#!/bin/sh
# ntfy-webhook 啟動 wrapper（待辦19d）— cron @reboot 與 */5 自癒共用。
# flock 保單實例；服務自寫 ~/.local/state/homelab-notify/webhook.log，故丟棄 std 流。
exec /usr/bin/flock -n /home/codex/.local/state/homelab-notify/.webhook.lock \
    /usr/bin/python3 /home/codex/.local/bin/ntfy-webhook.py >/dev/null 2>&1
