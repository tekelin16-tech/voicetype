# VoiceType

按住一個鍵說話，整理好的文字直接出現在游標位置。

```bash
curl -fsSL https://tekelin16-tech.github.io/voicetype/install.sh | bash
```

macOS 專用。第一次安裝約 5–10 分鐘（要下載 1.5GB 的辨識模型）。
說明網頁：https://tekelin16-tech.github.io/voicetype

移除：`~/.local/share/voicetype/uninstall.sh`

---

## 為什麼是兩段式

**DeepSeek 沒有語音辨識 API**，它只有文字模型（`deepseek-flash` / `deepseek-v4-pro`），
沒有 Whisper 那種 audio transcription 端點。所以：

| 階段 | 用什麼 | 在哪跑 | 實測速度 |
|---|---|---|---|
| 錄 | `VoiceTypeRec.app`（自製，Swift/AVFoundation） | 本機 | — |
| 聽（ASR） | whisper.cpp `large-v3-turbo` | 本機 Metal，常駐 | 11.7 秒語音 → **0.8 秒** |
| 修稿 | DeepSeek `deepseek-flash` | API | 約 2 秒 |

本機辨識的好處：不用把聲音傳出去、沒有 ASR 費用、斷網也還能用（只是少了修稿）。
DeepSeek 負責的是真正有價值的那一半——加標點、去贅字、簡轉繁台灣用語、依情境改寫語氣。

## 三個地方都能叫出設定視窗

1. **「應用程式」裡的 VoiceType** — 就是一般 App 的用法，Launchpad 或 Spotlight 都找得到
2. **選單列的波形圖示** → 「歷史紀錄與設定…」
3. **`⌥⌘H`**

那個 VoiceType.app 本身不做事，只是叫 Hammerspoon 打開視窗
（Hammerspoon 沒在跑會先幫你起它）。真正在運作的是 Hammerspoon 模組。

⚠️ `~/.local/share/voicetype/recorder/VoiceTypeRec.app` 是**背景錄音元件**，
不是主程式。它刻意沒有視窗，點了不會有反應，也已經設定成不被 Spotlight 索引。

## 熱鍵

| 按鍵 | 行為 |
|---|---|
| `⌥Space` | **按住說話**，放開就轉錄貼上 |
| `⌥Space` 短按一下 | 改成**鎖定錄音**（不用一直按著），再按一下結束 |
| `⌥⇧Space` | 單純切換錄音，長篇口述用 |
| `⌃⌥Space` | 選這次的修稿風格 |
| `⌥⌘H` | 開啟歷史紀錄與設定視窗 |
| `Esc` | 錄音中按 = 取消，不辨識不貼上 |

選單列：`🎙 待命` → `🔴 錄音中` → `⏳ 轉錄中`

## 錄音介面

按下去之後螢幕正中央會出現一個面板：紅點、「錄音中」、經過秒數、音量波形、操作提示。
轉錄時紅點變黃、文字變「轉錄中…」，貼上後自動消失。

**面板可以用滑鼠拖到任何地方**，位置記在 `~/.cache/voicetype/panel_pos`，重開機也還在。
想放回正中央就點選單列的「錄音面板位置歸中」。換螢幕或改解析度後，如果存的座標已經在
畫面外，會自動忽略回到正中央。

**波形畫的是真實音量**（`vtrec` 每 50ms 把 `averagePowerLevel` 寫進 `~/.cache/voicetype/level`，
Hammerspoon 讀檔畫圖），不是裝飾動畫。所以它同時是個診斷工具——
如果你在講話但波形是平的，就是麥克風沒收到，不用等到貼不出東西才發現。

## 修稿風格

| 風格 | 適合 |
|---|---|
| 一般 | 預設。補標點、去贅字、繁體台灣用語 |
| AI 指令 | 口述要丟給 Claude / ChatGPT 的指令，整理成條理清楚的敘述 |
| 訊息 | LINE、即時通訊。保持口語自然，不會變公文體 |
| 信件 | 書面語、禮貌得體、適當分段 |
| 筆記 | 條列重點，保留所有資訊 |
| 原始 | 跳過 DeepSeek，直接吐 whisper 結果（省錢、離線可用） |

講錯風格不用重錄——選單列有「重新修稿上一段」，換個風格重跑，不用再說一次。

## 歷史紀錄與設定視窗（⌥⌘H）

選單列的麥克風圖示 🎙 也能打開。兩個分頁：

- **歷史紀錄** — 每次口述都留著（原始辨識＋修稿結果＋風格＋時間），可以搜尋、複製、
  **編輯**、刪除。預設保留最近 500 筆，存在 `~/.cache/voicetype/history.jsonl`。
- **設定** — 改熱鍵（點欄位然後按下你要的組合鍵）、預設風格、熱詞表、麥克風、
  提示音、自動貼上。存檔時自動重載 Hammerspoon。

第一次安裝完會自動打開，裡面有一頁上手說明。

## 詞彙表：名字、暱稱、專有名詞

`⌥⌘H` → 設定 → 最上面那個「詞彙表」。一行一條，兩種寫法：

```
國翔            辨識時優先選這個寫法，聽到音近的也會往這邊修
國祥→國翔       不管前面怎麼判，最後一定換成右邊（最保險）
陳雅婷
小美
ERP
```

人名、同事暱稱、公司名、專案代號、術語都放這裡。開頭 `#` 的是註解。

**同音字建議兩條都寫**（`國翔` 和 `國祥→國翔`）。原因：同音字光靠熱詞壓不住，
辨識選哪個字是機率問題。第一條讓 AI 理解語境，第二條是保險。

這一份清單同時餵三個地方：
1. **whisper 的熱詞** — 提高一開始就聽對的機率（只取前 40 條，太多會拖慢辨識）
2. **DeepSeek 的專有名詞清單** — 讓它知道哪些字是刻意的，不要「修正」掉
3. **強制替換** — 帶 `→` 的規則在最後套用，長規則優先，
   免得短規則把長規則的字先吃掉

存在 `~/.config/voicetype/corrections.txt`，存檔時會自動去重。
`config.sh` 的 `VOCAB` 留空就是從這份衍生；手動填的話以 `VOCAB` 為準。

## 編輯一次，它就記住了

歷史紀錄裡按「編輯」改完存檔後，如果改的是**換詞**（不是加標點或整句改寫），
會跳出來問要不要記住。按「加進詞彙表」就寫進去，下次辨識到就自動改。

規則會**自動帶前後文**，不會產生「祥→翔」這種會誤傷的單字規則
（那樣講「吉祥」會變成「吉翔」）。實際產生的是 `林國祥→林國翔`、`平安站→平安棧`
這種帶上下文的規則。句首的字前面沒東西可抓時會往後抓，至少湊到兩個字。

只認替換，這些不會問你：
- 純粹補標點（`今天天氣不錯` → `今天天氣不錯。`）
- 整句改寫（`我覺得可以` → `我覺得應該可以先做一個版本看看再說`）
- 沒有變動

## 貼不進去的時候

焦點不在輸入框（按鈕、清單、桌面…）時不會硬貼，文字會**留在剪貼簿**並跳出提示，
切到要貼的地方按 ⌘V 就好。密碼欄位是硬性排除的，不會把口述內容貼進去。

判斷方式是反向的——只有在明確認出「這裡不可能打字」時才不貼。
實測 Claude 桌面版（Electron）回報 `AXGroup`、`AXValue 不可寫`，但明明就能打字；
網頁 app 幾乎都這樣。用白名單會把一大堆正常情況擋掉，比原本的問題更糟。

## 設定

`~/.config/voicetype/config.sh`，改完存檔即生效。

- `MIC_NAME` — 麥克風**名稱**不是索引。接耳機時裝置索引會整個跑掉，用名稱才不會錄到錯的孔。
  查名稱：`ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A9 "audio devices"`
- `VOCAB` — 熱詞表。人名、品牌、專有名詞寫進去可大幅改善辨識（已預填你常用的）。
  逗號分隔，建議 30 個以內，太長會拖慢辨識。
- `AUTO_PASTE=0` — 只複製到剪貼簿不自動貼上（某些 App 不吃模擬按鍵時用）。
- `STYLE` — 預設風格。
- `MIN_LEVEL` — 音量閘門（預設 -60 dB）。實測數字：數位靜音 -91、安靜房間 -41、正常說話 -15。
  設得寬鬆是刻意的，只擋「完全沒訊號」，不擋安靜房間。

API key 存在 macOS Keychain，不在純文字檔裡。要換：`./set-key.sh`

## 指令列用法

```bash
./vt.sh toggle [風格]    # 開始/結束
./vt.sh cancel           # 取消
./vt.sh status           # 看狀態
./vt.sh redo prompt      # 上一段換風格重新修稿
./vt.sh rescan           # 換耳機後重新解析麥克風
./vt.sh server-start     # 手動熱機（Hammerspoon 開機會自動做）
./vt.sh test             # 檢查環境
```

## 兩道防幻覺的閘門

Whisper 對靜音或極小聲的輸入會**生出訓練資料裡的 YouTube 字幕署名**——實測按了熱鍵沒說話，
它吐出 `中文字幕志愿者 杨茜茜`。對聽寫工具來說這很危險，會直接貼進你的文件。

1. **音量閘**：錄音平均音量低於 `MIN_LEVEL`（-60dB）就不送進 whisper。
   特別處理 -91dB（純數位靜音）——那幾乎一定是麥克風權限沒給，會明講而不是含糊說「沒聽到」。
   −91dB 時會分辨兩種原因：偵測到 Zoom／Teams／QuickTime 等在跑就說「麥克風被 X 佔用」，
   否則說「檢查權限」。兩種情況 ffmpeg 都是 exit 0 不報錯，症狀一模一樣，所以要主動分辨。
2. **幻覺過濾**：擋掉 `字幕志願者`、`Amara.org`、`请不吝点赞订阅`、`明镜与点点栏目`、
   `优优独播剧场` 這些招牌句。

過濾器刻意做得保守——寧可漏掉一次幻覺，也不要吃掉你真正說的話。所以有長度限制，
「那個字幕志願者的名單要更新一下」「這個活動由社區提供場地」這種正常句子會放行。
（第一版寫太兇，把「字幕組真的很辛苦」也擋了，改過了。）

## 為什麼錄音不用 ffmpeg

**Homebrew 的 ffmpeg 是 ad-hoc 簽章、沒有 TeamIdentifier，macOS 不會給它麥克風。**
而且是靜默拒絕：exit 0、檔案照產生、完全不報錯，內容卻是一串零（-91dB）。
母程序（Hammerspoon、終端機）明明在系統設定的麥克風清單裡而且是開的，子程序照樣拿不到——
授權不會沿著這條鏈傳下去，因為 ffmpeg 的簽章身分跟母程序不同。

所以錄音交給 `recorder/VoiceTypeRec.app`：一個自己做的 app bundle，有 `Info.plist`、
有 `NSMicrophoneUsageDescription`、有穩定的 bundle identifier，macOS 才認得它、
才會跳授權、才會出現在系統設定裡。它用 AVFoundation 的 `AVCaptureSession` 錄音。

**ffmpeg 還在用，但只拿來轉檔**（轉成 whisper 要的 16kHz 單聲道）——那不需要麥克風權限。

改過 `recorder/main.swift` 之後跑 `recorder/build.sh` 重建。

## 錄到 -91dB（純數位靜音）怎麼查

這是最陰險的失敗：ffmpeg exit 0、檔案正常產生、完全不報錯，但內容是一串零。三個可能：

1. **其他 App 獨佔麥克風** — 視訊會議最常見。`vt.sh` 會偵測並在通知裡點名。
   手動查：`ps -axo comm= | grep -iE "zoom|teams|webex|QuickTime"`
2. **權限沒給** — 系統設定 → 隱私權與安全性 → 麥克風，看 VoiceTypeRec 有沒有開。
   `./vt.sh test` 會直接告訴你授權狀態。
3. **CoreAudio 卡住** — 連續快速開關裝置後偶爾會這樣。登出再登入，或重開機。

診斷指令：
```bash
ffmpeg -f avfoundation -i ":0" -ar 16000 -ac 1 -c:a pcm_s16le -t 3 -y /tmp/t.wav
ffmpeg -hide_banner -nostats -loglevel info -i /tmp/t.wav -af volumedetect -f null - 2>&1 | grep volume
```
參考值：**-91dB = 沒訊號**、**-41dB = 安靜房間**、**-15dB = 正常說話**。

## 換成自己的 Logo

放這兩個檔案就會生效，不用改程式：

| 檔案 | 規格 | 用在哪 |
|---|---|---|
| `~/.config/voicetype/logo.png` | 512×512 PNG，透明背景 | 設定視窗標頭 |
| `~/.config/voicetype/menubar.png` | 44×44 PNG，**純黑＋透明** | 選單列 |

⚠️ 選單列那張一定要是**單色**（純黑，其餘透明）。macOS 的 template 模式會自動
處理深色／淺色選單列的反色——放彩色圖的話，在深色選單列上會變成一團黑。

改完從選單列點「重新載入設定」。內建的圖示是用 `assets/make-logo.py` 產的，
想調整波形或顏色可以改那個腳本重跑。

## 需要的系統權限

系統設定 → 隱私權與安全性：

- **麥克風** → Hammerspoon
- **輔助使用** → Hammerspoon（模擬 ⌘V 貼上、攔截 Esc 用）

⚠️ 麥克風權限是**跟著啟動錄音的那個程式**走的。ffmpeg 是 Hammerspoon 叫起來的，
所以要給權限的是 Hammerspoon，不是 ffmpeg 也不是終端機。
如果改用 launchd 之類的方式啟動，會錄到一片靜音而且**完全不報錯**。

## 幾個踩過的坑

- **不能 `kill -9` ffmpeg**。強殺會讓 WAV 檔尾沒寫完，whisper 直接讀不了。
  要用 `kill -INT` 然後等它自己收乾淨——`vt.sh` 裡是這樣做的。
- **不要用 `keystroke` 直接打中文**。中文輸入法開著的時候會打出一堆亂碼。
  只有「丟剪貼簿 + ⌘V」這條路可靠。
- **貼完會還原剪貼簿**。不然你複製到一半的東西會被默默吃掉。
  注意只還原得了文字——如果你剛剛複製的是圖片或檔案，會被換成純文字。
- **whisper 的 `-l zh` 幾乎都吐簡體**，initial prompt 也壓不太住。
  不要在辨識階段跟它拚，反正後面本來就要過一次 DeepSeek，簡轉繁合併在同一個 prompt 處理。
- **macOS 內建 awk 不能拿來比對中文字串**。onetrue-awk 20200816 對非 ASCII 的 `==`
  一律回真——`awk -v n="蘋果" 'BEGIN{print ("香蕉"==n)}'` 印出 `1`。ASCII 正常，只有非 ASCII 中招，
  強制字串語境 `($2"")==(n"")` 也救不了。這個 bug 害麥克風名稱比對抓到完全錯的裝置而且不報錯，
  現在改用 shell 的 `while IFS= read` + `[ "$a" = "$b" ]`。
- **BSD sed 不支援 `\+`**，`[0-9]\+` 會被當成字面的加號，要寫 `[0-9][0-9]*`。
  RHS 也不展開 `\t`。同樣是靜默失敗——比對不到就回空字串，然後預設值把它蓋掉。
- **bash 展開變數遇到中文標點要加大括號**。`"$MIC_NAME」"` 會被當成變數名 `MIC_NAME」`
  （bash 把 CJK 位元組當識別字的一部分），要寫 `"${MIC_NAME}」"`，否則 `set -u` 直接炸。
- **裝置索引要快取**。每次錄音前跑 `ffmpeg -list_devices` 要 0.2-0.4 秒，會吃掉你的第一個字，
  而且短按熱鍵時 `stop` 可能跑在 `start` 寫 PID 檔之前，變成假的「沒錄到聲音」。
  現在快取在 `~/.cache/voicetype/mic_index`，`start` 只要 **19ms**。換麥克風按選單列的「重新掃描」。
- **ffmpeg 開麥克風有 ~0.75 秒暖機**，這段時間說的話收不到。所以提示音改成等 WAV 真的
  開始長大才響——提示音才是誠實的「可以說了」訊號。**聽到「叮」再開口**。
- **`volumedetect` 的輸出是 info 等級**，用 `-v error` 會連它一起濾掉，量到的永遠是空字串，
  然後音量閘等於沒作用。要用 `-loglevel info`。
- **麥克風權限沒給時 ffmpeg 不報錯**，只是給你一串零（-91dB）。這是最陰險的一種失敗，
  因為 exit code 是 0、檔案也正常產生。所以才需要音量閘去主動抓。
- **拖曳要用全域 eventtap，不能用 canvas 自己的 `trackMouseMove`**。滑鼠拖快一點會跑出
  面板範圍，canvas 的追蹤就斷了，面板黏在半路。而且移動時要讀事件自己的 `e:location()`，
  不要另外去問 `hs.mouse.absolutePosition()`——那有延遲會抖。
- **`hs.canvas:behavior()` 吃的是整數**，要傳 `{"canJoinAllSpaces"}` 這種字串表得用
  `behaviorAsLabels()`。傳錯不會在載入時爆，是在第一次建立面板時才爆。
- **`⌥⌘Space` 綁不到**。macOS 自己用了（Finder 搜尋視窗），`hs.hotkey.bind` 回傳 nil
  但不報錯。實測可用：`⌃⌥Space`、`⌃⌘Space`、`⌥⌘` 加字母。
  現在綁不到的熱鍵會在啟動時跳通知列出來。
- **兩個功能設同一組熱鍵，後綁的會靜默失敗**。設定視窗會擋下來不讓存。
- **`hs.webview` 按紅點關閉時物件會被銷毀**，變數還指著死掉的視窗的話，
  下次開啟會走「已經有視窗」的提前返回而什麼都不做——症狀是關過一次就再也叫不出來。
- **不要用 heredoc 餵 python 腳本又想從 stdin 讀資料**。腳本本身把 stdin 用掉了，
  要處理的文字讀不到，結果是整段輸出憑空消失。改用 `-c` 加檔案參數。
- **模型要常駐**。每次重新載入 `large-v3-turbo` 要多花 0.6 秒以上，
  用 `whisper-server` 留在記憶體裡，推論才會是 0.8 秒而不是 1.4 秒。

## 檔案

安裝後：

```
~/.local/share/voicetype/
  vt.sh                    引擎：錄音 → 辨識 → 修稿 → 貼上
  set-key.sh               把 DeepSeek key 存進 Keychain
  uninstall.sh             移除
  recorder/
    main.swift             錄音器原始碼
    build.sh               改完 swift 跑這個重建
    VoiceTypeRec.app       有 bundle 才拿得到麥克風權限的錄音器

~/.hammerspoon/
  init.lua                 只會被加一行 require("voicetype")，你原本的設定不動
  voicetype.lua            熱鍵、選單列、錄音面板、設定視窗
  voicetype_ui.html        歷史紀錄與設定的介面

~/.config/voicetype/
  config.sh                麥克風、模型、熱詞表、風格、音量閘
  hotkeys.json             熱鍵
  corrections.txt          修正字典

~/.cache/voicetype/
  models/                  辨識模型（1.5GB）
  history.jsonl            歷史紀錄
  vt.log                   記錄，出問題先看這個
  panel_pos                錄音面板的位置
```

## 開發

這個 repo 就是原始碼。改完跑 `./install.sh` 就會裝到上面那些位置
（設定檔不會被蓋掉）。改過 `recorder/main.swift` 要另外跑 `recorder/build.sh`。
