#!/bin/sh
# archive-svc 啟動 wrapper(待辦49 拾遺板塊)— cron @reboot 與 */5 自癒共用。
# flock 保單實例;服務自寫 ~/.local/state/archive-svc/archive-svc.log,故丟棄 std 流。
PATH=/usr/local/bin:/usr/bin:/bin
export PATH
exec /usr/bin/flock -n /home/codex/.local/state/archive-svc/.lock \
    /usr/bin/python3 /home/codex/.local/bin/archive-svc.py >/dev/null 2>&1
