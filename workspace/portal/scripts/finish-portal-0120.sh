#!/bin/bash
# finish-portal-0120.sh — 部署 portal:0.12.0(大廳吉祥物 Clawd,使用者點名「右邊有點空+會動的吉祥物」)
#   像素小螃蟹住進大廳模塊格空位(手機 2 欄補滿第 4 列、桌面 3 欄跨兩格補滿右側):
#   待機浮動+眨眼+右螯招手+✻ 閃爍+終端游標;瞳孔跟隨滑鼠;點一下會跳+換台詞(8 句輪播)。
#   kiosk 牆板豁免(不上牆);reduced-motion 全靜默(殺名單+JS 雙層);純裝飾無數據依賴。
#   注意:若現役還是 0.10.0(finish-portal-0110.sh 未跑),本腳本直接跳版帶上 0.11.0
#   滾動進場一併上線,0110 腳本可作廢不必再跑。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-0120-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal0120-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build + 0.12.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "reveal-stagger" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 reveal-stagger(0.11.0 滾動進場回歸遺失?)"; exit 1; }
grep -q "clawd-bob" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-bob(0.12.0 吉祥物未進 bundle?)"; exit 1; }
grep -rq "站點吉祥物" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無吉祥物字串(Mascot 未接入 Home?)"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.12.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0120-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0120-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.12.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.12.0(錨點自適應:0.10.0 或 0.11.0 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.12.0" in s:
    print("compose 已是 0.12.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[01]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10.0/0.11.0(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.12.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.12.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0120-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0120-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== 5. 驗證:端點回歸 + 線上 CSS 含吉祥物動效 =="
for ep in health overview alerts brief services security game life power host/ct201 actions; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/" > "$TMP/index.html"
CSS=$(grep -o 'assets/index-[^"]*\.css' "$TMP/index.html" | head -1)
[ -n "$CSS" ] || { echo "index.html 無 CSS 引用?"; exit 1; }
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/$CSS" | grep -q "clawd-bob" \
  && echo "線上 CSS 含 clawd-bob OK" || { echo "線上 CSS 缺 clawd-bob"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感):"
echo "   ① 大廳模塊卡最後一格=Clawd 像素小螃蟹:會浮動呼吸、眨眼、右螯招手、✻ 閃爍;"
echo "   ② 桌面滑鼠繞著牠移動,瞳孔會跟著看;點/戳牠會跳一下+換一句台詞(8 句輪播);"
echo "   ③ kiosk 牆板沒有牠(刻意);開「減少動態」/手機省電模式=全靜止但完整可見(預期)。"
echo "   若本次是 0.10.0 直跳 0.12.0:0.11.0 滾動進場同時上線,finish-portal-0110.sh 作廢。=="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-0120-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal0120-<最早TS> + up -d --force-recreate portal"
