#!/bin/bash
# finish-portal-070.sh — 部署 portal:0.7.0(安全面板+設備總覽嵌入 Grafana d-solo 圖表)
# 前置:先跑 finish-grafana-embed.sh(Grafana 開 allow_embedding+匿名 Viewer),
#       否則 iframe 只會是登入頁/空白。
# 冪等:重跑無害。
# 回滾(兩層都要,只換 image 不會撤掉 bind mount 的新前端——審查 2026-07-09 確認項):
#   ① tar -C /opt/portal -xzf /root/_backups/portal-src-before-070-<TS>.tgz(還原 static+bff)
#   ② compose 蓋回 _backups/docker-compose.yml.before-portal070-<最早TS>
#   ③ cd /opt/monitoring && docker compose up -d --force-recreate portal(0.6.3 image 仍在本機)
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== -1. 前置檢查:Grafana 匿名 d-solo 已可用(finish-grafana-embed.sh 的產物) =="
code=$(ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w %{http_code} -m 8 \
  'http://127.0.0.1:3002/d-solo/openwrt-portscan-autoban/openwrt-portscan-autoban?orgId=1&panelId=10'")
[ "$code" = 200 ] || { echo "Grafana d-solo 回 $code——先跑 finish-grafana-embed.sh 再部署"; exit 1; }
echo "d-solo 200 ✓"

echo "== 0. 前端 build(CT260 本機;CT201 不裝 node) =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rql "d-solo" "$ROOT/frontend/dist/assets"/*.js || { echo "bundle 無 d-solo,嵌入元件沒進包?"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.7.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-070-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-070-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.7.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.7.0(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.7.0" not in s:
    assert "    image: portal:0.6.3" in s, "錨點未命中:image tag(現役非 0.6.3?)"
    s = s.replace("    image: portal:0.6.3", "    image: portal:0.7.0", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal070-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal070-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:11 GET 端點 + 靜態包含嵌入元件 + Grafana 嵌入前置在位 + 回歸 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
grep -rql \"d-solo\" /opt/portal/static/assets/*.js || { echo \"部署後 static 無 d-solo\"; exit 1; }
echo \"static 含 d-solo ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 \"http://127.0.0.1:3002/d-solo/openwrt-portscan-autoban/openwrt-portscan-autoban?orgId=1&panelId=10\")
[ \"\$code\" = 200 ] || { echo \"Grafana d-solo 回 \$code——先跑 finish-grafana-embed.sh\"; exit 1; }
echo \"Grafana d-solo 200 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"hi\\\"}]}\" http://127.0.0.1:8088/api/life/chat)
[ \"\$code\" = 403 ] || { echo \"chat 回歸失敗:\$code\"; exit 1; }
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"silence-1h\\\",\\\"param\\\":\\\"X\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"M3 回歸失敗:\$code\"; exit 1; }
echo \"chat/M3 無 Remote-User → 403 ✓\"
'"

echo "== 完成(TS=$TS)。驗收:安全面板見攻擊地圖+雙趨勢、設備總覽見四 bargauge+雙趨勢 =="
echo "   (手機走 portal.hl,需 Authelia 已登入;PC40 走 :8088 直嵌 :3002)"
echo "回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-070-<TS>.tgz 還原 static+bff"
echo "          + compose 蓋回 _backups/docker-compose.yml.before-portal070-<最早TS> + up -d --force-recreate portal"
