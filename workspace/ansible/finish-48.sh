#!/usr/bin/env bash
# finish-48.sh:待辦48 收尾——由使用者親自執行(auto-mode 分類器不允許 agent 直接改 crontab)。
# 作用:加一條每日 cron(23:15 Taipei = 15:15 UTC)跑 hl-ansible-backup,
#       趕在 23:30 hl-git-autocommit 之前,讓全站設定 diff 隨每日 commit 入庫。
# 冪等:已存在同款條目就跳過。
set -euo pipefail
LINE='15 15 * * * /usr/bin/flock -n /home/codex/.local/state/homelab-notify/.ansbak.lock /home/codex/.local/bin/hl-ansible-backup >/dev/null 2>&1'
COMMENT='# hl-ansible-backup: 每日全站設定唯讀入庫 (待辦#48) 23:15 Taipei == 15:15 UTC,趕在 autocommit 前'

if crontab -l 2>/dev/null | grep -qF 'hl-ansible-backup'; then
    echo "cron 已有 hl-ansible-backup 條目,跳過"
else
    (crontab -l 2>/dev/null; echo "$COMMENT"; echo "$LINE") | crontab -
    echo "已加入 cron:"
fi
crontab -l | tail -2
echo
echo "驗證:bash ~/.local/bin/hl-ansible-backup && tail -3 ~/.local/state/hl/ansible-backup.log"
