#!/bin/sh
# hl-memguard 啟動 wrapper — cron @reboot 與 */5 自癒共用(同 ntfy-webhook 慣例)。
# flock 保單實例;服務自寫 ~/.local/state/homelab-notify/memguard.log,故丟棄 std 流。
exec /usr/bin/flock -n /home/codex/.local/state/homelab-notify/.memguard.lock \
    /home/codex/.local/bin/hl-memguard >/dev/null 2>&1
