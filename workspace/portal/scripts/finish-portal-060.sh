#!/bin/bash
# finish-portal-060.sh — 部署 portal:0.6.0(生活頁「生活助理」對話框:
#                        BFF /api/life/chat|confirm → CT260 life-chat :5002 Sonnet 5;
#                        模型唯讀工具,寫入=提案單+確認卡+HMAC 驗簽)
# 前置:finish-life-chat-infra.sh 已跑(OpenWrt 5002 放行+portal.env 兩鍵)。
# 冪等:重跑無害。回滾:compose 蓋回 _backups/docker-compose.yml.before-portal060-<最早TS>
#       + docker compose up -d --force-recreate portal(0.5.2 image 仍在本機)。
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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.6.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-060-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-060-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.6.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.6.0(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.6.0" not in s:
    assert "    image: portal:0.5.2" in s, "錨點未命中:image tag(現役非 0.5.2?)"
    s = s.replace("    image: portal:0.5.2", "    image: portal:0.6.0", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal060-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal060-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
docker exec portal env | grep -c \"^LIFE_CHAT_\" | xargs echo \"容器內 LIFE_CHAT_ 鍵數(應為2):\"
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:11 GET 端點 + 生活助理端點三態 + M3 回歸 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
curl -s -m 8 http://127.0.0.1:8088/api/life/chat | python3 -c \"
import json,sys
d=json.load(sys.stdin)
assert d[\\\"enabled\\\"] is True, \\\"enabled 應為 true(portal.env 鍵未進容器?)\\\"
assert d[\\\"allowed\\\"] is False
print(\\\"GET /api/life/chat:enabled=true, 無 Remote-User allowed=false ✓\\\")\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"hi\\\"}]}\" http://127.0.0.1:8088/api/life/chat)
[ \"\$code\" = 403 ] || { echo \"無 Remote-User 應 403,實得 \$code\"; exit 1; }
echo \"POST 無 Remote-User → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"silence-1h\\\",\\\"param\\\":\\\"X\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"M3 回歸失敗:實得 \$code\"; exit 1; }
echo \"M3 回歸:無 Remote-User → 403 ✓\"
'"

echo "== 6. live 對話一輪(記帳線;經 BFF 帶 Remote-User,真打 Sonnet 5) =="
ssh pve24 "sudo pct exec 201 -- curl -s -m 140 -X POST -H 'Content-Type: application/json' \
  -H 'Remote-User: e2e' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"現在有沒有人欠我錢?一句話回答\"}]}' \
  http://127.0.0.1:8088/api/life/chat" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
print('reply:', d['reply'][:120])
print('meta:', d.get('meta'))"

echo "== 完成(TS=$TS)。驗收:手機 portal.hl 生活頁底部「生活助理」對話框 =="
echo "回滾:compose 蓋回 _backups/docker-compose.yml.before-portal060-<最早TS> + up -d --force-recreate portal"
