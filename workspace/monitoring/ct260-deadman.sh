#!/bin/bash
# ct260-deadman.sh — CT260 dead-man switch(新想法A2,2026-07-10)。部署位置:CT201 /usr/local/bin/。
# 監控大腦 CT260 自己沒人監:它一倒,TG notifier/watchdog/憑證續簽/晨報全靜默。
# 本哨兵跑在 CT201(cron 每分鐘),雙端點檢測(webhook :5001/health + node_exporter :9100),
# 連續 5 輪全掛 → 直發本機 ntfy(刻意不經 CT260 的 TG 鏈=獨立告警路徑);恢復發解除。
# 憑證:/usr/local/etc/ct260-deadman.env(600,NTFY_TOKEN=ntfy pub token)。
set -u
ENV=/usr/local/etc/ct260-deadman.env
STATE=/var/tmp/ct260-deadman.state
[ -f "$ENV" ] && . "$ENV"
NTFY_URL="${NTFY_URL:-http://127.0.0.1:8091}"
NTFY_TOPIC="${NTFY_TOPIC:-homelab}"
THRESH=5

ok=0
curl -sfm5 -o /dev/null http://192.168.20.60:5001/health 2>/dev/null && ok=1
[ "$ok" -eq 0 ] && curl -sfm5 -o /dev/null http://192.168.20.60:9100/metrics 2>/dev/null && ok=1

fails=0; alerted=0
[ -f "$STATE" ] && read -r fails alerted < "$STATE"

ntfy() { # $1=priority $2=title $3=body
    curl -sfm10 -o /dev/null \
      -H "Authorization: Bearer ${NTFY_TOKEN:-}" \
      -H "Priority: $1" -H "Title: $2" -H "Tags: $4" \
      -d "$3" "$NTFY_URL/$NTFY_TOPIC" 2>/dev/null
}

if [ "$ok" -eq 1 ]; then
    if [ "$alerted" = "1" ]; then
        ntfy default "CT260 恢復" "ops 大腦回線,TG 通知鏈應已恢復。" "white_check_mark"
    fi
    echo "0 0" > "$STATE"
else
    fails=$((fails+1))
    if [ "$fails" -ge "$THRESH" ] && [ "$alerted" != "1" ]; then
        ntfy urgent "CT260 失聯(dead-man)" \
"webhook:5001 與 node_exporter:9100 連續 ${THRESH} 分鐘無回應。
影響:TG 告警/watchdog/晨報/憑證續簽全靜默——現在起看不到的不代表沒事。
處置:pve24 上 pct status 260 / pct start 260;不行看 pct console 260。" "skull"
        alerted=1
    fi
    echo "$fails $alerted" > "$STATE"
fi

# 順手出 Prometheus 指標(CT201 有 textfile dir 才寫)
TD=/var/lib/prometheus/node-exporter
[ -d "$TD" ] && printf '# HELP ct260_deadman_ok CT201 視角 CT260 存活(1=活)\n# TYPE ct260_deadman_ok gauge\nct260_deadman_ok %s\n' "$ok" > "$TD/ct260_deadman.prom.$$" && mv "$TD/ct260_deadman.prom.$$" "$TD/ct260_deadman.prom"
exit 0
