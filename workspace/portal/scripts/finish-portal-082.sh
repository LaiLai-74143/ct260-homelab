#!/bin/bash
# finish-portal-082.sh — 部署 portal:0.8.2(遊戲頁拔掉 portal.hl 終端機提示行)
#   0.8.1 在 portal.hl 顯示「內嵌僅區網 :8088」提示,使用者裁決移除;HL 網域終端區塊
#   直接不渲染,MCSM 入口只剩頁尾面板連結。BFF 僅 version 字串變更,其餘沿用 0.8.1。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-082-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal082-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build(CT260 本機;CT201 不裝 node) =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rql "api/game/action" "$ROOT/frontend/dist/assets"/*.js >/dev/null \
  || { echo "bundle 無 api/game/action,控制沒進包?"; exit 1; }
# 0.8.2 核心斷言(反斷言):提示行字串必須「不在」bundle 裡
if grep -rq "網頁終端機內嵌僅於區網" "$ROOT/frontend/dist/assets"/*.js; then
  echo "bundle 仍含終端提示行字串,移除沒進包?"; exit 1
fi

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.8.2 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-082-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-082-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.8.2 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.8.2(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.8.2" not in s:
    assert "    image: portal:0.8.1" in s, "錨點未命中:image tag(現役非 0.8.1?)"
    s = s.replace("    image: portal:0.8.1", "    image: portal:0.8.2", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal082-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal082-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:11 端點 + 提示行已拔 + 控制/反代/M3 回歸 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf \"/api/%s → \" \"\$ep\"; curl -s -o /dev/null -w \"%{http_code}\" -m 8 http://127.0.0.1:8088/api/\$ep; echo
done
# 0.8.2 核心:現役 static 不得再含提示行字串
if grep -rq \"網頁終端機內嵌僅於區網\" /opt/portal/static/assets/*.js; then
  echo \"現役 bundle 仍含提示行,部署未生效?\"; exit 1
fi
echo \"提示行已拔 ✓\"
grep -rql \"api/game/action\" /opt/portal/static/assets/*.js || { echo static 無 api/game/action; exit 1; }
# 回歸:CSRF gate / 白名單 / Grafana 反代健康+admin 擋 / M3(全走必被擋路徑,零副作用)
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"open\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"CSRF gate 回歸失敗(無 XRW 應 403):\$code\"; exit 1; }
echo \"game/action 無 X-Requested-With → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -H \"X-Requested-With: XMLHttpRequest\" -H \"Remote-User: e2e\" \
  -d \"{\\\"action\\\":\\\"kill\\\"}\" http://127.0.0.1:8088/api/game/action)
[ \"\$code\" = 403 ] || { echo \"白名單回歸失敗(kill 應 403):\$code\"; exit 1; }
echo \"game/action kill(帶齊 header)→ 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 http://127.0.0.1:8088/grafana/api/health)
[ \"\$code\" = 200 ] || { echo \"Grafana 反代 /api/health 非 200:\$code\"; exit 1; }
echo \"Grafana 反代 /api/health → 200 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -u admin:admin http://127.0.0.1:8088/grafana/api/admin/settings)
[ \"\$code\" = 403 ] || { echo \"高危回歸失敗:admin 管理 API 得 \$code(應 403)\"; exit 1; }
echo \"admin:admin /grafana/api/admin/settings → 403 ✓\"
code=\$(curl -s -o /dev/null -w %{http_code} -m 8 -X POST -H \"Content-Type: application/json\" \
  -d \"{\\\"action\\\":\\\"silence-1h\\\",\\\"param\\\":\\\"X\\\"}\" http://127.0.0.1:8088/api/action)
[ \"\$code\" = 403 ] || { echo \"M3 回歸失敗:\$code\"; exit 1; }
echo \"M3 無 Remote-User → 403 ✓\"
curl -s -m 8 http://127.0.0.1:8088/api/health | grep -q \"ok\" && echo \"health ok ✓\"
'"

echo "== 完成(TS=$TS)。驗收:遊戲頁 portal.hl 不再顯示終端提示行,:8088 終端 iframe 照舊 =="
echo "回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-082-<TS>.tgz"
echo "          + compose 蓋回 _backups/docker-compose.yml.before-portal082-<最早TS> + up -d --force-recreate portal"
