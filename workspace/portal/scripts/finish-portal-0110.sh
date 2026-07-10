#!/bin/bash
# finish-portal-0110.sh — 部署 portal:0.11.0(滾動進場+互動性 pass,使用者點名)
#   ① 滾動進場:板塊滑入視口時 fade+上滑一次(Reveal.tsx IntersectionObserver),
#     網格卡片級聯(stagger nth-child 遞增 delay)——展示頁式過渡
#   ② 卡片互動:hover 浮起 2px+按壓回彈(card-hover),撒在可點卡片/入口連結
#   豁免三態(reduced-motion/kiosk 輪播/無 IO)=整組不掛 class 內容直接可見,
#   不存在 JS 沒跑內容藏死;告警橫幅 StatusBanner 刻意不進場動畫(緊急資訊不延遲)。
#   全部 prefers-reduced-motion 相容;BFF 僅版本號變更,無 API 變化。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-0110-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal0110-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build + 0.11.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "data-flash" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 data-flash(0.10.0 絲滑包回歸遺失?)"; exit 1; }
grep -q "reveal-stagger" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 reveal-stagger(0.11.0 滾動進場未進 bundle?)"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.11.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0110-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0110-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.11.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.11.0(先驗後裝) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.11.0" not in s:
    assert "    image: portal:0.10.0" in s, "錨點未命中:image tag(現役非 0.10.0?)"
    s = s.replace("    image: portal:0.10.0", "    image: portal:0.11.0", 1)
open(p, "w").write(s); print("compose edited")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0110-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0110-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:端點回歸 + 靜態資源含滾動進場 =="
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/" > "$TMP/index.html"
CSS=$(grep -o 'assets/index-[^"]*\.css' "$TMP/index.html" | head -1)
[ -n "$CSS" ] || { echo "index.html 無 CSS 引用?"; exit 1; }
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/$CSS" | grep -q "reveal-stagger" \
  && echo "線上 CSS 含 reveal-stagger OK" || { echo "線上 CSS 缺 reveal-stagger"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感,手機/PC40 都可):"
echo "   ① 進任一頁往下滑:折下的板塊滑入視口時淡入上滑、網格卡片依序級聯;"
echo "   ② 大廳/設備卡片滑鼠 hover 會浮起 2px、按下回彈;"
echo "   ③ kiosk 牆板照舊瞬切不重播進場;開「減少動態效果」=內容直接全可見不藏。"
echo "   注意:省電模式會觸發 reduced-motion → 全部靜默屬預期(0.10.0 同款)。=="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-0110-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal0110-<最早TS> + up -d --force-recreate portal"
