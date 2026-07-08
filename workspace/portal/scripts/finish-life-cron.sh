#!/bin/bash
# finish-life-cron.sh — 待辦49 M2:CT260 crontab 追加 hl-write-life(*/30)
# 冪等:已存在該行則跳過;追加前備份 crontab 到 ~/_backups/。
set -euo pipefail
mkdir -p ~/_backups
crontab -l > ~/_backups/crontab.before-life-$(date +%Y%m%d_%H%M%S)
if crontab -l | grep -q hl-write-life; then
  echo "cron 已存在,跳過"
else
  (crontab -l; echo '*/30 * * * * /usr/bin/flock -n /home/codex/.local/state/homelab-notify/.life.lock /home/codex/.local/bin/hl-write-life >/dev/null 2>&1') | crontab -
  echo "cron 已追加"
fi
crontab -l | grep hl-write-life
