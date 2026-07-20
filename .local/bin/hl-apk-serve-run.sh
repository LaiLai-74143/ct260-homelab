#!/bin/sh
# Trime APK 交付站(8899)啟動 wrapper — cron @reboot 與 */5 自癒共用。 (added 2026-07-20)
# ⚠ 開發用(魔改 Trime 迭代期間手機下載新版 APK 用);純 LAN、低敏。
#   F2/F3 收尾、不再頻繁出版後可移除本 wrapper 與對應 cron 兩行。
# 目錄列表服務,cwd = 產物目錄;flock -n 保單實例 + 埠檢查防呆(同 rime-dict)。
PATH=/usr/local/bin:/usr/sbin:/usr/bin:/bin
export PATH
STATE=/home/codex/.local/state/apk-serve
OUTDIR=/mnt/coldstore/android/out
mkdir -p "$STATE"

[ -d "$OUTDIR" ] || exit 0
ss -ltn 2>/dev/null | grep -q ':8899 ' && exit 0

cd "$OUTDIR" || exit 1
exec /usr/bin/flock -n "$STATE/.lock" \
    /usr/bin/python3 -m http.server 8899 --bind 0.0.0.0 >> "$STATE/apk.log" 2>&1
