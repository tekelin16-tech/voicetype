#!/bin/bash
# 移除 VoiceType
set -uo pipefail
B=$'\033[1m'; G=$'\033[32m'; D=$'\033[2m'; N=$'\033[0m'
DEST="$HOME/.local/share/voicetype"; CACHE="$HOME/.cache/voicetype"
CONF="$HOME/.config/voicetype"; HS="$HOME/.hammerspoon"

echo ""
echo "${B}移除 VoiceType${N}"
echo ""
echo "會刪除："
echo "  $DEST"
echo "  $CACHE  ${D}(含 1.5GB 辨識模型)${N}"
echo "  $HS/voicetype.lua  ${D}以及 init.lua 裡的 require 那一行${N}"
echo "  Keychain 裡的 DeepSeek key"
echo ""
echo "${D}會保留 $CONF/config.sh（你的設定），要的話自己刪。${N}"
echo "${D}Homebrew 裝的 whisper-cpp / ffmpeg / jq / Hammerspoon 不會動——${N}"
echo "${D}別的東西可能在用，要移除請自己 brew uninstall。${N}"
echo ""
printf "確定要移除嗎？[y/N] "; read -r a
case "$a" in [yY]*) ;; *) echo "取消"; exit 0;; esac

pkill -f "whisper-server .*8178" 2>/dev/null
pkill -f "VoiceTypeRec.app" 2>/dev/null
rm -rf "$DEST" "$CACHE"
rm -f "$HS/voicetype.lua" "$HS/voicetype_ui.html"
if [ -f "$HS/init.lua" ]; then
  # 只拿掉我們加的那兩行，其他保持原狀
  python3 - "$HS/init.lua" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
s = re.sub(r'\n*-- VoiceType 語音聽寫\nrequire\("voicetype"\)\n', '\n', s)
s = re.sub(r'\n*require\("voicetype"\)\n', '\n', s)
open(p, 'w', encoding='utf-8').write(s)
PY
  echo "  已從 init.lua 移除 require"
fi
security delete-generic-password -s voicetype-deepseek >/dev/null 2>&1 && echo "  已刪除 Keychain 裡的 key"
osascript -e 'tell application "Hammerspoon" to reload config' >/dev/null 2>&1 || pkill -x Hammerspoon
echo ""
echo "${G}已移除${N}"
echo "${D}系統設定 → 隱私權與安全性 → 麥克風 裡的 VoiceTypeRec 項目要自己關掉。${N}"
echo ""
