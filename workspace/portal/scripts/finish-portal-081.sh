#!/bin/bash
# finish-portal-081.sh — 部署 portal:0.8.1(修 0.7/0.8 的 Grafana 嵌入)
#   Grafana 圖表改走 BFF 同源反代 /grafana/*→:3002(修 portal.hl 跨網域+Authelia
#   cookie 被擋的失敗);遊戲頁終端連結去重。設備趨勢/MCSM 控制沿用 0.8.0。
# 冪等:重跑無害。前置=Grafana 匿名 Viewer 已開(0.7.0 的 finish-grafana-embed.sh)。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-081-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal081-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build(CT260 本機;CT201 不裝 node) =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
# 錨點必須是「執行期字串」——protected_instance 只在註解,minify 後為 0(審查確認項)
grep -rql "api/game/action" "$ROOT/frontend/dist/assets"/*.js >/dev/null \
  || { echo "bundle 無 api/game/action,控制沒進包?"; exit 1; }
grep -rql "d-solo" "$ROOT/frontend/dist/assets"/*.js >/dev/null \
  || { echo "bundle 無 d-solo,嵌入沒進包?"; exit 1; }

echo "== 1. 打包 static + bff =="
tar -C "$ROOT/frontend/dist" -czf "$TMP/portal-static.tgz" .
tar -C "$ROOT/bff" --exclude .venv --exclude '__pycache__' \
    -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
STATIC_SHA=$(sha256sum "$TMP/portal-static.tgz" | cut -d' ' -f1)
BFF_SHA=$(sha256sum "$TMP/portal-bff.tgz" | cut -d' ' -f1)

echo "== 2. 傳輸 pve24 → pct push CT201 =="
scp -q "$TMP/portal-static.tgz" "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo pct push 201 /tmp/portal-static.tgz /tmp/portal-static.tgz && \
           sudo pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && \
           rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz'

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.8.1 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-081-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-081-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.8.1 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.8.1(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.8.1" not in s:
    assert "    image: portal:0.8.0" in s, "錨點未命中:image tag(現役非 0.8.0?)"
    s = s.replace("    image: portal:0.8.0", "    image: portal:0.8.1", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal081-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal081-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:11 端點 + game control + 白名單 403 + Grafana 反代 + 回歸 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
curl -s -m 8 http://127.0.0.1:8088/api/game | python3 -c \"
import json,sys
d=json.load(sys.stdin); c=d.get(\\\"control\\\") or {}
assert isinstance(c.get(\\\"actions\\\"), dict) and set(c[\\\"actions\\\"])=={\\\"open\\\",\\\"stop\\\",\\\"restart\\\"}, \\\"control 白名單三動作缺\\\"
print(\\\"control 塊 ✓ enabled=\\\", c[\\\"enabled\\\"], \\\"| 終端 id:\\\", d.get(\\\"instance_uuid\\\") and \\\"有\\\" or \\\"無(讀取 key advanced 未回 uuid/daemon→終端機不顯示,查 MCSM 版本)\\\")\"
# E2E 全走「必被擋」路徑,零 MCSM 副作用(open 真測會把停機中的伺服器拉起來,審查確認項):
# ①無 X-Requested-With → 403(CSRF gate);②帶齊 header 但 action=kill → 403(白名單)
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"open\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"CSRF gate 回歸失敗(無 XRW 應 403):\$code\"; exit 1; }
echo \"game/action 無 X-Requested-With → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -H \"X-Requested-With: XMLHttpRequest\" -H \"Remote-User: e2e\" \
  -d \"{\\\"action\\\":\\\"kill\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"白名單回歸失敗(kill 應 403):\$code\"; exit 1; }
echo \"game/action kill(帶齊 header)→ 403 ✓\"
grep -rql \"api/game/action\" /opt/portal/static/assets/*.js || { echo static 無 api/game/action; exit 1; }
# Grafana 同源反代:d-solo HTML 經 /grafana 出來、base/appSubUrl 已改寫、資產可代出
curl -s -m 10 \"http://127.0.0.1:8088/grafana/d-solo/homelab-overview/homelab-overview?orgId=1&panelId=13&theme=dark\" | python3 -c \"
import sys
h=sys.stdin.read()
assert '<base href=\\\"/grafana/\\\"' in h, 'base href 未改寫成 /grafana/'
assert '\\\"appSubUrl\\\":\\\"/grafana\\\"' in h, 'appSubUrl 未改寫'
assert 'public/build/' in h, 'd-solo 資產缺(非 Grafana 頁?)'
print('Grafana 反代 d-solo 改寫 ✓')\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 10 http://127.0.0.1:8088/grafana/public/build/app.b5c3fa1a9a2d09a31940.js)
{ [ \"\$code\" = 200 ] || [ \"\$code\" = 404 ]; } || { echo \"反代資產路徑異常:\$code(非 200/404)\"; exit 1; }
echo \"Grafana 反代資產路徑 → \$code(200=命中/404=hash 已滾動,路徑通即可)\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 http://127.0.0.1:8088/grafana/api/health)
[ \"\$code\" = 200 ] || { echo \"Grafana 反代 /api/health 非 200:\$code\"; exit 1; }
echo \"Grafana 反代 /api/health → 200 ✓\"
# 高危回歸(審查 2026-07-09):admin:admin 經反代打管理 API 必須被反代層 403 擋下
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -u admin:admin http://127.0.0.1:8088/grafana/api/admin/settings)
[ \"\$code\" = 403 ] || { echo \"高危回歸失敗:admin:admin 打管理 API 得 \$code(應 403)\"; exit 1; }
echo \"admin:admin /grafana/api/admin/settings → 403 ✓(authorization 不透傳+管理路徑擋)\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"silence-1h\\\",\\\"param\\\":\\\"X\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"M3 回歸失敗:\$code\"; exit 1; }
echo \"M3 無 Remote-User → 403 ✓\"
'"

echo "== 完成(TS=$TS)。驗收:設備總覽=趨勢折線;遊戲頁=控制鍵(未落 key 顯示未配置)+終端機 =="
echo "   控制鍵要能按 → 跑 finish-mcsm-control.sh 落 MCSM_CTRL_KEY"
echo "回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-081-<TS>.tgz"
echo "          + compose 蓋回 _backups/docker-compose.yml.before-portal081-<最早TS> + up -d --force-recreate portal"
