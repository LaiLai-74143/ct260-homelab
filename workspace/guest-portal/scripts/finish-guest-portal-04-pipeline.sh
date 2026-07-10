#!/bin/bash
# finish-guest-portal-04-pipeline.sh — 安裝資料管線腳本到 ~/.local/bin + 掛 cron(CT260)。
#
# 在哪跑:CT260 一般使用者身份(codex):
#   bash ~/workspace/guest-portal/scripts/finish-guest-portal-04-pipeline.sh
#
# 前置:段B(CT205 存在)。安裝後:
#   1) hl-guest add <username> [記賬人名]   建帳號(自動推 guest.json)
#   2) 之後 cron 每 30 分同步、每 5 分查登入異常
# 冪等:重跑=覆蓋腳本 + 去重 cron。
set -euo pipefail

SRC=~/workspace/guest-portal/scripts
BIN=~/.local/bin
mkdir -p "$BIN"

echo "== 1. 安裝三腳本到 $BIN =="
for f in hl-guest hl-write-guest hl-guest-watch; do
    install -m 755 "$SRC/$f" "$BIN/$f"
    echo "   ✓ $BIN/$f"
done

echo "== 2. cron(去重後重寫本工具三行)=="
# 取出既有 crontab(無則空),濾掉本工具舊行,再補新行
CUR=$(crontab -l 2>/dev/null | grep -v 'hl-write-guest' | grep -v 'hl-guest-watch' || true)
LOCK=~/.local/state/homelab-notify
{
    echo "$CUR"
    echo "# guest-portal 資料同步(推不是拉;flock 防重疊)"
    echo "*/30 * * * * flock -n $LOCK/.guest-write.lock $BIN/hl-write-guest >/dev/null 2>&1"
    echo "# guest-portal 登入異常哨兵"
    echo "*/5 * * * * flock -n $LOCK/.guest-watch.lock $BIN/hl-guest-watch >/dev/null 2>&1"
} | sed '/^$/d' | crontab -
echo "   ✓ cron 已更新:"
crontab -l | grep -E 'hl-write-guest|hl-guest-watch' | sed 's/^/     /'

echo
echo "✅ 管線就緒。接著:"
echo "   hl-guest add <username> [記賬人名]   # 建第一個帳號,密碼會印出一次"
echo "   hl-guest list                        # 檢視"
echo "   hl-write-guest --dry-run             # 手動驗一次(不推送,看資料對不對)"
