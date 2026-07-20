#!/bin/sh
# rime 詞庫站(8790)啟動 wrapper — cron @reboot 與 */5 自癒共用。 (added 2026-07-20)
# 對外:CT203 Caddy → 既有 CF Tunnel → rime.lailai74143.com(F1 雲端同步鍵/管理網頁的後端)。
# server.js 需 EDIT_TOKEN/PORT,故先 source env(不落 argv);資料走 __dirname 故 cd 到專案。
# flock -n 保單實例;另加埠檢查防呆:過渡期舊 hl-detach 實例仍在聽 8790 時 no-op,
#   等重開機埠釋放後由本 wrapper 乾淨接管(避免撞 EADDRINUSE 空轉)。
PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin
export PATH
STATE=/home/codex/.local/state/rime-dict
mkdir -p "$STATE"

# 已在聽就不動(涵蓋舊實例過渡期 + cron 競態)
ss -ltn 2>/dev/null | grep -q ':8790 ' && exit 0

set -a
. /home/codex/.config/homelab/rime-dict.env
set +a
cd /home/codex/workspace/rime-cloud-dict || exit 1
exec /usr/bin/flock -n "$STATE/.lock" \
    /usr/bin/node server.js >> "$STATE/dict.log" 2>&1
