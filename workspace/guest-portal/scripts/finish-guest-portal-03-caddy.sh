#!/bin/bash
# finish-guest-portal-03-caddy.sh — CT203 Caddy :80 加 schedule.* host 分流(接 CT205)。
#
# 在哪跑:CT260 一般使用者身份:
#   bash ~/workspace/guest-portal/scripts/finish-guest-portal-03-caddy.sh
#
# 前置:段B(CT205 存在且 app :8300 已起)+段C(guest.json 已推、至少能回 /api/health)。
#   ——否則 schedule 路由回歸會 502(路由本身仍正確,只是後端還沒起)。
#
# ★ 零風險改法:只「加」schedule.lailai74143.com 具名路由;Vaultwarden 仍是 catch-all,
#   其行為一字不動(不需知道 VW 確切 hostname)。
# 冪等:重推同一份 Caddyfile 無害。
# 回滾:CT203 /root/_backups/Caddyfile.before-guest-<TS> 蓋回 + systemctl restart caddy。
set -euo pipefail

SRC=~/workspace/ct-dmz-proxy/Caddyfile
TS=$(date +%Y%m%d_%H%M%S)

[ -f "$SRC" ] || { echo "✗ 找不到 Caddyfile SoT:$SRC"; exit 1; }
grep -q "schedule.lailai74143.com" "$SRC" || { echo "✗ SoT 未含 schedule 路由,先確認已編輯"; exit 1; }
ssh pve24 "sudo pct exec 203 -- true" || { echo "✗ CT203 不可達"; exit 1; }

echo "== 1. 備份 CT203 現行 Caddyfile =="
ssh pve24 "sudo pct exec 203 -- mkdir -p /root/_backups && \
           sudo pct exec 203 -- cp /etc/caddy/Caddyfile /root/_backups/Caddyfile.before-guest-$TS"
echo "   備份 → /root/_backups/Caddyfile.before-guest-$TS"

echo "== 2. 推新 Caddyfile → CT203 =="
scp -q "$SRC" pve24:/tmp/Caddyfile.guest
ssh pve24 "sudo pct push 203 /tmp/Caddyfile.guest /etc/caddy/Caddyfile; rc=\$?; rm -f /tmp/Caddyfile.guest; exit \$rc"

echo "== 3. caddy validate(失敗即回滾)=="
if ! ssh pve24 "sudo pct exec 203 -- caddy validate --config /etc/caddy/Caddyfile" >/dev/null 2>&1; then
    echo "✗ validate 失敗 → 回滾"
    ssh pve24 "sudo pct exec 203 -- cp /root/_backups/Caddyfile.before-guest-$TS /etc/caddy/Caddyfile"
    exit 1
fi
echo "   ✓ validate 通過"

echo "== 4. restart + 存活檢查(失敗即回滾)=="
ssh pve24 "sudo pct exec 203 -- systemctl restart caddy"
sleep 2
if ! ssh pve24 "sudo pct exec 203 -- systemctl is-active --quiet caddy"; then
    echo "✗ caddy 未起 → 回滾"
    ssh pve24 "sudo pct exec 203 -- cp /root/_backups/Caddyfile.before-guest-$TS /etc/caddy/Caddyfile && \
               sudo pct exec 203 -- systemctl restart caddy"
    exit 1
fi
echo "   ✓ caddy active"

echo "== 5. 回歸(CT203 本機視角,對齊防火牆拓樸)=="
# 5a. 健康端點仍在
H=$(ssh pve24 "sudo pct exec 203 -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/health")
echo "   /health → $H $([ "$H" = 200 ] && echo ✓ || echo '✗（異常）')"
# 5b. Vaultwarden catch-all 未受影響:任意非 schedule host → 應到 DXP(200/302,非 404)
VW=$(ssh pve24 "sudo pct exec 203 -- curl -s -o /dev/null -w '%{http_code}' -H 'Host: pw.probe.invalid' http://127.0.0.1/")
echo "   非 schedule host(catch-all→Vaultwarden)→ $VW $([ "$VW" != 404 ] && echo '✓（仍達後端）' || echo '✗（catch-all 壞了!）')"
# 5c. schedule host → CT205 app(app 已起=200;未起=502/000,路由仍正確)
SCH=$(ssh pve24 "sudo pct exec 203 -- curl -s -o /dev/null -w '%{http_code}' -H 'Host: schedule.lailai74143.com' http://127.0.0.1/api/health")
echo "   schedule host → CT205 /api/health → $SCH $([ "$SCH" = 200 ] && echo ✓ || echo '（非200=CT205 app 未起,先完成段B/C）')"

echo
echo "✅ Caddy 分流已上線。"
echo "   ★ 最後一步(你在 Cloudflare 操作,CF 帳號不經 Agent):"
echo "     Zero Trust → Networks → Tunnels → 你的 tunnel → Public Hostname → Add:"
echo "       Subdomain=schedule  Domain=lailai74143.com"
echo "       Service=HTTP  URL=localhost:80"
echo "     (與 Vaultwarden 同一 tunnel、同指 localhost:80;Caddy 依 Host 分流)"
echo "   加完後外網 https://schedule.lailai74143.com 即可達 → 登入頁。"
