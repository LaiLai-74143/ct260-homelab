#!/bin/bash
# finish-portal-0130.sh — 部署 portal:0.13.0(吉祥物 Clawd 改版,使用者點名四點)
#   ①全頁面都有:改掛 Layout 層,fixed 漂浮不隨滾動(桌面右側中下、手機右下角 tabbar 上方);
#   ②形象換 Claude Code 官方像素小傢伙(橘方塊+黑方眼+側耳+白腳,--clawd #D97757 官方橘);
#   ③平時蹲下起立循環+眨眼+眼睛跟滑鼠;偶爾顛足球(首次 ~7s、之後每 16s 一輪 3.2s);
#   ④點擊跳+台詞泡泡(8 句輪播)。kiosk 不走 Layout=自然無吉祥物;reduced-motion 全靜默可見。
#   本版依使用者要求跳過多數決審查,走查 21/21(fixed 不隨滾動/顛球/泡泡/reduced/手機定位)。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾(兩層):tar -C /opt/portal -xzf /root/_backups/portal-src-before-0130-<TS>.tgz
#   + compose 蓋回 _backups/docker-compose.yml.before-portal0130-<最早TS> + up -d --force-recreate portal。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build + 0.13.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "reveal-stagger" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 reveal-stagger(0.11.0 滾動進場回歸遺失?)"; exit 1; }
grep -q "clawd-squat" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-squat(0.13.0 蹲起未進 bundle?)"; exit 1; }
grep -q "clawd-ball" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-ball(0.13.0 足球未進 bundle?)"; exit 1; }
grep -rq "本站吉祥物" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無吉祥物台詞(Mascot 未接入 Layout?)"; exit 1; }

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

echo "== 3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.13.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0130-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0130-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.13.0 /opt/portal/bff
echo build-OK
'"

echo "== 4. compose 換版 →0.13.0(錨點自適應:0.10~0.12 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.13.0" in s:
    print("compose 已是 0.13.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-2]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.12(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.13.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.13.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0130-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0130-$TS
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
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/$CSS" | grep -q "clawd-squat" \
  && echo "線上 CSS 含 clawd-squat OK" || { echo "線上 CSS 缺 clawd-squat"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感):"
echo "   ① 任何頁面右側(手機=右下角 tabbar 上方)都有橘色小傢伙,固定不隨滾動;"
echo "   ② 平時蹲下起立+眨眼、眼睛跟滑鼠;開頁 ~7 秒後開始顛足球,之後每 16 秒一輪;"
echo "   ③ 點/戳牠:跳一下+頭上冒台詞泡泡(8 句輪播);"
echo "   ④ kiosk 牆板沒有牠;省電模式/減少動態=靜止但完整可見(預期)。"
echo "   大廳模塊格由吉祥物卡改回 7 卡(牠搬去漂浮了)。=="
echo "回滾:tar -C /opt/portal -xzf /root/_backups/portal-src-before-0130-<TS>.tgz"
echo "     + compose 蓋回 _backups/docker-compose.yml.before-portal0130-<最早TS> + up -d --force-recreate portal"
