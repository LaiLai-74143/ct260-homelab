#!/usr/bin/env bash
# opencode-up-notify.sh — opencode-serve 的 ExecStartPost 鉤子:服務起來後發 TG。
# 由 systemd 以 codex 身分執行;必須永遠 exit 0(非零會把整次 start 判成失敗)。
ENVF="$HOME/.config/homelab/notify-telegram.env"
LOG="$HOME/.local/state/homelab-notify/opencode-up.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG" 2>/dev/null; }

tg_send() {
    local token chat
    token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENVF" | head -1 | sed "s/[\"']//g")
    chat=$(sed -n 's/^TELEGRAM_CHAT_ID=//p' "$ENVF" | head -1 | sed "s/[\"']//g")
    [ -n "$token" ] && [ -n "$chat" ] || { log "TG config missing in $ENVF"; return 1; }
    curl -sf -m 20 "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=$1" >/dev/null || { log "TG send failed"; return 1; }
}

# 等服務真的能應答(有 Basic 守門,401 = 活著),最多 30s
code=000
for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m2 http://127.0.0.1:4096/ 2>/dev/null) || true
    [ "$code" = "401" ] && break
    sleep 1
done

# NRestarts:自動拉起 ≥1;開機或手動 start/restart 會歸零
n=$(systemctl show opencode-serve -p NRestarts --value 2>/dev/null) || n='?'
if [ -n "$n" ] && [ "$n" != "?" ] && [ "$n" != "0" ]; then
    kind="自動拉起(第 ${n} 次,前次行程被殺或崩潰)"
else
    kind="啟動(開機或手動)"
fi
ts=$(TZ=Asia/Taipei date '+%F %T')
if [ "$code" = "401" ]; then
    msg="🟢 opencode-serve ${kind} @ CT260,:4096 應答正常(${ts} 台北)"
else
    msg="🟡 opencode-serve ${kind} @ CT260,但 30s 內 :4096 未應答(code=${code},${ts} 台北)"
fi
log "$msg"
tg_send "$msg" || true
exit 0
