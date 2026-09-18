#!/bin/bash
# 建立 VoiceType.app — 一個放在「應用程式」裡可以點的啟動器。
#
# 它本身不做事，只是叫 Hammerspoon 打開設定視窗（hammerspoon:// URL scheme）。
# 為什麼需要它：VoiceType 是跟著 Hammerspoon 跑的模組，不是獨立 App，
# 所以 Launchpad 裡本來什麼都沒有。使用者會去那裡找，找到的卻是背景用的
# VoiceTypeRec（那個刻意沒有視窗），點了沒反應，只會以為壞了。
set -e
cd "$(dirname "$0")"
SRC="$PWD"
APP="${1:-$HOME/Applications/VoiceType.app}"
LOGO="$SRC/../assets/logo.png"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VoiceType</string>
  <key>CFBundleDisplayName</key><string>VoiceType</string>
  <key>CFBundleIdentifier</key><string>place.unlimited.voicetype.launcher</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLEOF

cat > "$APP/Contents/MacOS/launcher" <<'LEOF'
#!/bin/bash
# 叫 Hammerspoon 開啟 VoiceType 的視窗。Hammerspoon 沒在跑就先起它。
if ! pgrep -x Hammerspoon >/dev/null 2>&1; then
  open -a Hammerspoon
  sleep 3
fi
open "hammerspoon://voicetype"
LEOF
chmod +x "$APP/Contents/MacOS/launcher"

# logo.png → icon.icns
if [ -f "$LOGO" ]; then
  ICONSET=$(mktemp -d)/icon.iconset
  mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "$LOGO" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1
    sips -z $((sz*2)) $((sz*2)) "$LOGO" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/icon.icns" 2>/dev/null
  rm -rf "$(dirname "$ICONSET")"
fi

codesign --force --sign - "$APP" 2>/dev/null || true
# Finder / Launchpad 有時會抓著舊的圖示不放，戳一下讓它重讀
touch "$APP"
echo "✓ 已建立 $APP"
