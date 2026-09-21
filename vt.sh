#!/bin/bash
# voicetype — 語音聽寫：whisper.cpp 辨識 + DeepSeek 修稿 + 貼到游標位置
# 用法: vt.sh toggle | start | stop | cancel | status | server-start | server-stop | test
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CONF="$HOME/.config/voicetype/config.sh"
CORR="$HOME/.config/voicetype/corrections.txt"
[ -f "$CONF" ] && . "$CONF"

: "${MIC_NAME:=}"        # 空的 = 用系統列出的第一個裝置
: "${MODEL:=$HOME/.cache/voicetype/models/ggml-large-v3-turbo.bin}"
: "${PORT:=8178}"
: "${LANG_CODE:=zh}"
: "${DS_MODEL:=deepseek-flash}"
: "${DS_FALLBACK:=deepseek-v4-pro}"  # flash 塞車時改用這個（貴一點但會通）
: "${DS_TIMEOUT:=8}"                 # 主模型：短皮帶，反正有備援可以退
: "${DS_TIMEOUT_FALLBACK:=25}"       # 備援：最後一道防線，給它久一點
: "${DS_DOWN_COOLDOWN:=600}"         # 整個 API 都掛掉時，暫停呼叫多久（秒，預設 10 分鐘）
: "${DS_COOLDOWN:=14400}"            # 主模型掛掉後，多久內直接走備援（秒，預設 4 小時）
: "${DS_ENDPOINT:=https://api.deepseek.com/chat/completions}"
: "${STYLE:=default}"
: "${SOUNDS:=1}"
: "${AUTO_PASTE:=1}"
: "${MAX_SECONDS:=300}"
: "${VT_PASTE:=auto}"   # auto=自己貼(指令列) / none=只輸出交給呼叫端貼(Hammerspoon)
: "${MIN_LEVEL:=-60}"   # 平均音量低於此 dB 視為沒說話
: "${HISTORY_MAX:=500}" # 歷史紀錄保留幾筆
: "${SYNC_URL:=https://voice.arkapp.pw}"   # 詞彙表同步服務
# 前後文：給 DeepSeek 多一點線索去判斷同音字。兩種來源，預設值刻意不同——
#   HISTORY_CONTEXT：拿你最近幾次的口述當線索。這些內容本來就送過 DeepSeek，
#                    不會多洩漏任何東西，所以預設開。
#   FIELD_CONTEXT：  拿游標前面「你原本就打好的字」。這是新的外洩，所以預設關。
#                    另外 Electron App（Claude、Slack）讀不到，開了也沒用。
: "${HISTORY_CONTEXT:=3}"
: "${FIELD_CONTEXT:=0}" # 歷史紀錄保留幾筆   # 平均音量低於此 dB 視為沒說話。實測：數位靜音 -91、安靜房間 -41、正常說話 -15
: "${VOCAB:=}"

# API key：Keychain 優先。刻意排在環境變數前面——.zshrc 裡可能留著過期的
# DEEPSEEK_API_KEY，那會安靜地蓋掉正確的那把，症狀是「修稿突然失效」很難查。
# 要臨時覆寫就用 VT_KEY=xxx ./vt.sh
if [ -n "${VT_KEY:-}" ]; then
  DEEPSEEK_API_KEY="$VT_KEY"
else
  K=$(security find-generic-password -s voicetype-deepseek -w 2>/dev/null)
  [ -n "$K" ] && DEEPSEEK_API_KEY="$K"
fi
export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"

RUN="$HOME/.cache/voicetype"; mkdir -p "$RUN"
PIDFILE="$RUN/rec.pid"; RAW="$RUN/rec_raw.wav"; WAV="$RUN/rec.wav"; LOG="$RUN/vt.log"
# 錄音一律走這個有 bundle 的 app。ffmpeg 只拿來轉檔——轉檔不需要麥克風權限。
VTREC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recorder/VoiceTypeRec.app/Contents/MacOS/vtrec"
SRVPID="$RUN/server.pid"; STYLEFILE="$RUN/style"; LEVEL="$RUN/level"; COOLDOWN="$RUN/model_cooldown"; APIDOWN="$RUN/api_down"; FIELDCTX="$RUN/field_context.txt"; LASTRAW="$RUN/last_raw.txt"; LASTOUT="$RUN/last_out.txt"; HISTORY="$RUN/history.jsonl"

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
ding(){ [ "$SOUNDS" = 1 ] && afplay "/System/Library/Sounds/$1.aiff" >/dev/null 2>&1 & }
notify(){ osascript -e "display notification \"$1\" with title \"VoiceType\"" >/dev/null 2>&1; }

# ---------- 麥克風 ----------
# 裝置清單以 vtrec 為準：ffmpeg 的 avfoundation 列舉跟 AVFoundation 的不完全一樣，
# 用會錄音的那個當唯一真相，才不會「清單上有、實際挑不到」。
mic_scan(){ "$VTREC" --list 2>/dev/null | sed 's/^[^|]*|//'; }

mic_ok(){   # 設定的名稱是否真的存在（沒設定就是用第一個，一定成立）
  [ -z "$MIC_NAME" ] && return 0
  local nm
  while IFS= read -r nm; do [ "$nm" = "$MIC_NAME" ] && return 0; done < <(mic_scan)
  return 1
}

# ---------- whisper-server：常駐省下每次載入模型的時間 ----------
server_up(){ curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; }
server_start(){
  server_up && { echo "whisper-server 已在跑 (port $PORT)"; return 0; }
  [ -f "$MODEL" ] || { echo "找不到模型: $MODEL" >&2; return 1; }
  nohup whisper-server -m "$MODEL" --port "$PORT" -l "$LANG_CODE" -nt -sns -t 6 \
        >> "$RUN/server.log" 2>&1 &
  echo $! > "$SRVPID"
  local i; for i in $(seq 1 60); do server_up && { echo "whisper-server 起來了 (port $PORT)"; return 0; }; sleep 0.5; done
  echo "whisper-server 啟動逾時，看 $RUN/server.log" >&2; return 1
}
server_stop(){ [ -f "$SRVPID" ] && kill "$(cat "$SRVPID")" 2>/dev/null; rm -f "$SRVPID"; pkill -f "whisper-server .*--port $PORT" 2>/dev/null; echo "已停止"; }

# ---------- 錄音 ----------
rec_start(){
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "已經在錄音中"; return 0; fi
  rm -f "$RAW" "$WAV"
  log "start rec: $MIC_NAME"
  rm -f "$LEVEL" "$FIELDCTX"
  "$VTREC" "$RAW" "$MIC_NAME" "$LEVEL" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  # 開裝置要一點時間，這段期間說的話收不到。等檔案真的開始長大再響提示音，
  # 提示音才是誠實的「可以說了」訊號。
  local i sz
  for i in $(seq 1 100); do
    sz=$(stat -f%z "$RAW" 2>/dev/null || echo 0)
    [ "${sz:-0}" -gt 4096 ] && break
    kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || break   # 錄音器掛了就別空等
    sleep 0.05
  done
  ding Tink
}

rec_stop_file(){   # 收掉錄音器並轉成 whisper 要的格式
  [ -f "$PIDFILE" ] || return 1
  local pid; pid=$(cat "$PIDFILE"); rm -f "$PIDFILE" "$LEVEL"
  # 不能 kill -9：那樣 WAV 檔尾寫不完整，whisper 會讀不了。vtrec 收到 INT 會自己收尾。
  kill -INT "$pid" 2>/dev/null
  local i; for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
  [ -s "$RAW" ] || return 1
  ffmpeg -hide_banner -loglevel error -y -i "$RAW" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV" 2>>"$LOG"
  [ -s "$WAV" ]
}

# ---------- 辨識 ----------
mean_db(){   # 注意 volumedetect 的結果是 info 等級，-v error 會把它一起濾掉（踩過）
  ffmpeg -hide_banner -nostats -loglevel info -i "$WAV" -af volumedetect -f null - 2>&1 \
  | sed -n 's/.*mean_volume: \(-*[0-9.]*\) dB.*/\1/p' | head -1
}

# whisper 對靜音或極小聲的輸入會生出訓練資料裡的 YouTube 字幕署名。
# 主要防線是上面的音量閘；這裡只擋「整句都不可能是正常說話」的那幾種，
# 寧可漏掉也不要誤殺——安靜吃掉使用者真正說的話，比偶爾一次幻覺糟得多。
# 所以要求：整段夠短（幻覺都是短的獨立署名）+ 命中明確特徵。
is_hallucination(){
  local t; t=$(printf '%s' "$1" | tr -d ' 　,，。.、!！?？~-')
  [ "${#t}" -gt 40 ] && return 1          # 夠長就是真的在說話
  # 不可能出現在正常口述裡的招牌字串
  printf '%s' "$t" | grep -qE '([Aa]mara|不吝(点赞|點贊|按赞|按讚)|明(镜|鏡)与(点点|點點)|优优独播剧场|YoYo Television)' && return 0
  # 這些字眼正常說話也會用到（「字幕志願者的名單要更新」），所以再加嚴長度限制
  [ "${#t}" -le 20 ] && printf '%s' "$t" | grep -qE '(字幕志(愿|願)者|中文字幕by|字幕组$|字幕組$)' && return 0
  # 完全等於這幾句才擋
  printf '%s' "$t" | grep -qE '^(谢谢观看|謝謝觀看|感谢观看|感謝觀看|谢谢大家观看|请不吝点赞订阅|請不吝點贊訂閱)$' && return 0

  return 1
}

transcribe(){
  local VOCAB_EFF; VOCAB_EFF=$(vocab_effective)
  local out
  if server_up; then
    out=$(curl -s -m 120 "http://127.0.0.1:$PORT/inference" \
          -F file=@"$WAV" -F temperature=0 -F response_format=text \
          -F language="$LANG_CODE" ${VOCAB_EFF:+-F prompt="$VOCAB_EFF"} 2>/dev/null)
  else
    out=$(whisper-cli -m "$MODEL" -l "$LANG_CODE" -nt -np -sns -t 6 \
          ${VOCAB_EFF:+--prompt "$VOCAB_EFF"} -f "$WAV" 2>/dev/null)
  fi
  printf '%s' "$out" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -vE '^\[(BLANK_AUDIO|_BEG_|音樂|Music)\]?' | paste -sd' ' -
}

# ---------- 修正字典 ----------
# 同音字（國翔／國祥）光靠熱詞表壓不住，whisper 選哪個字是機率問題。
# 所以分兩層：熱詞表幫 whisper 提高命中率，修正字典在事後把漏網的改掉。
# 格式：一行一條，「國翔」= 告訴 DeepSeek 這是專有名詞；
#      「國祥→國翔」= 不管前面怎麼判，最後強制替換。
# 詞彙表只有一份（corrections.txt），三個用途都從它衍生：
#   1. whisper 的熱詞（提高一開始就聽對的機率）
#   2. DeepSeek 的專有名詞清單（讓它知道哪些字是刻意的）
#   3. 明確的「錯→對」強制替換
# 之前分成「熱詞表」和「修正字典」兩個欄位，結果兩邊重疊又各有遺漏，
# 使用者根本不知道該填哪一邊。一份就好。
vocab_effective(){   # 給 whisper 用的熱詞：config 有設就用它，否則從詞彙表衍生
  if [ -n "$VOCAB" ]; then printf '%s' "$VOCAB"; return; fi
  [ -f "$CORR" ] || return
  # 限 40 個詞：whisper 的 initial prompt 太長會明顯拖慢辨識
  python3 -c '
import sys, io
seen, out = set(), []
for line in io.open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    for sep in ("\u2192", "->"):
        if sep in line:
            line = line.split(sep, 1)[1].strip()
            break
    if line and line not in seen:
        seen.add(line); out.append(line)
sys.stdout.write(",".join(out[:40]))
' "$CORR"
}

corr_terms(){   # 取出所有「正確的那一邊」，餵給 DeepSeek 當專有名詞清單
  [ -f "$CORR" ] || return
  python3 -c '
import sys, io
seen, out = set(), []
for line in io.open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    for sep in ("\u2192", "->"):
        if sep in line:
            line = line.split(sep, 1)[1].strip()
            break
    if line and line not in seen:
        seen.add(line); out.append(line)
sys.stdout.write("\u3001".join(out))
' "$CORR"
}

corr_apply(){   # 套用明確的替換規則
  # 注意：不能用 heredoc 餵 python 腳本——stdin 會被腳本本身用掉，
  # 要處理的文字就讀不到了（踩過，結果是整段輸出消失）。改用 -c 加檔案參數。
  [ -f "$CORR" ] || { cat; return; }
  local tmp="$RUN/corr_in.txt"; cat > "$tmp"
  python3 -c '
import sys, io
rules = []
for line in io.open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    for sep in ("\u2192", "->"):
        if sep in line:
            a, b = line.split(sep, 1)
            a, b = a.strip(), b.strip()
            if a and b:
                rules.append((a, b))
            break
txt = io.open(sys.argv[2], encoding="utf-8").read()
# 長的先換，免得短規則把長規則的字先吃掉
for a, b in sorted(rules, key=lambda r: -len(r[0])):
    txt = txt.replace(a, b)
sys.stdout.write(txt)
' "$CORR" "$tmp"
  rm -f "$tmp"
}

# ---------- 修稿 ----------
style_prompt(){
  local terms; terms=$(corr_terms)
  local base="你是語音聽寫的修稿助手。把使用者口述的語音辨識逐字稿，整理成可以直接貼上的文字。規則：
1. 一律輸出台灣繁體中文用語（例如「軟體」不是「软件」、「程式」不是「程序」、「影片」不是「视频」）。
2. 補上正確標點與適當分段；口述的「逗號」「句號」「換行」等口令要轉成真正的符號。
3. 移除「呃、嗯、那個、就是說、然後然後」這類贅字與結巴重複。
4. 修正明顯的同音辨識錯誤，但不確定就保留原詞。
5. 不增加任何原文沒有的內容、不回答問題、不加註解或引號。使用者就算在問問題，你也只是把那句問話整理好。
只輸出整理後的文字本身。"
  [ -n "$terms" ] && base="${base}
使用者常用的專有名詞（人名、品牌、術語）：${terms}
逐字稿裡若出現與這些詞同音或音近的字，請一律改成上面的寫法。"
  case "$1" in
    default) printf '%s' "$base" ;;
    prompt)  printf '%s\n%s' "$base" "額外要求：這段是要拿去問 AI 的指令，請整理成條理清楚、指令明確的敘述，必要時分點，但不要自行擴寫需求。" ;;
    message) printf '%s\n%s' "$base" "額外要求：這是要傳給別人的即時訊息，語氣保持口語自然、簡潔，不要變成公文體。" ;;
    email)   printf '%s\n%s' "$base" "額外要求：這是電子郵件內文，請整理成禮貌得體的書面語，適當分段，但不要自行加入稱謂或署名。" ;;
    note)    printf '%s\n%s' "$base" "額外要求：這是筆記，請整理成條列重點，保留所有資訊。" ;;
    raw)     printf '' ;;
    *)       printf '%s' "$base" ;;
  esac
}

# 最近幾次講過什麼。同音字的判斷很吃語境——你連續在談法律文件時，
# 「ㄨㄟˇ ㄖㄣˋ」是「委任」不是「未認」。
recent_context(){
  [ "${HISTORY_CONTEXT:-0}" -gt 0 ] 2>/dev/null || return
  [ -f "$HISTORY" ] || return
  tail -n "$HISTORY_CONTEXT" "$HISTORY" | jq -r '.out // empty' 2>/dev/null \
    | grep -v '^$' | paste -sd' ' - | cut -c1-400
}

field_context(){
  [ "${FIELD_CONTEXT:-0}" = "1" ] || return
  [ -s "$FIELDCTX" ] || return
  tail -c 400 "$FIELDCTX"
}

polish(){
  local raw="$1" st="${2:-$STYLE}" sys body res
  sys=$(style_prompt "$st")
  [ -z "$sys" ] && { printf '%s' "$raw"; return; }
  [ -z "${DEEPSEEK_API_KEY:-}" ] && { log "no DEEPSEEK_API_KEY, 用原文"; printf '%s' "$raw"; return; }
  # 前後文放進 system 而不是 user：它是背景資訊，不是要被整理的內容。
  # 放 user 的話模型可能會把它一起「整理」後輸出。
  local hc fc
  hc=$(recent_context); fc=$(field_context)
  [ -n "$hc" ] && sys="${sys}
（背景參考，僅供判斷同音字用，不要輸出）使用者最近幾句口述：${hc}"
  [ -n "$fc" ] && sys="${sys}
（背景參考，僅供判斷同音字用，不要輸出）游標前已有的文字：${fc}"

  _clear_down(){ [ -f "$APIDOWN" ] && { rm -f "$APIDOWN"; log "DeepSeek 恢復，解除暫停"; }; true; }

  _ds_call(){   # _ds_call 模型 [逾時秒數] → 成功時印出修好的文字，失敗回非 0
    local model="$1" tmo="${2:-$DS_TIMEOUT}" b r txt code
    b=$(jq -n --arg m "$model" --arg s "$sys" --arg u "$raw" \
      '{model:$m,temperature:0.2,stream:false,messages:[{role:"system",content:$s},{role:"user",content:$u}]}')
    # 分開拿 HTTP 狀態碼：逾時的時候 body 是空的，只靠 body 判斷會得到空訊息，
    # 之後看記錄完全查不出發生什麼事（踩過）
    r=$(curl -s -m "$tmo" -w '\n%{http_code}' "$DS_ENDPOINT" \
        -H "Content-Type: application/json" -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -d "$b" 2>/dev/null)
    code=$(printf '%s' "$r" | tail -1)
    r=$(printf '%s' "$r" | sed '$d')
    if [ "$code" = "000" ] || [ -z "$code" ]; then
      log "deepseek $model: 逾時（${tmo}s 內無回應）"; return 1
    fi
    if [ "$code" != "200" ]; then
      log "deepseek $model: HTTP $code $(printf '%s' "$r" | jq -r '.error.message // .' 2>/dev/null | head -c 160)"
      return 1
    fi
    txt=$(printf '%s' "$r" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    [ -z "$txt" ] && { log "deepseek $model: 回應解析不出內容"; return 1; }
    _clear_down
    printf '%s' "$txt"
  }

  # 整個 API 都不通的時候，不要每次口述都去等一輪。
  # 直接秒出未整理的原文，比讓使用者每句都等半分鐘好太多。
  local down_until
  down_until=$(cat "$APIDOWN" 2>/dev/null || echo 0)
  case "$down_until" in ''|*[!0-9]*) down_until=0 ;; esac
  if [ "$(date +%s)" -lt "$down_until" ]; then
    log "DeepSeek 暫停中（剩 $(( (down_until - $(date +%s)) / 60 )) 分鐘），直接用原文"
    printf '%s' "$raw"; return
  fi

  # 熔斷：主模型掛掉之後，不要每次口述都再浪費十幾秒去試它。
  # 記下時間，冷卻期內直接走備援；時間到自動回頭試一次，通了就切回來。
  local now cd_until out
  now=$(date +%s)
  cd_until=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
  case "$cd_until" in ''|*[!0-9]*) cd_until=0 ;; esac

  if [ "$now" -lt "$cd_until" ]; then
    # 冷卻中：直接用備援，連試都不試主模型
    if out=$(_ds_call "$DS_FALLBACK" "$DS_TIMEOUT_FALLBACK"); then printf '%s' "$out"; return; fi
    # 備援也掛了，那就順便看看主模型是不是復活了
    if out=$(_ds_call "$DS_MODEL"); then
      rm -f "$COOLDOWN"; log "主模型 $DS_MODEL 恢復，解除冷卻"
      notify "$DS_MODEL 恢復正常"
      printf '%s' "$out"; return
    fi
  else
    if out=$(_ds_call "$DS_MODEL"); then
      if [ "$cd_until" -gt 0 ]; then
        rm -f "$COOLDOWN"; log "主模型 $DS_MODEL 恢復，解除冷卻"; notify "$DS_MODEL 恢復正常"
      fi
      printf '%s' "$out"; return
    fi
    # 主模型不通 → 進入冷卻，之後直接走備援
    if [ -n "$DS_FALLBACK" ] && [ "$DS_FALLBACK" != "$DS_MODEL" ]; then
      echo $((now + DS_COOLDOWN)) > "$COOLDOWN"
      log "$DS_MODEL 不通，改用 ${DS_FALLBACK}，冷卻 $((DS_COOLDOWN / 3600)) 小時"
      notify "$DS_MODEL 忙線，接下來 $((DS_COOLDOWN / 3600)) 小時改用 $DS_FALLBACK"
      if out=$(_ds_call "$DS_FALLBACK" "$DS_TIMEOUT_FALLBACK"); then printf '%s' "$out"; return; fi
    fi
  fi

  # 兩個模型都不通 → 暫停呼叫一段時間，讓後續口述直接秒出原文
  echo $(( $(date +%s) + DS_DOWN_COOLDOWN )) > "$APIDOWN"
  log "DeepSeek 全數不通，暫停呼叫 $((DS_DOWN_COOLDOWN / 60)) 分鐘"
  notify "DeepSeek 連不上，接下來 $((DS_DOWN_COOLDOWN / 60)) 分鐘直接輸出未整理的原文"
  printf '%s' "$raw"
}

# ---------- 歷史紀錄 ----------
# 一行一筆 JSON（jsonl）。用 jq 產生，才不會被引號、換行、CJK 搞壞。
history_add(){
  # 用 /dev/urandom 而不是 ${RANDOM}：同一秒內連續呼叫 $RANDOM 會拿到一樣的值，
  # 兩筆紀錄撞 id 的話，刪一筆會把兩筆都刪掉。
  local id; id="$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  jq -nc --arg id "$id" --arg ts "$(date -u +%FT%TZ)" \
         --arg raw "$1" --arg out "$2" --arg style "$3" \
         '{id:$id, ts:$ts, style:$style, raw:$raw, out:$out}' >> "$HISTORY" 2>/dev/null
  # 只留最近 N 筆，不然檔案會無限長大
  local n; n=$(wc -l < "$HISTORY" 2>/dev/null | tr -d ' ')
  if [ -n "$n" ] && [ "$n" -gt "$HISTORY_MAX" ]; then
    tail -n "$HISTORY_MAX" "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
  fi
}

# ---------- 貼上（保留原本剪貼簿內容） ----------
paste_text(){
  local txt="$1"
  local saved; saved=$(pbpaste 2>/dev/null)
  printf '%s' "$txt" | pbcopy
  if [ "$AUTO_PASTE" = 1 ]; then
    osascript -e 'tell application "System Events" to keystroke "v" using command down' >/dev/null 2>&1
    sleep 0.6
    printf '%s' "$saved" | pbcopy    # 還原使用者原本複製的東西
  fi
}

# ---------- 給 UI 用的讀寫介面 ----------
# 設定的讀寫都走這裡，不要讓 UI 自己去改設定檔——一個真相來源比較不會壞。
CONF="$HOME/.config/voicetype/config.sh"
CORR="$HOME/.config/voicetype/corrections.txt"

config_get(){
  local mics; mics=$(mic_scan | jq -R . | jq -sc .)
  jq -nc --arg style "$STYLE" --arg mic "$MIC_NAME" \
         --argjson mics "${mics:-[]}" \
         --argjson sounds "$([ "$SOUNDS" = 1 ] && echo true || echo false)" \
         --argjson autopaste "$([ "$AUTO_PASTE" = 1 ] && echo true || echo false)" \
         --arg model "$DS_MODEL" \
         '{style:$style, mic:$mic, mics:$mics, sounds:$sounds,
           autopaste:$autopaste, ds_model:$model}'
}

config_set(){   # config_set KEY VALUE
  local k="$1" v="$2"
  mkdir -p "$(dirname "$CONF")"; touch "$CONF"
  # 值裡可能有 / 和中文，用 python 改比 sed 安全
  python3 - "$CONF" "$k" "$v" <<'PY'
import sys, re
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
line = '%s="%s"' % (key, val.replace('\\', '\\\\').replace('"', '\\"'))
pat = re.compile(r'^%s=.*$' % re.escape(key), re.M)
s = pat.sub(lambda m: line, s) if pat.search(s) else (s.rstrip() + '\n' + line + '\n')
open(path, 'w', encoding='utf-8').write(s)
PY
}

corr_add(){   # 從 stdin 讀新的條目，接在現有詞彙表後面（corr_set 會去重）
  { corr_get; cat; } | corr_set
}

# 給設定視窗用的模型狀態。讓使用者看得懂現在在哪個階段、為什麼。
model_status(){
  local now cu du cur stage last
  now=$(date +%s)
  cu=$(cat "$COOLDOWN" 2>/dev/null || echo 0); case "$cu" in ''|*[!0-9]*) cu=0 ;; esac
  du=$(cat "$APIDOWN" 2>/dev/null || echo 0);  case "$du" in ''|*[!0-9]*) du=0 ;; esac

  if [ "$du" -gt "$now" ]; then
    cur=""; stage="paused"
  elif [ "$cu" -gt "$now" ]; then
    cur="$DS_FALLBACK"; stage="fallback"
  else
    cur="$DS_MODEL"; stage="primary"
  fi
  # 最近一次模型相關的錯誤，讓使用者知道是 503 還是逾時
  last=$(grep -E "deepseek .*(逾時|HTTP|解析不出)" "$LOG" 2>/dev/null | tail -1 | sed 's/^[0-9-]* [0-9:]* //')

  jq -nc --arg cur "$cur" --arg primary "$DS_MODEL" --arg fb "$DS_FALLBACK" \
    --arg stage "$stage" --arg last "${last:-}" \
    --argjson cd "$(( cu > now ? (cu - now) / 60 : 0 ))" \
    --argjson down "$(( du > now ? (du - now) / 60 : 0 ))" \
    '{current:$cur, primary:$primary, fallback:$fb, stage:$stage,
      cooldown_min:$cd, paused_min:$down, last_error:$last}'
}

model_reset(){ rm -f "$COOLDOWN" "$APIDOWN"; log "使用者手動解除冷卻與暫停"; echo '{"ok":true}'; }

corr_get(){ [ -f "$CORR" ] && cat "$CORR" || true; }
corr_set(){   # 存檔時去重、去空行，並保證結尾有換行
  mkdir -p "$(dirname "$CORR")"
  python3 -c '
import sys, io
seen, out = set(), []
for line in io.open(0, encoding="utf-8"):
    line = line.rstrip()
    key = line.strip()
    if not key:
        continue
    if key.startswith("#"):
        out.append(line); continue
    if key in seen:
        continue
    seen.add(key); out.append(line)
io.open(sys.argv[1], "w", encoding="utf-8").write("\n".join(out) + "\n")
' "$CORR"
}

# 只回最近 N 筆。
# 為什麼要限制：hs.task 是等程序結束才讀輸出，但管線緩衝區只有 64KB——
# 輸出超過就會卡在寫入、程序永遠不結束、回呼永遠不觸發，整個設定視窗變全白。
# 這個死鎖在歷史累積到約 230 筆時就會發生，而且從終端機跑完全正常（shell 會持續讀取），
# 非常難聯想。要調大的話請同時確認輸出仍遠小於 64KB。
: "${HISTORY_PAGE:=80}"
history_get(){
  # 同時寫檔與印出。Hammerspoon 那端讀檔案，不讀管線——
  # macOS 的管線緩衝區約 16KB，超過就會有各種難查的行為（輸出變空、程序卡住），
  # 而且從終端機跑通常正常，非常難重現。走檔案就沒這個問題。
  local page="$RUN/history_page.json"
  if [ -f "$HISTORY" ]; then
    tail -r "$HISTORY" 2>/dev/null | jq -sc ".[0:${1:-$HISTORY_PAGE}]" > "$page" 2>/dev/null \
      || jq -nc '[]' > "$page"
  else
    jq -nc '[]' > "$page"
  fi
  cat "$page"
}


history_edit(){   # history_edit ID 新內容
  [ -f "$HISTORY" ] || return 0
  jq -c --arg id "$1" --arg out "$2" 'if .id == $id then .out = $out | .edited = true else . end' \
    "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
}

history_del(){
  [ -f "$HISTORY" ] || return 0
  jq -c --arg id "$1" 'select(.id != $id)' "$HISTORY" > "$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
}

# ---------- 詞彙表同步 ----------
# 帳號碼放 Keychain，不放設定檔。沒設定就不同步，功能照常運作。
sync_token(){ security find-generic-password -s voicetype-sync-token -w 2>/dev/null; }

sync_set_token(){
  read -r -s -p "貼上帳號碼（輸入時不顯示）: " T; echo
  [ -z "$T" ] && { echo "沒有輸入，取消"; return 1; }
  security delete-generic-password -s voicetype-sync-token >/dev/null 2>&1
  security add-generic-password -a "$USER" -s voicetype-sync-token -w "$T" -U || return 1
  local who; who=$(curl -s -m 20 -H "Authorization: Bearer $T" "$SYNC_URL/v1/me" \
                   | jq -r '.name // empty' 2>/dev/null)
  if [ -n "$who" ]; then echo "已連上，帳號：$who"; else
    echo "帳號碼存起來了，但連不上伺服器或帳號碼無效"; return 1; fi
}

# 把兩份詞彙表合成一份：聯集、去重、保留順序。
# 用聯集而不是「誰新誰贏」，是因為兩台裝置各自加的詞都該留著——
# 覆蓋式同步會讓人在手機上加的詞被電腦默默吃掉。
_merge_vocab(){
  python3 -c '
import io, sys
def load(p):
    try: return io.open(p, encoding="utf-8").read().splitlines()
    except FileNotFoundError: return []
a, b = load(sys.argv[1]), load(sys.argv[2])
seen, out = set(), []
for line in a + b:
    t = line.strip()
    if not t:
        continue
    if t.startswith("#"):
        if t not in seen: seen.add(t); out.append(line)
        continue
    if t in seen: continue
    seen.add(t); out.append(line)
sys.stdout.write("\n".join(out) + "\n")
' "$1" "$2"
}

sync_vocab(){
  local t; t=$(sync_token)
  [ -z "$t" ] && { echo "還沒設定同步帳號碼。跑 vt.sh sync-login" >&2; return 1; }
  local tmp="$RUN/sync"; mkdir -p "$tmp"

  local attempt
  for attempt in 1 2; do
    local resp; resp=$(curl -s -m 25 -H "Authorization: Bearer $t" "$SYNC_URL/v1/vocab")
    [ -z "$resp" ] && { echo "連不上同步伺服器" >&2; return 1; }
    local err; err=$(printf '%s' "$resp" | jq -r '.error // empty')
    [ -n "$err" ] && { echo "同步失敗：$err" >&2; return 1; }

    printf '%s' "$resp" | jq -r '.vocabulary // ""' > "$tmp/remote.txt"
    local ver; ver=$(printf '%s' "$resp" | jq -r '.version // 0')

    corr_get > "$tmp/local.txt"
    _merge_vocab "$tmp/local.txt" "$tmp/remote.txt" > "$tmp/merged.txt"

    # 本地先寫入，就算推送失敗，遠端的東西也已經拿到手了
    cat "$tmp/merged.txt" | corr_set

    local body; body=$(jq -n --rawfile v "$tmp/merged.txt" --argjson bv "$ver" \
      --arg d "mac" '{vocabulary:$v, base_version:$bv, device:$d}')
    local put; put=$(curl -s -m 25 -X PUT -H "Authorization: Bearer $t" \
      -H "Content-Type: application/json" -d "$body" "$SYNC_URL/v1/vocab")
    local perr; perr=$(printf '%s' "$put" | jq -r '.error // empty')

    if [ "$perr" = "conflict" ]; then
      # 另一台裝置在這期間改過。重抓再合併一次就好，資料不會掉。
      log "同步衝突，重新合併"; continue
    fi
    if [ -n "$perr" ]; then echo "同步失敗：$perr" >&2; return 1; fi

    local n; n=$(grep -vc '^[[:space:]]*#' "$tmp/merged.txt" 2>/dev/null | tr -d ' ')
    echo "已同步，共 $n 條（版本 $(printf '%s' "$put" | jq -r '.version')）"
    rm -rf "$tmp"; return 0
  done
  echo "同步衝突重試後仍失敗，請再跑一次" >&2; return 1
}

# ---------- 主流程 ----------
do_stop(){
  local st="${1:-$STYLE}"
  rec_stop_file || { ding Basso; notify "沒有錄到聲音"; return 1; }
  ding Pop
  # 第一道：音量閘。刻意設得寬鬆（-60dB），只擋「完全沒訊號」，
  # 不擋安靜房間——誤殺使用者真的說過的話比放過一次幻覺糟得多，後面還有幻覺過濾接手。
  local lv; lv=$(mean_db)
  if [ -n "$lv" ] && awk -v a="$lv" -v b="$MIN_LEVEL" 'BEGIN{exit !(a<b)}'; then
    log "音量過低 (${lv}dB < ${MIN_LEVEL}dB)"
    ding Basso
    # -91dB 是純數位靜音：要嘛被其他 App 獨佔，要嘛權限沒給。兩者 ffmpeg 都不報錯。
    if awk -v a="$lv" 'BEGIN{exit !(a<-85)}'; then
      local hog; hog=$(mic_hogs)
      if [ -n "$hog" ]; then
        notify "麥克風被 ${hog} 佔用，請先結束它"
        log "麥克風無訊號；偵測到佔用者: ${hog}"
      else
        notify "麥克風沒有訊號——檢查 Hammerspoon 的麥克風權限"
        log "麥克風無訊號；沒偵測到佔用 App，疑似權限未授予"
      fi
    else
      notify "沒聽到聲音（${lv}dB）"
    fi
    return 1
  fi
  local raw; raw=$(transcribe)
  printf '%s' "$raw" > "$LASTRAW"
  if [ -z "$raw" ] || [ "${#raw}" -lt 2 ]; then ding Basso; notify "沒聽到內容"; return 1; fi
  # 第二道：擋掉 whisper 的幻覺句
  if is_hallucination "$raw"; then
    log "擋下幻覺輸出: $raw"; ding Basso; notify "沒聽清楚，請再說一次"; return 1
  fi
  local out; out=$(polish "$raw" "$st" | corr_apply)
  printf '%s' "$out" > "$LASTOUT"
  history_add "$raw" "$out" "$st"
  log "raw: $raw"; log "out: $out"
  # VT_PASTE=none 時不碰剪貼簿，由 Hammerspoon 用 hs.eventtap 貼
  # （osascript 打 System Events 需要額外的「自動化」權限，而且第一次會跳對話框卡住）
  [ "$VT_PASTE" = none ] || paste_text "$out"
  ding Glass
  printf '%s\n' "$out"
}

cmd="${1:-toggle}"; shift 2>/dev/null || true
case "$cmd" in
  start)  [ $# -gt 0 ] && echo "$1" > "$STYLEFILE"; rec_start ;;
  stop)   st=$(cat "$STYLEFILE" 2>/dev/null || echo "$STYLE"); rm -f "$STYLEFILE"; do_stop "${1:-$st}" ;;
  toggle)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      st=$(cat "$STYLEFILE" 2>/dev/null || echo "$STYLE"); rm -f "$STYLEFILE"; do_stop "$st"
    else
      [ $# -gt 0 ] && echo "$1" > "$STYLEFILE"; rec_start
    fi ;;
  cancel) [ -f "$PIDFILE" ] && { kill -INT "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; }; rm -f "$STYLEFILE" "$LEVEL"; ding Basso; echo "已取消" ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "recording"; else echo "idle"; fi
    server_up && echo "server: up (port $PORT)" || echo "server: down"
    echo "model: $MODEL"; mic_ok && echo "mic: ${MIC_NAME:-（系統預設，第一個裝置）} ✓" || echo "mic: ${MIC_NAME} ✗ 找不到這個裝置"
    echo "可用裝置:"; mic_scan | sed 's/^/  /'
    echo "錄音權限: $("$VTREC" --check 2>&1)"
    cu=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
    case "$cu" in ''|*[!0-9]*) cu=0 ;; esac
    du=$(cat "$APIDOWN" 2>/dev/null || echo 0)
    case "$du" in ''|*[!0-9]*) du=0 ;; esac
    [ "$du" -gt "$(date +%s)" ] && echo "⚠️ DeepSeek 暫停呼叫中，剩 $(( (du - $(date +%s)) / 60 )) 分鐘（直接輸出原文）"
    if [ "$cu" -gt "$(date +%s)" ]; then
      echo "修稿模型: ${DS_FALLBACK}（$DS_MODEL 冷卻中，剩 $(( (cu - $(date +%s)) / 60 )) 分鐘）"
    else
      echo "修稿模型: $DS_MODEL"
    fi; echo "style: $STYLE" ;;
  sync)         sync_vocab ;;
  sync-login)   sync_set_token ;;
  model-status) model_status ;;
  model-reset)  model_reset ;;
  corr-get)     corr_get ;;
  corr-add)     corr_add ;;
  corr-set)     corr_set ;;
  config-get)   config_get ;;
  config-set)   config_set "$1" "${2:-}" ;;
  history-get)  history_get "${1:-}" ;;
  history-edit) history_edit "$1" "$2" ;;
  history-del)  history_del "$1" ;;
  server-start) server_start ;;
  server-stop)  server_stop ;;
  redo)   raw=$(cat "$LASTRAW" 2>/dev/null)
          [ -z "$raw" ] && { echo "沒有上一段可以重做" >&2; exit 1; }
          out=$(polish "$raw" "${1:-$STYLE}" | corr_apply); printf '%s' "$out" > "$LASTOUT"
          [ "$VT_PASTE" = none ] || printf '%s' "$out" | pbcopy
          printf '%s\n' "$out" ;;
  test)   echo "錄音器: $VTREC"; [ -x "$VTREC" ] && echo "  存在 ✓" || echo "  不存在 ✗ 先跑 recorder/build.sh"
          echo "錄音權限: $("$VTREC" --check 2>&1)"
    cu=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
    case "$cu" in ''|*[!0-9]*) cu=0 ;; esac
    du=$(cat "$APIDOWN" 2>/dev/null || echo 0)
    case "$du" in ''|*[!0-9]*) du=0 ;; esac
    [ "$du" -gt "$(date +%s)" ] && echo "⚠️ DeepSeek 暫停呼叫中，剩 $(( (du - $(date +%s)) / 60 )) 分鐘（直接輸出原文）"
    if [ "$cu" -gt "$(date +%s)" ]; then
      echo "修稿模型: ${DS_FALLBACK}（$DS_MODEL 冷卻中，剩 $(( (cu - $(date +%s)) / 60 )) 分鐘）"
    else
      echo "修稿模型: $DS_MODEL"
    fi
          mic_ok && echo "麥克風「${MIC_NAME:-系統預設}」✓" || echo "麥克風「${MIC_NAME}」✗ 找不到"
          echo "模型: $MODEL"; [ -f "$MODEL" ] && echo "模型存在 ✓" || echo "模型不存在 ✗"
          [ -n "${DEEPSEEK_API_KEY:-}" ] && echo "DEEPSEEK_API_KEY 已設定 ✓" || echo "DEEPSEEK_API_KEY 未設定 ✗" ;;
  *) echo "用法: vt.sh {toggle|start|stop|cancel|status|redo|config-get|config-set|sync|sync-login|model-status|model-reset|corr-get|corr-set|corr-add|history-get|history-edit|history-del|server-start|server-stop|test} [style]"; exit 1 ;;
esac
