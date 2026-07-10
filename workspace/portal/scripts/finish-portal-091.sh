#!/bin/bash
# finish-portal-091.sh — 部署 portal:0.9.1(生活頁「今日行程」下新增「近期行程」段)
#   資料鏈:CT260 hl-write-life 加 calendar_upcoming(明日起 14 天,GCal 單次呼叫拆今日/近期)
#   → life.json → BFF _redact_life 對 upcoming 同步遮蔽 title → 前端 UpcomingCard(依日分組)。
# 前置:CT260 ~/.local/bin/hl-write-life 已更新(跑一次以投遞新欄位)。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-091-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal091-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build(CT260 本機;CT201 不裝 node) =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
# 核心斷言:GuestPanel 進包(帳號管理面板字串)
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串,UpcomingCard 沒進包?"; exit 1; }
grep -rql "api/game/action" "$ROOT/frontend/dist/assets"/*.js >/dev/null \
  || { echo "bundle 無 api/game/action(回歸基準遺失?)"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.9.1 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-091-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-091-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.9.1 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.9.1(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.9.1" not in s:
    assert "    image: portal:0.9.0" in s, "錨點未命中:image tag(現役非 0.9.0?)"
    s = s.replace("    image: portal:0.9.0", "    image: portal:0.9.1", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal091-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal091-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:端點 + guest 面板進包 + guest 閘門 + 既有回歸 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
# 現役 static 含帳號管理面板
grep -rq \"近期行程\" /opt/portal/static/assets/*.js || { echo \"現役 bundle 無近期行程,部署未生效?\"; exit 1; }
echo \"近期行程已進包 ✓\"
# guest 閘門:無 Remote-User → 403(GET list 與 POST op 皆然)
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 http://127.0.0.1:8088/api/life/guest)
[ \"\$code\" = 403 ] || { echo \"guest list 無 Remote-User 應 403,得 \$code\"; exit 1; }
echo \"/api/life/guest 無 Remote-User → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"op\\\":\\\"list\\\"}\" http://127.0.0.1:8088/api/life/guest)
[ \"\$code\" = 403 ] || { echo \"guest POST 無 Remote-User 應 403,得 \$code\"; exit 1; }
echo \"POST /api/life/guest 無 Remote-User → 403 ✓\"
# 白名單外 op(帶 Remote-User)→ 400
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -H \"Remote-User: e2e\" -d \"{\\\"op\\\":\\\"evil\\\"}\" http://127.0.0.1:8088/api/life/guest)
[ \"\$code\" = 400 ] || { echo \"guest 白名單外 op 應 400,得 \$code\"; exit 1; }
echo \"guest op=evil → 400 ✓\"
# 既有回歸:M3 / game CSRF / Grafana 反代
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"silence-1h\\\",\\\"param\\\":\\\"X\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"M3 回歸失敗:\$code\"; exit 1; }
echo \"M3 無 Remote-User → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"open\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"game CSRF gate 回歸失敗:\$code\"; exit 1; }
echo \"game/action 無 X-Requested-With → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 http://127.0.0.1:8088/grafana/api/health)
[ \"\$code\" = 200 ] || { echo \"Grafana 反代 /api/health 非 200:\$code\"; exit 1; }
echo \"Grafana 反代 /api/health → 200 ✓\"
curl -s -m 8 http://127.0.0.1:8088/api/health | grep -q \"ok\" && echo \"health ok ✓\"
'"

echo "== 完成(TS=$TS)。驗收:生活頁「今日行程」下方見「近期行程」(依日分組 14 天) =="
echo "回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-091-<TS>.tgz"
echo "          + compose 蓋回 _backups/docker-compose.yml.before-portal091-<最早TS> + up -d --force-recreate portal"
