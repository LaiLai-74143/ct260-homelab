#!/bin/sh
# life-chat 啟動 wrapper(待辦49 生活對話框)— cron @reboot 與 */5 自癒共用。
# flock 保單實例;服務自寫 ~/.local/state/life-chat/life-chat.log,故丟棄 std 流。
# PATH 帶 npm-global:claude CLI 需要 node(cron 環境不含)。
PATH=/home/codex/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
export PATH
exec /usr/bin/flock -n /home/codex/.local/state/life-chat/.lock \
    /usr/bin/python3 /home/codex/.local/bin/life-chat.py >/dev/null 2>&1
