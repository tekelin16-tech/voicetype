#!/bin/bash
# 從零建出錄音器 app。改過 main.swift 之後跑這個。
#
# 為什麼一定要包成 app bundle：macOS 不給 ad-hoc 簽章的裸執行檔麥克風權限，
# 而且是靜默拒絕——照樣 exit 0、照樣產生檔案，內容卻是一串零。
# 有 Info.plist + NSMicrophoneUsageDescription + 穩定的 bundle id，系統才認得它。
set -e
cd "$(dirname "$0")"
APP="$PWD/VoiceTypeRec.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VoiceTypeRec</string>
  <key>CFBundleDisplayName</key><string>VoiceType 錄音器</string>
  <key>CFBundleIdentifier</key><string>place.unlimited.voicetype.rec</string>
  <key>CFBundleExecutable</key><string>vtrec</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>VoiceType 需要麥克風才能把你說的話轉成文字。</string>
</dict></plist>
PLEOF

swiftc -O -o "$APP/Contents/MacOS/vtrec" main.swift
codesign --force --sign - --identifier place.unlimited.voicetype.rec "$APP"
# 這是內部用的背景元件，不該出現在 Spotlight / Launchpad 的搜尋結果裡——
# 使用者會誤以為那就是主程式，點下去卻什麼都沒有（它刻意沒有視窗）。
touch "$(dirname "$APP")/.metadata_never_index"
echo "✓ 已建置: $APP"
