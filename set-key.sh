#!/bin/bash
# 把 DeepSeek API key 存進 macOS Keychain（不會留在 shell 記錄或純文字檔裡）
read -r -s -p "貼上 DeepSeek API key（輸入時不會顯示）: " K; echo
[ -z "$K" ] && { echo "沒有輸入，取消"; exit 1; }
security delete-generic-password -s voicetype-deepseek >/dev/null 2>&1
security add-generic-password -a "$USER" -s voicetype-deepseek -w "$K" && echo "已存入 Keychain"
echo -n "測試中… "
R=$(curl -s -m 30 https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $K" \
  -d '{"model":"deepseek-flash","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}')
if echo "$R" | grep -q '"choices"'; then echo "可用 ✓"
else echo "失敗 ✗"; echo "$R" | head -c 300; echo; exit 1; fi
