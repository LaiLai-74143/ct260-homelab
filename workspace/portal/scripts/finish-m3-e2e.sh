#!/bin/bash
# finish-m3-e2e.sh — 待辦49 M3 live 端到端一次性自測(部署 0.3.0 後執行)。
# 無害自測法(監控告警 §5g):silence-1h/NotifySelfTest——建一筆可見 silence,完事自動 expire。
# 驗四點:①POST /api/action 200 ②/api/alerts silences 出現該筆 ③webhook.log RUN via=portal ④TG 回發(手機實收)
set -euo pipefail

echo "== 1. CT201 內模擬 portal.hl 請求(帶 Remote-User)按〔靜音1h/NotifySelfTest〕 =="
ssh pve24 'sudo pct exec 201 -- curl -s -m 130 -X POST -H "Remote-User: m3-e2e" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"silence-1h\",\"param\":\"NotifySelfTest\"}" http://127.0.0.1:8088/api/action'
echo

echo "== 2. /api/alerts silences 應出現 NotifySelfTest(等快取 TTL 過期) =="
sleep 6
ssh pve24 'sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/alerts' \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
hits = [s for s in d.get('silences', []) if 'NotifySelfTest' in s.get('matchers', '')]
assert hits, 'silences 未見 NotifySelfTest!'
print('silence 已見:', hits[0]['matchers'], '至', hits[0]['ends_at'])"

echo "== 3. CT260 webhook.log 應有 RUN via=portal =="
grep 'via=portal silence-1h(NotifySelfTest)' ~/.local/state/homelab-notify/webhook.log | tail -1 \
  || { echo "webhook.log 未見 via=portal 記錄!"; exit 1; }

echo "== 4. 清理:expire 該筆測試 silence =="
ssh pve24 'sudo pct exec 201 -- docker exec alertmanager sh -c "
ID=\$(amtool silence query alertname=NotifySelfTest -q --alertmanager.url=http://localhost:9093)
[ -n \"\$ID\" ] && amtool silence expire \$ID --alertmanager.url=http://localhost:9093 && echo \"已 expire: \$ID\" || echo 無殘留
"'

echo "== 完成。第④點(TG 收到「🔘 portal:已執行 silence-1h(NotifySelfTest)」)請在手機/TG 確認 =="
