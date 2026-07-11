#!/bin/bash
# hl-claude-rc-watch(2026-07-11):claude remote-control server 哨兵。
# 常駐路徑 ~/.local/bin/(SoT=~/workspace/ops/),cron */5 + flock。
# 死了=手機/PC 連不上 codex-ops workspace。連續 >=2 輪(約 10 分)失敗才發 TG
# (去抖比照 watchdog-ct201),恢復補發一則。★只告警不自動重啟——手動
# tmux kill-session 屬合法操作,搶救交給人:跑 ~/.local/bin/hl-claude-tmux-run.sh。
# pgrep 模式釘 'claude remote-control'(server mode 子指令);不會誤中
# --remote-control 旗標形或本腳本自身。測試鉤子:RCW_PATTERN/RCW_STATE/RCW_DRY。
set -uo pipefail

PATTERN="${RCW_PATTERN:-(^|/)claude remote-control}"  # 錨定 argv0,避免誤中 cmdline 碰巧含該字串的無關程序
STATE="${RCW_STATE:-$HOME/.local/state/homelab-notify/claude-rc.state}"
FAIL_THRESHOLD=2

tg() {  # token 經 curl -K stdin,不進 argv
    if [ "${RCW_DRY:-0}" = "1" ]; then echo "[dry-run TG] $1"; return 0; fi
    local envf="$HOME/.config/homelab/notify-telegram.env" token chat
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$envf" 2>/dev/null | cut -d= -f2-)
    chat=$(grep '^TELEGRAM_CHAT_ID=' "$envf" 2>/dev/null | cut -d= -f2-)
    [ -n "$token" ] && [ -n "$chat" ] || return 1
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" | \
        curl -sf -m 20 -K - --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" >/dev/null
}

fails=0; alerted=0
[ -f "$STATE" ] && . "$STATE" 2>/dev/null || true

if pgrep -f "$PATTERN" >/dev/null 2>&1; then
    if [ "$alerted" = "1" ]; then
        tg "✅ claude-rc 恢復:claude remote-control 又在跑了(codex-ops workspace 可遠端連線)。"
    fi
    printf 'fails=0\nalerted=0\n' > "$STATE"
    echo "OK"
else
    fails=$((fails + 1))
    if [ "$fails" -ge "$FAIL_THRESHOLD" ] && [ "$alerted" = "0" ]; then
        tmux_note="tmux session 'claude' 也不在"
        tmux has-session -t claude 2>/dev/null && tmux_note="tmux session 'claude' 還在(claude 程序死在殼裡,attach 可看殘骸)"
        tg "🚨 claude-rc 哨兵:claude remote-control 已連續 ${fails} 輪(約 $((fails*5)) 分)不在跑,手機/PC 連不上 codex-ops workspace。${tmux_note}。
處置(CT260,codex):tmux attach -t claude 看現場;重拉:~/.local/bin/hl-claude-tmux-run.sh
(若是你手動 kill 的,忽略本則;哨兵不自動重啟。)"
        alerted=1
    fi
    printf 'fails=%s\nalerted=%s\n' "$fails" "$alerted" > "$STATE"
    echo "FAIL fails=$fails alerted=$alerted"
fi
