#!/bin/bash
# finish-portal-0190.sh — 部署 portal:0.19.0(待辦49 邸報:自動呈報+批閱)
#   拾遺頁加「剪藏/邸報」切換:邸報=dibao-ingest(FreshRSS→DeepSeek 擬題摘要
#   +六部分部+重要性 1-10 評分)自動呈報,按分排序、14 天滾動;閱讀器對邸報件
#   出「批閱」列:准=收編入六部剪藏庫、駁=撤下。L0 卡 sub 加「邸報今日 N」。
#   晨報「今日訊息」同批改評分制 top-7(homelab-notify.py,CT260 側已由 Agent 換版)。
#   走查 e2e-0190-mock.mjs 23/23。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 前置:0180 已上線(archive-svc/防火牆/portal.env 全就位);另跑 finish-dibao.sh 裝 cron。
# 回滾:CT201 /root/_backups/portal-src-before-0190-<TS>.tgz 蓋回
#      + /opt/monitoring/_backups/docker-compose.yml.before-portal0190-<TS> 蓋回
#      + docker compose up -d --force-recreate portal
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== B-1. 前置:CT201 portal.env 須已有 ARCHIVE_ 鍵(infra 腳本先行) =="
N=$(ssh pve24 "sudo pct exec 201 -- grep -c '^ARCHIVE_' /opt/portal/portal.env" || true)
[ "$N" = 2 ] || { echo "portal.env ARCHIVE_ 鍵數='$N'(應為2;空值=ssh/pct/檔案讀取失敗)——先跑 finish-archive-infra.sh"; exit 1; }
echo "portal.env ARCHIVE_ 鍵 ✓"

echo "== B0. 前端 build + 0.19.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
# 本版新物斷言
grep -rq "邸報 · 呈報" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無邸報切換(0.19 未接入?)"; exit 1; }
grep -rq "准 · 收編入庫" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無批閱列"; exit 1; }
grep -rq "portal v0.19" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 版號非 v0.19"; exit 1; }
# 回歸斷言(0.18 拾遺)
grep -rq "拾遺歸檔" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無拾遺歸檔(0.18 回歸遺失?)"; exit 1; }
grep -rq "六部虛位以待" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無空狀態文案(Archive 頁遺失?)"; exit 1; }
grep -rq "禮·典章" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無六部字典"; exit 1; }
# 回歸斷言(既有功能)
grep -rq "命令面板" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無命令面板(0.17.0 回歸遺失?)"; exit 1; }
grep -q "html.night" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 html.night(夜間模式遺失?)"; exit 1; }
grep -q "critbar" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 critbar(戰情模式遺失?)"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
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

echo "== B3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.19.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0190-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0190-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.19.0 /opt/portal/bff
echo build-OK
'"

echo "== B4. compose 換版 →0.19.0(錨點自適應:0.10~0.18 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.19.0" in s:
    print("compose 已是 0.19.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-8]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.18(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.19.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.19.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0190-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0190-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== B5. 驗證:端點回歸 + 新端點(CT201 視角) =="
for ep in health overview alerts brief services security game life power host/ct201 actions clawd/chat spark archive; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
# /api/archive 內容:live 下 items+by_topic 必在,enabled:true
ARC=$(ssh pve24 "sudo pct exec 201 -- curl -s -m 10 http://127.0.0.1:8088/api/archive")
echo "$ARC" | grep -q '"by_topic"' && echo "$ARC" | grep -q '"enabled":true' \
  && echo "archive 列表 OK(total=$(echo "$ARC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'))" \
  || { echo "archive 列表異常:$(echo "$ARC" | head -c 200)"; exit 1; }
# overview modules 須含 archive 卡
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/overview" \
  | python3 -c 'import json,sys; ms=[m["key"] for m in json.load(sys.stdin).get("modules",[])]; assert "archive" in ms, ms; print("overview 拾遺卡 OK:", ms)'
# 0.19 新參數:origin=rss(邸報)200;origin 壞值 400
ARC_RSS=$(ssh pve24 "sudo pct exec 201 -- curl -s -m 10 'http://127.0.0.1:8088/api/archive?origin=rss&sort=score'")
echo "$ARC_RSS" | grep -q '"by_topic"' \
  && echo "邸報列表 OK(rss total=$(echo "$ARC_RSS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'))" \
  || { echo "邸報列表異常:$(echo "$ARC_RSS" | head -c 200)"; exit 1; }
code=$(ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 'http://127.0.0.1:8088/api/archive?origin=bogus'")
[ "$code" = 400 ] && echo "origin 壞值 → 400 ✓" || { echo "預期 400 實得 $code"; exit 1; }
# overview 拾遺卡 sub 應含邸報字樣(live;邸報 0 件也會出「邸報今日 0」)
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/overview" \
  | python3 -c 'import json,sys; m=[x for x in json.load(sys.stdin).get("modules",[]) if x["key"]=="archive"][0]; assert "邸報" in m["sub"], m; print("拾遺卡 sub OK:", m["sub"])'
# 壞 body → 400;無此條目 → 404
code=$(ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST -H 'Content-Type: application/json' -d 'not-json' http://127.0.0.1:8088/api/archive")
[ "$code" = 400 ] && echo "POST 壞 body → 400 ✓" || { echo "預期 400 實得 $code"; exit 1; }
code=$(ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/archive/nonexistent00")
[ "$code" = 404 ] && echo "無此條目 → 404 ✓" || { echo "預期 404 實得 $code"; exit 1; }
# 閘門回歸:直達無 Remote-User → actions allowed:false(動作面不受本版影響)
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/actions" | grep -q '"allowed":false' \
  && echo "actions 閘門 allowed:false OK" || { echo "閘門異常:直達竟 allowed?"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感):"
echo "   ① /m/archive 上方多〔剪藏·六部〕〔邸報·呈報〕切換;邸報按分數排、左側琥珀分數;"
echo "   ② 邸報件進閱讀器有「批閱」列:〔准·收編入庫〕入六部剪藏、〔駁·撤下〕刪除;"
echo "      不批也行,14 天自動清;"
echo "   ③ 大廳拾遺卡 sub 顯「邸報今日 N」;⌘K 只搜剪藏,邸報流水不進面板;"
echo "   ④ 明晨 06:00 晨報「今日訊息」=前一日邸報 top-7(標題——摘要(來源));"
echo "   ⑤ 0.18 剪藏功能全部照舊(收藏/改歸/刪除/g r)。=="
echo "回滾:CT201 tar -C /opt/portal -xzf /root/_backups/portal-src-before-0190-$TS.tgz"
echo "     + cp /opt/monitoring/_backups/docker-compose.yml.before-portal0190-$TS /opt/monitoring/docker-compose.yml"
echo "     + cd /opt/monitoring && docker compose up -d --force-recreate portal"
