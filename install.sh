#!/bin/bash
# VoiceType 安裝程式
#
# 一行安裝：
#   curl -fsSL https://tekelin16-tech.github.io/voicetype/install.sh | bash
# 或解壓縮後：
#   ./install.sh
#
# 重跑同一個指令就是更新。移除請跑 ~/.local/share/voicetype/uninstall.sh
set -uo pipefail

REPO_URL="${VOICETYPE_REPO:-https://github.com/tekelin16-tech/voicetype}"
BRANCH="${VOICETYPE_BRANCH:-main}"
DEST="$HOME/.local/share/voicetype"
CONF_DIR="$HOME/.config/voicetype"
CACHE="$HOME/.cache/voicetype"
HS_DIR="$HOME/.hammerspoon"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
MODEL_PATH="$CACHE/models/ggml-large-v3-turbo.bin"
MODEL_MIN_BYTES=1500000000     # 約 1.5GB，用來判斷是不是只下載到一半

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
say(){ printf '%s\n' "$*"; }
step(){ printf '\n%s▸ %s%s\n' "$B" "$*" "$N"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die(){ printf '\n%s✗ %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }

say ""
say "${B}VoiceType — 語音聽寫${N}"
say "${D}whisper.cpp 本機辨識 + DeepSeek 修稿${N}"

# ---------- 1. 環境檢查 ----------
step "檢查環境"
[ "$(uname -s)" = "Darwin" ] || die "這個工具只能在 macOS 上跑。"
ok "macOS $(sw_vers -productVersion) ($(uname -m))"

if ! command -v brew >/dev/null 2>&1; then
  die "找不到 Homebrew。先裝它再回來跑一次：
    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi
ok "Homebrew"

# swiftc 用來在「你自己的機器上」編譯錄音器。
# 這是刻意的：從網路下載的 app 會被 Gatekeeper 隔離，而且拿不到麥克風權限；
# 現場編譯就完全沒有這個問題。
if ! command -v swiftc >/dev/null 2>&1; then
  warn "缺少 Xcode Command Line Tools，正在叫出安裝視窗…"
  xcode-select --install 2>/dev/null
  die "請在跳出的視窗按「安裝」，裝完（約 5-10 分鐘）再跑一次這個指令。"
fi
ok "Swift 編譯器"

# ---------- 2. 相依套件 ----------
step "安裝相依套件${D}（第一次會比較久，brew 更新本身就要幾分鐘，不是當掉）${N}"
for f in whisper-cpp ffmpeg jq; do
  if brew list --formula "$f" >/dev/null 2>&1; then ok "$f ${D}已安裝${N}"
  else say "  安裝 $f …"; brew install "$f" >/dev/null 2>&1 && ok "$f" || die "$f 安裝失敗"; fi
done
if [ -d /Applications/Hammerspoon.app ]; then ok "Hammerspoon ${D}已安裝${N}"
else say "  安裝 Hammerspoon …"; brew install --cask hammerspoon >/dev/null 2>&1 \
     && ok "Hammerspoon" || die "Hammerspoon 安裝失敗"; fi

# ---------- 3. 取得程式碼 ----------
step "安裝程式檔案"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "$SRC" ] && [ -f "$SRC/vt.sh" ]; then
  ok "使用本機檔案 ${D}$SRC${N}"
else
  # curl | bash 的情況：沒有兄弟檔案，去抓一份 tarball
  TMP=$(mktemp -d)
  say "  下載程式碼 …"
  curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$TMP" \
    || die "下載失敗，檢查網路或 repo 網址：$REPO_URL"
  SRC=$(find "$TMP" -maxdepth 1 -type d -name "voicetype-*" | head -1)
  [ -n "$SRC" ] || die "解壓縮後找不到程式碼"
  ok "已下載"
fi

mkdir -p "$DEST" "$CONF_DIR" "$CACHE/models" "$HS_DIR"
cp "$SRC/vt.sh" "$SRC/set-key.sh" "$SRC/uninstall.sh" "$DEST/" 2>/dev/null
cp "$SRC/config.sh.example" "$SRC/README.md" "$DEST/" 2>/dev/null
mkdir -p "$DEST/recorder"
cp "$SRC/recorder/main.swift" "$SRC/recorder/build.sh" "$DEST/recorder/"
chmod +x "$DEST"/*.sh "$DEST/recorder/build.sh"
ok "裝到 $DEST"

# ---------- 4. 辨識模型 ----------
step "下載辨識模型${D}（1.5GB，只下載一次）${N}"
if [ -f "$MODEL_PATH" ] && [ "$(stat -f%z "$MODEL_PATH")" -ge "$MODEL_MIN_BYTES" ]; then
  ok "模型已存在 ${D}($(du -h "$MODEL_PATH" | cut -f1))${N}"
else
  [ -f "$MODEL_PATH" ] && warn "既有模型不完整，重新下載"
  # -C - 續傳、先寫 .tmp 再改名：下載到一半的模型會讓 whisper 報一個很難懂的錯
  curl -L --retry 3 -C - --progress-bar -o "$MODEL_PATH.tmp" "$MODEL_URL" \
    || die "模型下載失敗"
  [ "$(stat -f%z "$MODEL_PATH.tmp")" -ge "$MODEL_MIN_BYTES" ] || die "下載的模型大小不對，請重跑一次"
  mv "$MODEL_PATH.tmp" "$MODEL_PATH"
  ok "模型下載完成"
fi

# ---------- 5. 編譯錄音器 ----------
step "編譯錄音器"
say "${D}  macOS 不給 Homebrew 的 ffmpeg 麥克風權限（ad-hoc 簽章），而且是靜默拒絕——${N}"
say "${D}  錄出來會是一片靜音卻不報錯。所以錄音交給這個有正式 bundle 的小程式。${N}"
"$DEST/recorder/build.sh" >/dev/null 2>&1 || die "編譯失敗，手動跑看看錯誤：$DEST/recorder/build.sh"
ok "錄音器編譯完成"

# ---------- 6. 設定檔 ----------
step "建立設定"
VTREC="$DEST/recorder/VoiceTypeRec.app/Contents/MacOS/vtrec"
if [ -f "$CONF_DIR/config.sh" ]; then
  ok "設定檔已存在，保留你的設定 ${D}$CONF_DIR/config.sh${N}"
else
  cp "$DEST/config.sh.example" "$CONF_DIR/config.sh"
  # 挑第一個麥克風當預設。不同機型名稱不一樣（MacBook Air / Pro / 英文語系），
  # 不能寫死。
  MIC=$("$VTREC" --list 2>/dev/null | sed 's/^[^|]*|//' | head -1)
  if [ -n "$MIC" ]; then
    sed -i '' "s|^MIC_NAME=.*|MIC_NAME=\"$MIC\"|" "$CONF_DIR/config.sh"
    ok "麥克風設為「$MIC」"
  fi
  ok "設定檔建立完成"
fi

# ---------- 7. Hammerspoon ----------
step "設定熱鍵"
cp "$SRC/hammerspoon/voicetype.lua" "$HS_DIR/voicetype.lua"
cp "$SRC/hammerspoon/voicetype_ui.html" "$HS_DIR/voicetype_ui.html"
ok "熱鍵模組已安裝"
touch "$HS_DIR/init.lua"
if grep -q 'require("voicetype")' "$HS_DIR/init.lua" 2>/dev/null; then
  ok "init.lua 已經載入了，沒有重複加"
else
  # 只加一行，不碰使用者原本的設定
  printf '\n-- VoiceType 語音聽寫\nrequire("voicetype")\n' >> "$HS_DIR/init.lua"
  ok "已在 init.lua 加上一行 require（你原本的設定沒有被動到）"
fi

# ---------- 8. API key ----------
step "DeepSeek API key"
if security find-generic-password -s voicetype-deepseek -w >/dev/null 2>&1; then
  ok "Keychain 裡已經有 key 了"
else
  say "  DeepSeek 負責把逐字稿整理成通順的文字（加標點、去贅字、簡轉繁）。"
  say "  申請： ${B}https://platform.deepseek.com/api_keys${N}"
  say "  ${D}現在跳過也可以，之後跑 $DEST/set-key.sh 再設定。${N}"
  say "  ${D}沒有 key 時仍可使用，只是吐出未整理的原始辨識結果。${N}"
  say ""
  if [ -t 0 ]; then
    "$DEST/set-key.sh" || warn "稍後可再跑 $DEST/set-key.sh"
  else
    warn "非互動模式，跳過。裝完請跑： $DEST/set-key.sh"
  fi
fi

# ---------- 9. 完成 ----------
open -a Hammerspoon 2>/dev/null
say ""
say "${G}${B}安裝完成${N}"
say ""
say "${B}還要做一件事：給權限${N}"
say "  系統設定 → 隱私權與安全性 →"
say "    ${B}輔助使用${N}  打開 Hammerspoon    ${D}（模擬 ⌘V 貼上用）${N}"
say "    ${B}麥克風${N}    第一次按熱鍵時會跳出來，按允許"
say ""
say "${B}怎麼用${N}"
say "  ${B}⌥Space${N}        按住說話，放開就把整理好的文字貼到游標位置"
say "  ${B}⌥Space${N} 按一下  改成鎖定錄音，再按一下結束"
say "  ${B}⌥⇧Space${N}       切換錄音（長篇口述用）"
say "  ${B}⌥⌘Space${N}       選修稿風格（一般／AI 指令／訊息／信件／筆記／原始）"
say "  ${B}Esc${N}           錄音中取消"
say "  ${B}⌥⌘H${N}          歷史紀錄與設定（可以改熱鍵、編輯講過的內容）"
say ""
say "${D}  說明文件： $DEST/README.md${N}"
say "${D}  設定檔：   $CONF_DIR/config.sh${N}"
say "${D}  移除：     $DEST/uninstall.sh${N}"
say ""
