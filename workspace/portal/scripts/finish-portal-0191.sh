#!/bin/bash
# finish-portal-0191.sh — 部署 portal:0.19.1(待辦49 邸報使用者回饋兩修)
#   ① 邸報頁不再平鋪:同剪藏依吏戶禮兵刑工六部分區(組內仍按門下省評分高→低);
#   ② 邸報閱讀器不再只丟連結:full_text 帶【AI 導讀】(dibao-ingest v2 入庫時生成;
#      既有 38 筆由 Agent 以 dibao-brief-backfill.py 回填,CT260 側已完成)。
#   走查 e2e-0190-mock.mjs 26/26(0.19.1 斷言已併入)。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 前置:0.19.0 已上線(finish-portal-0190.sh);CT260 側 v2+回填由 Agent 先行完成。
# 回滾:CT201 /root/_backups/portal-src-before-0191-<TS>.tgz 蓋回
#      + /opt/monitoring/_backups/docker-compose.yml.before-portal0191-<TS> 蓋回
#      + docker compose up -d --force-recreate portal
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== B0. 前端 build + 0.19.1 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
# 本版新物斷言:版徽 0.19.1(六部分區共用剪藏字串,無獨有文案,靠版徽釘版)
grep -rq "portal v0.19.1" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 版號非 v0.19.1(Layout 徽章未跟版?)"; exit 1; }
# 回歸斷言(0.19.0 邸報)
grep -rq "邸報 · 呈報" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無邸報切換(0.19 回歸遺失?)"; exit 1; }
grep -rq "准 · 收編入庫" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無批閱列"; exit 1; }
# 回歸斷言(0.18 拾遺+既有功能)
grep -rq "拾遺歸檔" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無拾遺歸檔(0.18 回歸遺失?)"; exit 1; }
grep -rq "六部虛位以待" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無空狀態文案(Archive 頁遺失?)"; exit 1; }
grep -rq "禮·典章" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無六部字典"; exit 1; }
grep -rq "命令面板" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無命令面板(0.17.0 回歸遺失?)"; exit 1; }
grep -q "html.night" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 html.night(夜間模式遺失?)"; exit 1; }
grep -q "critbar" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 critbar(戰情模式遺失?)"; exit 1; }
grep -rq "每次對話都是全新的" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無問答框文案(0.16.0 回歸遺失?)"; exit 1; }

echo "== B1. 打包 static + bff =="
tar -C "$ROOT/frontend/dist" -czf "$TMP/portal-static.tgz" .
tar -C "$ROOT/bff" --exclude .venv --exclude '__pycache__' \
    -czf "$TMP/portal-bff.tgz" app Dockerfile requirements.txt
STATIC_SHA=$(sha256sum "$TMP/portal-static.tgz" | cut -d' ' -f1)
BFF_SHA=$(sha256sum "$TMP/portal-bff.tgz" | cut -d' ' -f1)

echo "== B2. 傳輸 pve24 → pct push CT201 =="
scp -q "$TMP/portal-static.tgz" "$TMP/portal-bff.tgz" pve24:/tmp/
ssh pve24 'sudo pct push 201 /tmp/portal-static.tgz /tmp/portal-static.tgz && \
           sudo pct push 201 /tmp/portal-bff.tgz /tmp/portal-bff.tgz && \
           rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz'

echo "== B3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.19.1 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0191-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0191-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.19.1 /opt/portal/bff
echo build-OK
'"

echo "== B4. compose 換版 →0.19.1(錨點自適應:0.10~0.19 的 .0 版都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.19.1" in s:
    print("compose 已是 0.19.1(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-9]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.19 的 .0 版(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.19.1", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.19.1")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0191-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0191-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== B5. 驗證:端點回歸 + 0.19.1 新物(CT201 視角) =="
for ep in health overview alerts brief services security game life power host/ct201 actions clawd/chat spark archive; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
# 邸報列表照舊
ARC_RSS=$(ssh pve24 "sudo pct exec 201 -- curl -s -m 10 'http://127.0.0.1:8088/api/archive?origin=rss&sort=score'")
echo "$ARC_RSS" | grep -q '"by_topic"' \
  && echo "邸報列表 OK(rss total=$(echo "$ARC_RSS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'))" \
  || { echo "邸報列表異常:$(echo "$ARC_RSS" | head -c 200)"; exit 1; }
# 0.19.1 新物:任取一筆邸報件,閱讀器正文應含【AI 導讀】(回填+v2 已在 CT260 完成)
RSS_ID=$(echo "$ARC_RSS" | python3 -c 'import json,sys; it=json.load(sys.stdin)["items"]; print(it[0]["id"] if it else "")')
if [ -n "$RSS_ID" ]; then
  ssh pve24 "sudo pct exec 201 -- curl -s -m 10 http://127.0.0.1:8088/api/archive/$RSS_ID" \
    | grep -q '【AI 導讀】' && echo "邸報件帶 AI 導讀 ✓($RSS_ID)" \
    || { echo "邸報件無 AI 導讀(回填沒生效?查 CT260 backfill)"; exit 1; }
else
  echo "邸報 0 件,導讀抽查跳過(14 天清空屬正常)"
fi
# 閘門回歸:直達無 Remote-User → actions allowed:false
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/actions" | grep -q '"allowed":false' \
  && echo "actions 閘門 allowed:false OK" || { echo "閘門異常:直達竟 allowed?"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感):"
echo "   ① /m/archive 邸報 tab 改六部分區(吏戶禮兵刑工,空部不出),組內仍高分在前;"
echo "   ② 點進邸報件:正文開頭【AI 導讀】2-4 句講清楚在寫什麼,連結串不再當正文;"
echo "   ③ 側欄版徽 portal v0.19.1;其餘(准駁/⌘K/晨報)照 0.19.0。=="
echo "回滾:CT201 tar -C /opt/portal -xzf /root/_backups/portal-src-before-0191-$TS.tgz"
echo "     + cp /opt/monitoring/_backups/docker-compose.yml.before-portal0191-$TS /opt/monitoring/docker-compose.yml"
echo "     + cd /opt/monitoring && docker compose up -d --force-recreate portal"
