#!/usr/bin/env bash
# watchdog-ct201: 站外看門狗（監控的監控，待辦清單 #4）
# CT201（觀測面）或其上告警要件死亡時，由 CT260 直發 Telegram，完全不經 Prometheus/Alertmanager。
# 路徑：CT260 不能直連 VLAN80（見《監控告警.txt》§1），檢查一律走 ssh pve24 -> pct，
#       與 homelab-notify.py 同一慣例；若 pve24 亦不通則四項全失敗（CT260 與 CT201 同宿主，
#       pve24 全滅時本腳本也活不了，該情境由 UPS/復電自啟涵蓋）。
# 檢查四點：pct status 201 running / Prometheus :9090/-/healthy / Uptime Kuma :3001（回 302 即活）
#           / Gotify :8090/health。埠號以拓樸 V6 §5 為準。
# 防抖：連續 >=2 輪（cron */2 分 => 約 4 分鐘）失敗才發 TG；恢復時補發一則。
# 狀態檔 /var/tmp/wd-ct201.state 兼作心跳，供 life-ops daily_brief 讀「看門狗存活」行。
# 測試鉤子：WD_SSH_HOST=<不存在主機> 可模擬全鏈失敗。
set -u

SSH_HOST="${WD_SSH_HOST:-pve24-auto}"
STATE="/var/tmp/wd-ct201.state"
LOG="$HOME/.local/state/homelab-notify/watchdog-ct201.log"
ENVF="$HOME/.config/homelab/notify-telegram.env"
FAIL_THRESHOLD=2

mkdir -p "$(dirname "$LOG")"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG"; }

tg_send() {
    local token chat
    token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENVF" | head -1 | sed "s/[\"']//g")
    chat=$(sed -n 's/^TELEGRAM_CHAT_ID=//p' "$ENVF" | head -1 | sed "s/[\"']//g")
    if [ -z "$token" ] || [ -z "$chat" ]; then log "TG config missing in $ENVF"; return 1; fi
    curl -sf -m 20 "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=$1" >/dev/null || { log "TG send failed"; return 1; }
}

# ntfy 互動推播（待辦19）：告警附〔重啟監控棧〕〔重啟CT201〕按鈕（POST CT260 webhook :5001）。
# ★ 架構註記：ntfy server 在 CT201——CT201 全滅時 ntfy 發不出去（僅 TG 可達，無按鈕）；
#   按鈕只在「CT201 活著但個別服務（gotify/kuma/prom）死」時有效。失敗只記 log 不擋 TG。
NTFY_ENVF="$HOME/.config/homelab/ntfy.env"
WH_ENVF="$HOME/.config/homelab/ntfy-webhook.env"

ntfy_send() {  # $1=title $2=message $3=with_buttons(1|0)
    local url topic ptoken wtoken whurl actions
    url=$(sed -n 's/^NTFY_URL=//p' "$NTFY_ENVF" 2>/dev/null | head -1)
    topic=$(sed -n 's/^NTFY_TOPIC=//p' "$NTFY_ENVF" 2>/dev/null | head -1)
    ptoken=$(sed -n 's/^NTFY_PUB_TOKEN=//p' "$NTFY_ENVF" 2>/dev/null | head -1)
    wtoken=$(sed -n 's/^WEBHOOK_TOKEN=//p' "$WH_ENVF" 2>/dev/null | head -1)
    whurl=$(sed -n 's/^WEBHOOK_URL=//p' "$NTFY_ENVF" 2>/dev/null | head -1)
    [ -z "$url" ] || [ -z "$ptoken" ] && { log "ntfy config missing, skip"; return 0; }
    actions="[]"
    if [ "$3" = 1 ] && [ -n "$wtoken" ]; then
        actions=$(printf '[{"action":"http","label":"重啟監控棧","url":"%s","method":"POST","headers":{"Authorization":"Bearer %s","Content-Type":"application/json"},"body":"{\\"action\\":\\"restart-monitoring-stack\\"}","clear":false},{"action":"http","label":"重啟CT201","url":"%s","method":"POST","headers":{"Authorization":"Bearer %s","Content-Type":"application/json"},"body":"{\\"action\\":\\"pct-reboot-201\\"}","clear":false}]' \
            "$whurl" "$wtoken" "$whurl" "$wtoken")
    fi
    python3 - "$url" "$topic" "$1" "$2" "$actions" <<'PYEOF' >/dev/null 2>&1 || log "ntfy send failed（CT201 可能整台不可達，屬預期降級）"
import json, sys, urllib.request, os
url, topic, title, msg, actions = sys.argv[1:6]
tok = ""
for line in open(os.path.expanduser("~/.config/homelab/ntfy.env")):
    if line.startswith("NTFY_PUB_TOKEN="):
        tok = line.split("=",1)[1].strip()
payload = {"topic": topic or "homelab", "title": title, "message": msg, "priority": 5}
acts = json.loads(actions)
if acts:
    payload["actions"] = acts
req = urllib.request.Request(url, data=json.dumps(payload, ensure_ascii=False).encode(),
    headers={"Authorization": "Bearer "+tok, "Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=8).read()
PYEOF
}

# 一次 ssh 完成四點檢查，輸出 key=OK|FAIL 各一行；ssh 不通時輸出為空。
run_checks() {
    timeout 70 ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" '
        sudo pct status 201 2>/dev/null | grep -q "status: running" && echo ct=OK || echo ct=FAIL
        for c in "prom 9090 /-/healthy" "kuma 3001 /" "gotify 8090 /health"; do
            set -- $c
            sudo pct exec 201 -- curl -sf -m 8 -o /dev/null "http://localhost:$2$3" \
                && echo "$1=OK" || echo "$1=FAIL"
        done
    ' 2>/dev/null
}

# --- 讀上一輪狀態（不 source，/var/tmp 不信任內容） ---
FAIL_COUNT=0; ALERTED=0; PREV_DETAIL=-
if [ -f "$STATE" ]; then
    FAIL_COUNT=$(sed -n 's/^FAIL_COUNT=//p' "$STATE" | head -1)
    ALERTED=$(sed -n 's/^ALERTED=//p' "$STATE" | head -1)
    PREV_DETAIL=$(sed -n 's/^FAIL_DETAIL=//p' "$STATE" | head -1)
fi
case "$FAIL_COUNT" in ''|*[!0-9]*) FAIL_COUNT=0;; esac
case "$ALERTED" in 1) ;; *) ALERTED=0;; esac

write_state() {  # $1=STATUS $2=FAIL_COUNT $3=ALERTED $4=FAIL_DETAIL
    cat > "$STATE" <<EOF
LAST_RUN=$(date +%s)
LAST_STATUS=$1
FAIL_COUNT=$2
ALERTED=$3
FAIL_DETAIL=$4
EOF
}

# --- 本輪檢查 ---
out=$(run_checks)
fails=""
for k in ct prom kuma gotify; do
    echo "$out" | grep -q "^${k}=OK$" || fails="${fails:+$fails,}$k"
done
[ -z "$out" ] && fails="ssh-pve24不通(四項全不可達)"

if [ -z "$fails" ]; then
    if [ "$ALERTED" = 1 ]; then
        tg_send "✅ CT201 站外看門狗：恢復正常（ct/prometheus/kuma/gotify 四項檢查全通，經 pve24）。" \
            && log "RECOVERED (was: $PREV_DETAIL)" \
            || log "RECOVERED but TG notify failed (was: $PREV_DETAIL)"
        # 分流（2026-07-07）：恢復通知=閱讀型只走 TG；🚨（帶處置按鈕）才雙推 ntfy
    fi
    write_state OK 0 0 -
else
    new_count=$((FAIL_COUNT + 1))
    log "FAIL #$new_count: $fails"
    alerted=$ALERTED
    if [ "$new_count" -ge "$FAIL_THRESHOLD" ] && [ "$ALERTED" != 1 ]; then
        # 分流（2026-07-07）：ntfy 獨立於 TG 成敗先發（互備——外網斷時 LAN 內 ntfy 仍達）；
        # 只在跨門檻那一輪發一次，TG 失敗重試不重發 ntfy
        [ "$new_count" -eq "$FAIL_THRESHOLD" ] && \
            ntfy_send "🚨 CT201 看門狗：${fails}" "連續 ${new_count} 次失敗（按鈕僅在 CT201 尚活時可達）" 1
        if tg_send "🚨 CT201 站外看門狗（獨立於 Alertmanager）：連續 ${new_count} 次檢查失敗 → ${fails}
路徑 CT260→ssh pve24→pct；若顯示 ssh-pve24不通 代表連宿主都碰不到。
此刻 Prometheus 告警可能無法外送，請人工查看 CT201。
📱 已同步 ntfy（處置按鈕在 ntfy；CT201 全滅時 ntfy 不可達）"; then
            alerted=1
            log "ALERT sent: $fails"
        fi
    fi
    write_state FAIL "$new_count" "$alerted" "$fails"
fi
