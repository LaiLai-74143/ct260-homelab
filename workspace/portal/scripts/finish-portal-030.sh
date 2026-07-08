#!/bin/bash
# finish-portal-030.sh — 待辦49 M3:部署 portal:0.3.0(告警動作按鈕:GET /api/actions +
#                        POST /api/action → CT260 webhook;前端 Toast/Confirm/AlertActions)
# 前置:finish-webhook-portal-token.sh 已跑(OpenWrt 放行 + 雙 token + portal.env 兩鍵)。
# 冪等:重跑無害。回滾:compose 蓋回 _backups/docker-compose.yml.before-portal030-<最早TS>
#       + docker compose up -d --force-recreate portal(0.2.2 image 仍在本機)。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build(CT260 本機;CT201 不裝 node) =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.3.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
# 自癒:上次死在兩個 mv 之間時把 .old 挪回(兩者皆缺則 fail-loud)
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
# 首跑才建 before-030 備份(重跑時源已是 0.3.0,再備份會污染回滾點)
ls /root/_backups/portal-src-before-030-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-030-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.3.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.3.0(先驗後裝)+ force-recreate(吃 portal.env 新鍵) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.3.0" not in s:
    assert "    image: portal:0.2.2" in s, "錨點未命中:image tag(現役非 0.2.2?)"
    s = s.replace("    image: portal:0.2.2", "    image: portal:0.3.0", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal030-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal030-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:env 進容器(只印長度)+ 11 GET 端點 + /api/action 驗證鏈 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
docker exec portal sh -c \"echo 容器內 KUMA_len=\\\${#KUMA_API_KEY} MCSM_len=\\\${#MCSM_API_KEY} WHURL_len=\\\${#WEBHOOK_URL} WHTOK_len=\\\${#WEBHOOK_TOKEN_PORTAL}\"
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
echo \"-- /api/action 驗證鏈(不觸發真動作) --\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"silence-1h\\\",\\\"param\\\":\\\"X\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"無 Remote-User 應 403,實得 \$code\"; exit 1; }
echo \"無 Remote-User → 403 OK\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Remote-User: selftest\" -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"not-in-whitelist\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"白名單外應 403,實得 \$code\"; exit 1; }
echo \"白名單外動作 → 403 OK\"
'"

echo "== 完成(TS=$TS)。live E2E(silence-1h/NotifySelfTest 無害自測)另行一次性執行,不入本冪等腳本 =="
echo "回滾:compose 蓋回 _backups/docker-compose.yml.before-portal030-<最早TS> + up -d --force-recreate portal"
