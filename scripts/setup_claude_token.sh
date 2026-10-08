#!/bin/bash
# One-time setup: mint a long-lived Claude subscription token so CodelightPro
# can show your *official* 5h / weekly usage % (same data as `claude /status`).
#
# It runs `claude setup-token` (opens a browser to authorize), then you paste
# the printed token here. We save it to ~/.codelightpro/token (chmod 600).
set -euo pipefail

echo "▶ 即将运行 'claude setup-token'，会打开浏览器让你授权。"
echo "  授权完成后，终端会打印一个以 sk-ant-oat... 开头的 token。"
echo

if command -v claude >/dev/null 2>&1; then
    claude setup-token || true
else
    echo "⚠️  未在 PATH 找到 claude，可手动运行后再回到这里粘贴 token。"
fi

echo
read -r -p "把上面打印的 token 粘贴到这里，然后回车： " TOKEN
TOKEN="$(echo -n "$TOKEN" | tr -d '[:space:]')"

if [ -z "$TOKEN" ]; then
    echo "❌ 没有读到 token，已取消。"
    exit 1
fi

mkdir -p "$HOME/.codelightpro"
printf '%s' "$TOKEN" > "$HOME/.codelightpro/token"
chmod 600 "$HOME/.codelightpro/token"

echo "✅ 已保存到 ~/.codelightpro/token"
echo "   CodelightPro 会在下次刷新（最多 60 秒）后显示 Claude 官方用量。"
