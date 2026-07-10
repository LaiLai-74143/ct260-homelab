#!/bin/sh
# hl-tg-bridge 啟動 wrapper(C1 生活助理 TG 雙向橋)— cron @reboot 與 */5 自癒共用。
# flock 保單實例(getUpdates 只能有一個消費者,雙實例會互搶 409);
# 服務自寫 ~/.local/state/tg-bridge/bridge.log,故丟棄 std 流。
PATH=/usr/local/bin:/usr/bin:/bin
export PATH
exec /usr/bin/flock -n /home/codex/.local/state/tg-bridge/.lock \
    /usr/bin/python3 /home/codex/.local/bin/hl-tg-bridge >/dev/null 2>&1
