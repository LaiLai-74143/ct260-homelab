#!/bin/bash
# finish-portal-0100.sh — 部署 portal:0.10.0(D 絲滑包,前端動效五件+BFF 版本號)
#   D1 路由 View Transitions 真 crossfade(拔 key remount 淡入閃)
#   D2 首屏 Skeleton 骨架(九頁;拔掉載入中「0 告警/M2 待接」假數據首繪)
#   D3 數字 count-up+值變微閃(ModuleCard/遊戲/電力/安全大數字)
#   D4 MCSM 控制鍵樂觀更新(按下即轉「啟動中…」,不枯等 webhook 往返;過渡態 5s 輪詢)
#   D5 微互動(按鈕壓下感/Bar 寬度過渡/Toast 兩相離場/確認框縮放進場)
#   全部 prefers-reduced-motion 相容;BFF 僅版本號變更,無 API 變化。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-0100-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal0100-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build + 絲滑包斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "data-flash" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 data-flash(絲滑包未進 bundle?)"; exit 1; }
grep -q "view-transition" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 view-transition(D1 未進 bundle?)"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.10.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0100-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0100-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.10.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.10.0(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.10.0" not in s:
    assert "    image: portal:0.9.2" in s, "錨點未命中:image tag(現役非 0.9.2?)"
    s = s.replace("    image: portal:0.9.2", "    image: portal:0.10.0", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0100-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0100-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:端點回歸 + 靜態資源含絲滑包 =="
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/" > "$TMP/index.html"
CSS=$(grep -o 'assets/index-[^"]*\.css' "$TMP/index.html" | head -1)
[ -n "$CSS" ] || { echo "index.html 無 CSS 引用?"; exit 1; }
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/$CSS" | grep -q "data-flash" \
  && echo "線上 CSS 含 data-flash OK" || { echo "線上 CSS 缺 data-flash"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感,手機/PC40 都可):"
echo "   ① 頁間切換=淡出淡入 crossfade 不閃;② 重整首屏=灰塊骨架不見假數據;"
echo "   ③ 大廳卡片數字變動會滾+微閃;④ 遊戲頁按啟動/停止=立刻轉「切換中」卡;"
echo "   ⑤ 按鈕有壓下感、toast 滑出離場。系統設定開「減少動態效果」後全部靜默。=="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-0100-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal0100-<最早TS> + up -d --force-recreate portal"
