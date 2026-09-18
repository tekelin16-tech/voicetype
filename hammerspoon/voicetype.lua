-- ============================================================
--  VoiceType — 語音聽寫（whisper.cpp 辨識 + DeepSeek 修稿）
--
--  這是一個模組，不是你的 init.lua。安裝程式會在 ~/.hammerspoon/init.lua
--  末尾加一行 require("voicetype")，所以你原本的 Hammerspoon 設定不會被動到。
--  要停用就把那一行註解掉，再從選單列 Reload。
--
--  ⌥Space   按住說話，放開轉錄；短按一下改成「鎖定錄音」，再按一下結束
--  ⌥⇧Space  切換錄音（長篇口述）
--  ⌥⌘Space  選這次要用的修稿風格
-- ============================================================

-- 極輕量的記錄，寫進跟 shell 端同一份 log，方便對照時間軸
local function vtlog(t)
  local f = io.open(os.getenv("HOME") .. "/.cache/voicetype/vt.log", "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. "[hs] " .. tostring(t) .. "\n"); f:close() end
end

local HOME     = os.getenv("HOME")
local VT       = HOME .. "/.local/share/voicetype/vt.sh"
local HK_FILE  = HOME .. "/.config/voicetype/hotkeys.json"
local UI_HTML  = HOME .. "/.hammerspoon/voicetype_ui.html"

-- 圖示：使用者自己的優先，否則用內建的。放這兩個檔就會換掉：
--   ~/.config/voicetype/logo.png      512x512 PNG，透明背景
--   ~/.config/voicetype/menubar.png   44x44 PNG，純黑＋透明（選單列會自動反色）
local function findAsset(name)
  for _, dir in ipairs({ HOME .. "/.config/voicetype/", HOME .. "/.local/share/voicetype/assets/" }) do
    local f = io.open(dir .. name, "r")
    if f then f:close(); return dir .. name end
  end
  return nil
end
local LOGO_PATH    = findAsset("logo.png")
local MENUBAR_PATH = findAsset("menubar.png")

-- 熱鍵可以在設定視窗裡改，存成 JSON。改完要 hs.reload() 才會生效。
-- 注意：alt+cmd+space 被 macOS 佔走（Finder 搜尋視窗），hs.hotkey.bind 會回傳 nil
-- 而且不報錯。實測可用的有 ctrl+alt+space、ctrl+cmd+space、alt+cmd+[vjkh]。
local DEFAULT_HK = { push = "alt+space", toggle = "alt+shift+space",
                     style = "ctrl+alt+space", ui = "alt+cmd+h" }

local function readHotkeys()
  local f = io.open(HK_FILE, "r")
  if not f then return DEFAULT_HK end
  local ok, t = pcall(hs.json.decode, f:read("*a")); f:close()
  if not ok or type(t) ~= "table" then return DEFAULT_HK end
  for k, v in pairs(DEFAULT_HK) do if not t[k] or t[k] == "" then t[k] = v end end
  return t
end

-- "alt+shift+space" → {"alt","shift"}, "space"
local function parseHK(str)
  local parts, mods, key = {}, {}, nil
  for w in tostring(str):gmatch("[^+]+") do parts[#parts + 1] = w end
  key = table.remove(parts)
  for _, m in ipairs(parts) do mods[#mods + 1] = m end
  return mods, key
end

local HK = readHotkeys()
local boundHotkeys = {}   -- 擷取新熱鍵時要能把這些暫時關掉
local hkFailed = {}       -- 綁不到的熱鍵，最後統一通知使用者

-- hs.hotkey.bind 在組合被系統或別的 app 佔走時「回傳 nil 且不報錯」。
-- 沒有這層包裝的話，使用者只會發現某個熱鍵按了沒反應，完全查不出原因。
local function bindHK(label, str, ...)
  local mods, key = parseHK(str)
  local hk = hs.hotkey.bind(mods, key, ...)
  if hk then boundHotkeys[#boundHotkeys + 1] = hk
  else hkFailed[#hkFailed + 1] = label .. "（" .. tostring(str) .. "）" end
  return hk
end
local TAP_MAX  = 0.35   -- 秒：低於這個時間放開 = 鎖定錄音，不是誤觸
local style    = "default"

local STYLES = {
  { key = "default", name = "一般",   desc = "補標點、去贅字、繁體台灣用語" },
  { key = "prompt",  name = "AI 指令", desc = "整理成條理清楚的指令敘述" },
  { key = "message", name = "訊息",   desc = "口語自然，給 LINE / 即時通訊" },
  { key = "email",   name = "信件",   desc = "書面語、禮貌得體、適當分段" },
  { key = "note",    name = "筆記",   desc = "條列重點，保留所有資訊" },
  { key = "raw",     name = "原始",   desc = "不經 DeepSeek，直接吐辨識結果" },
}

-- 狀態機：idle / holding / latched / working
-- 前向宣告：這兩個要在下面很前面的地方就被呼叫，但實作在檔案後段
-- （用全域可以繞過，但會污染 Hammerspoon 命名空間、可能跟別人的設定撞名）
local escOn, escOff

local state = "idle"
local pressedAt = 0

----------------------------------------------------------------
-- 選單列指示器
----------------------------------------------------------------
local bar = hs.menubar.new()

local function styleName()
  for _, s in ipairs(STYLES) do if s.key == style then return s.name end end
  return style
end

local menubarIcon
if MENUBAR_PATH then
  local img = hs.image.imageFromPath(MENUBAR_PATH)
  -- template(true) 讓 macOS 自己處理深色／淺色選單列的反色。
  -- 沒設的話彩色圖在深色選單列上會變成一團黑。
  if img then menubarIcon = img:setSize({ w = 18, h = 18 }):template(true) end
end

local function render()
  if not bar then return end
  local label = ({ idle = "", holding = " 錄音中", latched = " 錄音中(鎖定)", working = " 轉錄中" })[state] or ""
  if menubarIcon then
    bar:setIcon(menubarIcon)
    bar:setTitle(label ~= "" and label or nil)
  else
    local emoji = ({ idle = "🎙", holding = "🔴", latched = "🔴", working = "⏳" })[state] or "🎙"
    bar:setTitle(emoji .. label)
  end
  bar:setTooltip("VoiceType — 風格：" .. styleName())
end


----------------------------------------------------------------
-- 正中央的錄音介面
-- 音量條畫的是「真實」音量（vtrec 每 50ms 寫進音量檔），不是裝飾動畫。
-- 這樣一眼就看得出麥克風有沒有真的收到聲音——之前被靜默錄成一串零坑過。
----------------------------------------------------------------
local LEVEL_FILE = os.getenv("HOME") .. "/.cache/voicetype/level"
local POS_FILE   = os.getenv("HOME") .. "/.cache/voicetype/panel_pos"
local BARS       = 28
local W, H       = 300, 96

local panel, panelTimer, startedAt, dragWatcher, dragOrigin, hintTimer

local function savePos(f)
  local h = io.open(POS_FILE, "w")
  if h then h:write(string.format("%d %d", math.floor(f.x), math.floor(f.y))); h:close() end
end

local function loadPos()
  local h = io.open(POS_FILE, "r"); if not h then return nil end
  local x, y = h:read("*a"):match("(-?%d+)%s+(-?%d+)"); h:close()
  if not x then return nil end
  x, y = tonumber(x), tonumber(y)
  -- 換過螢幕或解析度時存的座標可能已經在畫面外，那就當作沒存過
  for _, scr in ipairs(hs.screen.allScreens()) do
    local f = scr:fullFrame()
    if x + W > f.x and x < f.x + f.w and y + H > f.y and y < f.y + f.h then
      return { x = x, y = y }
    end
  end
  return nil
end

-- 拖曳用全域 eventtap 而不是 canvas 的 trackMouseMove：
-- 拖快一點滑鼠會跑出面板範圍，canvas 自己的追蹤就斷了，面板會黏在半路。
local function startDrag(cv)
  local f = cv:frame()
  local m = hs.mouse.absolutePosition()
  local off = { x = m.x - f.x, y = m.y - f.y }
  dragOrigin = { x = f.x, y = f.y }
  if dragWatcher then dragWatcher:stop() end
  dragWatcher = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp },
    function(e)
      if e:getType() == hs.eventtap.event.types.leftMouseUp then
        if dragWatcher then dragWatcher:stop(); dragWatcher = nil end
        savePos(cv:frame())
        return false
      end
      -- 用事件自己帶的座標，不要另外去問滑鼠在哪：中間有延遲會抖，
      -- 而且合成事件不一定會真的移動游標。
      local p = e:location()
      cv:topLeft({ x = p.x - off.x, y = p.y - off.y })
      return true
    end)
  dragWatcher:start()
end
local hist = {}                      -- 音量歷史，由右往左捲動
for i = 1, BARS do hist[i] = 0 end

-- dBFS → 0..1。-50 以下當作無聲，-8 以上算滿格。
local function norm(db)
  if not db then return 0 end
  local v = (db + 50) / 42
  return math.max(0, math.min(1, v))
end

local function buildPanel()
  local saved = loadPos()
  local f
  if saved then
    f = { x = saved.x, y = saved.y, w = W, h = H }
  else
    local scr = hs.screen.mainScreen():frame()
    f = { x = scr.x + (scr.w - W) / 2, y = scr.y + (scr.h - H) / 2, w = W, h = H }
  end
  local c = hs.canvas.new(f)
  c:level(hs.canvas.windowLevels.overlay)
  c:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)
  c:alpha(1.0)

  c:appendElements({
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 18, yRadius = 18 },
      fillColor = { red = 0.05, green = 0.05, blue = 0.06, alpha = 0.99 },
      strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 1, withShadow = true,
      shadow = { blurRadius = 24, offset = { h = -4, w = 0 }, color = { alpha = 0.5 } },
      frame = { x = 0, y = 0, w = W, h = H } },
    { type = "circle", action = "fill", center = { x = 22, y = 22 }, radius = 5,
      fillColor = { red = 0.95, green = 0.25, blue = 0.25, alpha = 1 } },
    { type = "text", text = "錄音中", textSize = 13,
      textColor = { white = 1, alpha = 0.92 }, textFont = ".AppleSystemUIFontBold",
      frame = { x = 36, y = 13, w = 140, h = 20 } },
    { type = "text", text = "0:00", textSize = 12, textAlignment = "right",
      textColor = { white = 1, alpha = 0.5 },
      frame = { x = W - 74, y = 14, w = 56, h = 18 } },
  })
  -- 音量條
  local gap, bw = 3, 0
  bw = (W - 36 - (BARS - 1) * gap) / BARS
  for i = 1, BARS do
    c:appendElements({ type = "rectangle", action = "fill",
      roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
      fillColor = { white = 1, alpha = 0.75 },
      frame = { x = 18 + (i - 1) * (bw + gap), y = 56, w = bw, h = 2 } })
  end
  c:appendElements({
    { type = "text", text = "", textSize = 10, textAlignment = "center",
      textColor = { white = 1, alpha = 0.38 },
      frame = { x = 0, y = H - 22, w = W, h = 16 } },
  })
  -- 蓋在最上層的透明抓取層：面板上任何一點都能拖。放最後才不會動到前面的索引。
  c:appendElements({
    { type = "rectangle", action = "fill", fillColor = { alpha = 0.001 },
      trackMouseDown = true, frame = { x = 0, y = 0, w = W, h = H } },
  })
  c:mouseCallback(function(cv, ev) if ev == "mouseDown" then startDrag(cv) end end)
  return c
end

local HINT_IDX = 4 + BARS + 1        -- 底部提示那一格的索引

local function overlayUpdate()
  if not panel then return end
  local db
  local f = io.open(LEVEL_FILE, "r")
  if f then db = tonumber(f:read("*a")); f:close() end
  table.remove(hist, 1)
  hist[BARS] = norm(db)
  local maxH = 26
  for i = 1, BARS do
    local h = 4 + hist[i] * maxH
    panel[4 + i].frame = { x = panel[4 + i].frame.x, y = 56 - (h - 4) / 2,
                           w = panel[4 + i].frame.w, h = h }
    panel[4 + i].fillColor = { white = 1, alpha = 0.32 + hist[i] * 0.58 }
  end
  local el = math.floor(hs.timer.secondsSinceEpoch() - (startedAt or 0))
  panel[4].text = string.format("%d:%02d", math.floor(el / 60), el % 60)
end

local function overlayShow(hint)
  if hintTimer then hintTimer:stop(); hintTimer = nil end
  for i = 1, BARS do hist[i] = 0 end
  startedAt = hs.timer.secondsSinceEpoch()
  if not panel then panel = buildPanel() end
  panel[2].fillColor = { red = 0.95, green = 0.25, blue = 0.25, alpha = 1 }
  panel[3].text = "錄音中"
  panel[HINT_IDX].text = hint or ""
  panel:show()
  if panelTimer then panelTimer:stop() end
  panelTimer = hs.timer.doEvery(0.05, overlayUpdate)
end

local function overlayWorking()
  if not panel then return end
  if panelTimer then panelTimer:stop(); panelTimer = nil end
  panel[2].fillColor = { red = 1, green = 0.75, blue = 0.2, alpha = 1 }
  panel[3].text = "轉錄中…"
  panel[HINT_IDX].text = ""
  for i = 1, BARS do
    panel[4 + i].frame = { x = panel[4 + i].frame.x, y = 55, w = panel[4 + i].frame.w, h = 2 }
    panel[4 + i].fillColor = { white = 1, alpha = 0.22 }
  end
end

local function overlayHide()
  if panelTimer then panelTimer:stop(); panelTimer = nil end
  if panel then panel:hide() end
end

-- 貼不進去時的提示面板。沿用同一個面板，位置跟使用者拖到的地方一致。
-- 必須定義在 pasteOut 之前：Lua 的 local 要先宣告，之後的閉包才抓得到。
-- （hintTimer 宣告在最上面那排 local，不能放這裡——overlayShow 在更前面就要用到它，
--   放這裡的話那邊抓到的會是全域的 nil，計時器永遠取消不掉。）
local function showClipboardHint(txt, why)
  if not panel then panel = buildPanel() end
  if panelTimer then panelTimer:stop(); panelTimer = nil end
  panel[2].fillColor = { red = 0.35, green = 0.62, blue = 1, alpha = 1 }
  panel[3].text = "已複製到剪貼簿"
  -- 把講的內容也顯示出來，才知道是哪一段
  local preview = txt:gsub("%s+", " ")
  if utf8 and utf8.len and (utf8.len(preview) or 0) > 22 then
    preview = preview:sub(1, utf8.offset(preview, 23) - 1) .. "…"
  end
  for i = 1, BARS do
    panel[4 + i].frame = { x = panel[4 + i].frame.x, y = 55, w = panel[4 + i].frame.w, h = 2 }
    panel[4 + i].fillColor = { white = 1, alpha = 0.10 }
  end
  panel[4].text = ""
  panel[HINT_IDX].text = "切到要貼的地方，按 ⌘V　·　" .. (why or "")
  -- 借用音量條那一排的位置放預覽文字
  panel[5].frame = { x = 18, y = 44, w = W - 36, h = 20 }
  panel[5].fillColor = { alpha = 0 }
  panel:show()
  if hintTimer then hintTimer:stop() end
  hintTimer = hs.timer.doAfter(6, function() overlayHide() end)
  hs.notify.new({ title = "VoiceType", informativeText = "已複製到剪貼簿：" .. preview }):send()
end


----------------------------------------------------------------
-- 呼叫 vt.sh（非同步，不卡住 UI）
----------------------------------------------------------------
local ENV = {
  HOME = os.getenv("HOME"),
  PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
  VT_PASTE = "none",          -- 貼上由下面的 pasteOut() 做，不讓 vt.sh 用 osascript
}

local function vt(args, done)
  local t = hs.task.new("/bin/bash", function(code, out, err)
    if done then done(code, out or "", err or "") end
  end, hs.fnutils.concat({ VT }, args))
  t:setEnvironment(ENV)
  t:start()
  return t
end

-- 焦點在不在「能打字的地方」。
--
-- 這裡刻意用反向判斷（只擋明確不能打字的），不是正向白名單。
-- 實測 Claude 桌面版（Electron）回報 role=AXGroup、AXValue 不可寫，但明明就能打字；
-- 網頁 app 幾乎都這樣。用白名單會把一大堆正常情況擋掉，比原本的問題更糟。
local NO_TEXT = {
  AXButton = true, AXCheckBox = true, AXRadioButton = true, AXPopUpButton = true,
  AXMenuItem = true, AXMenuBarItem = true, AXMenu = true, AXMenuBar = true,
  AXImage = true, AXSlider = true, AXProgressIndicator = true, AXDisclosureTriangle = true,
  AXList = true, AXTable = true, AXOutline = true, AXRow = true, AXCell = true,
  AXWindow = true, AXToolbar = true, AXTabGroup = true, AXSheet = true,
}

local function pasteTarget()
  local ok, el = pcall(function()
    return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  if not ok or not el then return false, "沒有輸入焦點" end
  local role = el:attributeValue("AXRole")
  if role == "AXSecureTextField" then return false, "這是密碼欄位" end
  if NO_TEXT[role] then return false, "焦點不是輸入欄位（" .. tostring(role) .. "）" end
  return true, role
end

-- 貼上：用 hs.eventtap 而不是 osascript。
-- osascript 打 System Events 需要另一個「自動化」權限，第一次會跳對話框把整個流程卡住；
-- hs.eventtap 直接用 Hammerspoon 本來就需要的「輔助使用」權限，也快得多。
-- 中文一定要走剪貼簿＋⌘V，不能用 keyStrokes 直接打字，輸入法開著會變亂碼。
local function pasteOut(txt)
  if not txt or txt == "" then return end
  local canPaste, why = pasteTarget()
  if not canPaste then
    -- 貼不進去就把文字留在剪貼簿（不還原），讓使用者自己挑地方貼。
    -- 這時候絕對不能還原舊剪貼簿，不然辛苦講的那段就消失了。
    hs.pasteboard.setContents(txt)
    showClipboardHint(txt, why)
    return
  end
  local saved = hs.pasteboard.getContents()
  hs.pasteboard.setContents(txt)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  hs.timer.doAfter(0.6, function()
    if saved then hs.pasteboard.setContents(saved) end   -- 還原使用者原本複製的東西
  end)
end

local function startRec()
  vt({ "start", style }, function(code, out, err)
    if code ~= 0 then
      state = "idle"; render(); if escOff then escOff() end; overlayHide()
      hs.notify.new({ title = "VoiceType",
        informativeText = "錄音啟動失敗——檢查 Hammerspoon 的麥克風權限" }):send()
    end
  end)
end

local function stopRec()
  state = "working"; render(); if escOff then escOff() end; overlayWorking()
  vt({ "stop", style }, function(code, out, err)
    state = "idle"; render(); overlayHide()
    local txt = (out or ""):gsub("%s+$", "")
    if code == 0 and txt ~= "" then
      pasteOut(txt)
    else
      hs.notify.new({ title = "VoiceType", informativeText = "沒有辨識到內容" }):send()
    end
  end)
end

local function cancelRec()
  vt({ "cancel" })
  state = "idle"; render(); if escOff then escOff() end; overlayHide()
  vtlog("已取消錄音")
end

----------------------------------------------------------------
-- ⌥Space：按住說話 / 短按鎖定
----------------------------------------------------------------
bindHK("按住說話", HK.push,
  function()  -- 按下
    if state == "latched" then          -- 鎖定中，這一下是結束
      stopRec()
      state = "working"
    elseif state == "idle" then
      pressedAt = hs.timer.secondsSinceEpoch()
      state = "holding"; render()
      if escOn then escOn() end
      overlayShow("按住說話，放開結束")
      startRec()
    end
  end,
  function()  -- 放開
    if state ~= "holding" then return end
    if hs.timer.secondsSinceEpoch() - pressedAt < TAP_MAX then
      state = "latched"; render()       -- 短按 → 繼續錄，之後再按一下結束
      if panel then panel[HINT_IDX].text = "再按一下結束　·　Esc 取消" end
    else
      stopRec()
    end
  end)

----------------------------------------------------------------
-- ⌥⇧Space：單純切換
----------------------------------------------------------------
bindHK("切換錄音", HK.toggle, function()
  if state == "idle" then
    state = "latched"; render()
    if escOn then escOn() end
    overlayShow("再按一下結束　·　Esc 取消")
    startRec()
  elseif state == "latched" or state == "holding" then
    stopRec()
  end
end)

----------------------------------------------------------------
-- ⌥⌘Space：選風格
----------------------------------------------------------------
local chooser = hs.chooser.new(function(choice)
  if choice then style = choice.key; render()
    hs.notify.new({ title = "VoiceType", informativeText = "修稿風格：" .. choice.text }):send()
  end
end)
local rows = {}
for _, s in ipairs(STYLES) do
  table.insert(rows, { text = s.name, subText = s.desc, key = s.key })
end
chooser:choices(rows)
chooser:rows(#rows)

bindHK("選修稿風格", HK.style, function() chooser:show() end)

-- Esc 取消錄音。
-- 原本用 hs.eventtap 全域攔截，實測收不到 Esc（其他鍵收得到）。
-- 改成一個「平常停用、只在錄音期間啟用」的真熱鍵：hs.hotkey 走的是系統的
-- 熱鍵註冊機制，比自己攔事件可靠得多；而且沒在錄音時完全不碰 Esc，
-- 不會干擾其他程式。
local escHotkey = hs.hotkey.new({}, "escape", function()
  vtlog("Esc 觸發，state=" .. tostring(state))
  if state == "holding" or state == "latched" then cancelRec() end
end)

escOn  = function() if escHotkey then escHotkey:enable() end end
escOff = function() if escHotkey then escHotkey:disable() end end


----------------------------------------------------------------
-- 歷史紀錄 / 設定視窗
-- 用 hs.webview 而不是 hs.canvas：canvas 畫得出東西但沒有文字輸入框，
-- 編輯歷史紀錄、填熱詞表這些都做不了。
----------------------------------------------------------------
local uiWin, uiCtrl

-- 把 vt.sh 的輸出丟進網頁
local function pushToUI()
  if not uiWin then return end
  vt({ "history-get" }, function(_, hist)
    vt({ "config-get" }, function(_, conf)
      vt({ "corr-get" }, function(_, corr)
        local data = {
          history = (hs.json.decode(hist or "[]") or {}),
          config  = (hs.json.decode(conf or "{}") or {}),
        }
        data.config.hotkeys = readHotkeys()
        data.config.corrections = corr or ""
        if LOGO_PATH then
          local f = io.open(LOGO_PATH, "rb")
          if f then
            local bytes = f:read("*a"); f:close()
            data.config.logo = "data:image/png;base64," .. hs.base64.encode(bytes)
          end
        end
        local js = "window.vtReceive(" .. hs.json.encode(data) .. ")"
        if uiWin then uiWin:evaluateJavaScript(js) end
      end)
    end)
  end)
end

local function saveSettings(c)
  -- 設定檔的寫入交給 vt.sh，UI 不直接碰檔案
  local pairsToSet = {
    { "STYLE", c.style or "default" },
    { "MIC_NAME", c.mic or "" },
    { "SOUNDS", c.sounds and "1" or "0" },
    { "AUTO_PASTE", c.autopaste and "1" or "0" },
  }
  local i = 1
  local function next_()
    if i > #pairsToSet then
      -- 修正字典可能很長且有換行，用 stdin 餵給 vt.sh
      local t = hs.task.new("/bin/bash", nil, { VT, "corr-set" })
      t:setEnvironment(ENV); t:setInput(c.corrections or ""); t:start()
      -- 熱鍵存成 JSON，然後重載才會生效
      local f = io.open(HK_FILE, "w")
      if f then f:write(hs.json.encode(c.hotkeys or DEFAULT_HK)); f:close() end
      hs.timer.doAfter(0.4, function() hs.reload() end)
      return
    end
    local kv = pairsToSet[i]; i = i + 1
    vt({ "config-set", kv[1], kv[2] }, next_)
  end
  next_()
end


-- 擷取新熱鍵。
-- 不能讓網頁自己用 keydown 接：⌥Space 這類組合已經被 hs.hotkey 全域綁走，
-- 網頁根本收不到那個按鍵，使用者會覺得「點了沒反應」。
-- 所以擷取期間把既有熱鍵全部停用，改用 eventtap 直接接。
local captureTap, captureTimer
local function stopCapture()
  if captureTap then captureTap:stop(); captureTap = nil end
  if captureTimer then captureTimer:stop(); captureTimer = nil end
  for _, hk in ipairs(boundHotkeys) do pcall(function() hk:enable() end) end
end

local function startCapture()
  for _, hk in ipairs(boundHotkeys) do pcall(function() hk:disable() end) end
  if captureTap then captureTap:stop() end
  local MODS_ONLY = { cmd = true, alt = true, shift = true, ctrl = true,
                      rightcmd = true, rightalt = true, rightshift = true, rightctrl = true,
                      capslock = true, fn = true }
  captureTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local name = hs.keycodes.map[e:getKeyCode()]
    if not name then return true end
    if MODS_ONLY[name] then return true end          -- 只按修飾鍵，繼續等
    if name == "escape" then
      stopCapture()
      if uiWin then uiWin:evaluateJavaScript("window.vtCaptured(null)") end
      return true
    end
    local f = e:getFlags()
    local mods = {}
    if f.ctrl then mods[#mods + 1] = "ctrl" end
    if f.alt then mods[#mods + 1] = "alt" end
    if f.shift then mods[#mods + 1] = "shift" end
    if f.cmd then mods[#mods + 1] = "cmd" end
    if #mods == 0 then
      -- 沒有修飾鍵的話會攔截正常打字，不能接受
      if uiWin then uiWin:evaluateJavaScript("window.vtCaptureError()") end
      return true
    end
    local combo = table.concat(mods, "+") .. "+" .. name
    stopCapture()
    -- 直接組字串，不要用 hs.json.encode：它對「純字串」（非 table）的回傳不可靠，
    -- 送出去的 JS 會是壞的，網頁端就什麼都沒發生。combo 只有 [a-z+]，安全。
    if uiWin then uiWin:evaluateJavaScript('window.vtCaptured("' .. combo .. '")') end
    return true
  end)
  captureTap:start()
  -- 忘了按會一直停用熱鍵，10 秒自動放棄
  captureTimer = hs.timer.doAfter(10, function()
    stopCapture()
    if uiWin then uiWin:evaluateJavaScript("window.vtCaptured(null)") end
  end)
end

local function onUIMessage(msg)
  local b = (msg and msg.body) or {}
  local a, p = b.action, b.payload or {}
  if a == "ready" then pushToUI()
  elseif a == "save" then vt({ "history-edit", p.id, p.out })
  elseif a == "delete" then vt({ "history-del", p.id })
  elseif a == "copy" then hs.pasteboard.setContents(p.text or "")
  elseif a == "settings" then saveSettings(p)
  elseif a == "learn" then
    -- 把學到的條目接到詞彙表後面。走 stdin，內容可能有中文和箭號。
    local t = hs.task.new("/bin/bash", nil, { VT, "corr-add" })
    t:setEnvironment(ENV)
    t:setInput(table.concat(p.lines or {}, "\n") .. "\n")
    t:start()
  elseif a == "capture-start" then startCapture()
  elseif a == "capture-stop" then stopCapture()
  end
end

local function showUI()
  -- 關掉的視窗要能再叫出來：hs.webview 按紅點關閉時物件就被銷毀了，
  -- 但變數還指著那個死掉的東西，如果不清掉，之後 showUI 會走「已經有視窗」
  -- 的提前返回而什麼都不做——症狀就是「點了選單列沒反應」。
  if uiWin then
    local alive = pcall(function() return uiWin:hswindow() end)
    if alive and uiWin:hswindow() then
      uiWin:show():bringToFront(); pushToUI(); return
    end
    uiWin = nil; uiCtrl = nil
  end
  uiCtrl = hs.webview.usercontent.new("voicetype")
  uiCtrl:setCallback(onUIMessage)
  local scr = hs.screen.mainScreen():frame()
  uiWin = hs.webview.new(
    { x = scr.x + (scr.w - 780) / 2, y = scr.y + (scr.h - 600) / 2, w = 780, h = 600 },
    { developerExtrasEnabled = true }, uiCtrl)
  uiWin:windowTitle("VoiceType")
  uiWin:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
  uiWin:allowTextEntry(true)      -- 沒有這行，網頁裡的輸入框打不了字
  uiWin:darkMode(true)
  uiWin:url("file://" .. UI_HTML)
  uiWin:windowCallback(function(action)
    if action == "closing" then
      stopCapture()          -- 關窗時一定要把熱鍵放回來，否則整個工具就啞了
      uiWin = nil; uiCtrl = nil
    end
  end)
  uiWin:show():bringToFront()
end

bindHK("歷史紀錄與設定", HK.ui, showUI)

-- 讓「應用程式」裡的 VoiceType.app 可以叫出這個視窗。
-- 那個 app 只是執行 open "hammerspoon://voicetype"。
hs.urlevent.bind("voicetype", function() showUI() end)

----------------------------------------------------------------
-- 選單列點擊 = 手動選單
----------------------------------------------------------------
bar:setMenu(function()
  local m = {
    { title = "歷史紀錄與設定…", fn = showUI },
    { title = "-" },
    { title = "目前風格：" .. styleName(), disabled = true },
  }
  for _, s in ipairs(STYLES) do
    table.insert(m, { title = s.name .. "  —  " .. s.desc, checked = (s.key == style),
                      fn = function() style = s.key; render() end })
  end
  table.insert(m, { title = "-" })
  table.insert(m, { title = "重新修稿上一段（換目前風格）", fn = function()
      vt({ "redo", style }, function(code, out)
        local txt = (out or ""):gsub("%s+$", "")
        if code == 0 and txt ~= "" then
          hs.pasteboard.setContents(txt)
          hs.notify.new({ title = "VoiceType", informativeText = "已重新修稿，貼上即可用" }):send()
        else
          hs.notify.new({ title = "VoiceType", informativeText = "沒有上一段可以重做" }):send()
        end
      end) end })
  table.insert(m, { title = "錄音面板位置歸中", fn = function()
      os.remove(POS_FILE)
      if panel then panel:delete(); panel = nil end
      hs.notify.new({ title = "VoiceType", informativeText = "下次錄音會回到螢幕正中央" }):send()
    end })
  table.insert(m, { title = "重新掃描麥克風（換耳機後用）", fn = function()
      vt({ "rescan" }, function(code, out)
        hs.notify.new({ title = "VoiceType", informativeText = (out or ""):gsub("%s+$", "") }):send()
      end) end })
  table.insert(m, { title = "啟動辨識引擎（加速第一次）", fn = function() vt({ "server-start" }) end })
  table.insert(m, { title = "開啟記錄檔", fn = function()
      hs.execute("open -a Console ~/.cache/voicetype/vt.log") end })
  table.insert(m, { title = "重新載入設定", fn = function() hs.reload() end })
  table.insert(m, { title = "-" })
  local function hkLabel(str)
    local mods, key = parseHK(str)
    local sym = { cmd = "⌘", alt = "⌥", ctrl = "⌃", shift = "⇧" }
    local out = ""
    for _, mo in ipairs(mods) do out = out .. (sym[mo] or mo) end
    return out .. (key == "space" and "Space" or key:upper())
  end
  table.insert(m, { title = "按住說話　" .. hkLabel(HK.push), disabled = true })
  table.insert(m, { title = "切換錄音　" .. hkLabel(HK.toggle), disabled = true })
  table.insert(m, { title = "選風格　　" .. hkLabel(HK.style), disabled = true })
  table.insert(m, { title = "這個視窗　" .. hkLabel(HK.ui), disabled = true })
  return m
end)

render()

-- 開機把辨識引擎先熱起來，第一次聽寫就不用等載入模型
hs.timer.doAfter(3, function() vt({ "server-start" }) end)

-- 第一次安裝時把說明視窗打開。找不到介面是最容易讓人放棄的一關，
-- 與其等他自己發現選單列，不如直接開給他看。
if #hkFailed > 0 then
  hs.notify.new({ title = "VoiceType：這些熱鍵綁不到",
    informativeText = table.concat(hkFailed, "、") .. " — 已被系統或其他程式佔用，請到設定換一組",
    withdrawAfter = 0 }):send()
end

local FIRST_RUN = HOME .. "/.config/voicetype/.onboarded"
if not io.open(FIRST_RUN, "r") then
  local f = io.open(FIRST_RUN, "w"); if f then f:write(os.date()); f:close() end
  hs.timer.doAfter(2.5, showUI)
else
  hs.notify.new({ title = "VoiceType 已就緒",
    informativeText = "按住 " .. (HK.push and "⌥Space" or "") ..
                      " 說話　·　⌥⌘H 開啟歷史紀錄與設定" }):send()
end





