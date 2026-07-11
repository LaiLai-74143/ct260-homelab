#!/bin/bash
# finish-portal-0160.sh — 部署 portal:0.16.0(右鍵 Clawd 問答)+ CT260 life-chat /clawd 端點
#   右鍵吉祥物開對話框 → BFF /api/clawd/chat(Remote-User 驗證,比照生活助理)→
#   CT260 life-chat :5002 /clawd → claude -p(Sonnet 5,Plan 型唯讀:Read 限
#   ~/workspace/ForAI + Glob/Grep,零 MCP、禁 Bash/寫入)。API 只收單一 question
#   不收歷史=每問全新無記憶;與生活助理共用單飛+6/分限速。零新基建:5002 放行
#   與 LIFE_CHAT_URL/TOKEN 皆沿用現有。走查 16/16。
# 在哪跑:CT260(codex@codex-ops)~/workspace/portal/scripts/。冪等:重跑無害。
# 回滾:①life-chat 蓋回 ~/_backups/life-chat.py.before-clawd-<TS> + 重啟;
#      ②portal 照 0150 兩層(src tgz + compose 備份)。
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ROOT=~/workspace/portal
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== A. CT260 life-chat:部署 /clawd 端點 =="
python3 -m py_compile ~/workspace/life-chat/life-chat.py
grep -q '"/clawd"' ~/workspace/life-chat/life-chat.py || { echo "源檔缺 /clawd 路由?"; exit 1; }
mkdir -p ~/_backups
if ! diff -q ~/workspace/life-chat/life-chat.py ~/.local/bin/life-chat.py >/dev/null 2>&1; then
  cp -a ~/.local/bin/life-chat.py ~/_backups/life-chat.py.before-clawd-$TS
  cp ~/workspace/life-chat/life-chat.py ~/.local/bin/life-chat.py
  # 重啟:只殺登記在案的那顆 PID(不按名字連坐),flock wrapper 拉新
  PID=$(pgrep -f "$HOME/.local/bin/life-chat.py" || true)
  [ -n "$PID" ] && kill "$PID" && sleep 1
  ~/.local/bin/life-chat-run.sh &
  sleep 2
else
  echo "life-chat.py 已同步(冪等跳過部署;仍驗證端點)"
fi
curl -s -m 4 http://127.0.0.1:5002/health | grep -q '"ok": *true' || { echo "/health 掛了"; exit 1; }
# shellcheck disable=SC1090
. ~/.config/homelab/life-chat.env
# token 自測法:驗證鏈通、但空 question=400 不起模型、不耗限速
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 6 -X POST -H 'Authorization: Bearer bad-token' \
     -H 'Content-Type: application/json' -d '{"question":"x"}' http://127.0.0.1:5002/clawd)" = "401" ] \
  || { echo "錯 token 未回 401"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 6 -X POST -H "Authorization: Bearer $LIFE_CHAT_TOKEN" \
     -H 'Content-Type: application/json' -d '{"question":""}' http://127.0.0.1:5002/clawd)" = "400" ] \
  || { echo "空 question 未回 400(路由沒上?)"; exit 1; }
echo "life-chat /clawd 驗證鏈 OK(401/400)"

echo "== A2. 真問一句(E2E,起一次 claude -p,約 10–40s)=="
R=$(curl -s -m 120 -X POST -H "Authorization: Bearer $LIFE_CHAT_TOKEN" \
     -H 'Content-Type: application/json' -d '{"question":"用一句話介紹你自己"}' \
     http://127.0.0.1:5002/clawd)
echo "$R" | grep -q '"ok": *true' || { echo "E2E 失敗:$R"; exit 1; }
echo "E2E 回覆:$(echo "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reply"][:120])')"

echo "== B0. 前端 build + 0.16.0 斷言 =="
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "dist 缺 index.html,中止"; exit 1; }
grep -rq "近期行程" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無近期行程字串(回歸基準遺失?)"; exit 1; }
grep -q "clawd-heavy" "$ROOT/frontend/dist/assets"/*.css \
  || { echo "CSS 無 clawd-heavy(0.15.0 吉祥物回歸遺失?)"; exit 1; }
grep -rq "每次對話都是全新的" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無問答框文案(ClawdChat 未接入?)"; exit 1; }
grep -rq "本站吉祥物" "$ROOT/frontend/dist/assets"/*.js \
  || { echo "bundle 無吉祥物台詞(Mascot 未接入 Layout?)"; exit 1; }

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

echo "== B3. CT201:sha 驗證 + 首跑備份 + 換源 + build 0.16.0 =="
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /root/_backups
echo \"\$(sha256sum /tmp/portal-static.tgz)\" | grep -q $STATIC_SHA || { echo static sha 不符; exit 1; }
echo \"\$(sha256sum /tmp/portal-bff.tgz)\"    | grep -q $BFF_SHA    || { echo bff sha 不符; exit 1; }
[ -d /opt/portal/static ] || mv /opt/portal/static.old /opt/portal/static
[ -d /opt/portal/bff ]    || mv /opt/portal/bff.old /opt/portal/bff
ls /root/_backups/portal-src-before-0160-*.tgz >/dev/null 2>&1 \
  || tar -C /opt/portal -czf /root/_backups/portal-src-before-0160-$TS.tgz static bff
rm -rf /opt/portal/static.new /opt/portal/bff.new /opt/portal/static.old /opt/portal/bff.old
mkdir -p /opt/portal/static.new /opt/portal/bff.new
tar -C /opt/portal/static.new -xzf /tmp/portal-static.tgz
tar -C /opt/portal/bff.new    -xzf /tmp/portal-bff.tgz
mv /opt/portal/static /opt/portal/static.old && mv /opt/portal/static.new /opt/portal/static
mv /opt/portal/bff /opt/portal/bff.old       && mv /opt/portal/bff.new /opt/portal/bff
rm -f /tmp/portal-static.tgz /tmp/portal-bff.tgz
docker build -q -t portal:0.16.0 /opt/portal/bff
echo build-OK
'"

echo "== B4. compose 換版 →0.16.0(錨點自適應:0.10~0.15 都收) =="
ssh pve24 'sudo pct exec 201 -- cat /opt/monitoring/docker-compose.yml' > "$TMP/dc.yml"
grep -q "  portal:" "$TMP/dc.yml" || { echo "compose 讀取失敗"; exit 1; }
python3 - "$TMP/dc.yml" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
if "portal:0.16.0" in s:
    print("compose 已是 0.16.0(冪等跳過)")
else:
    m = re.search(r"    image: portal:(0\.1[0-5]\.0)\n", s)
    assert m, "錨點未命中:image tag 非 0.10~0.15(現役版本出乎預期,人工確認)"
    s = s.replace(f"    image: portal:{m.group(1)}", "    image: portal:0.16.0", 1)
    open(p, "w").write(s); print(f"compose edited: {m.group(1)} -> 0.16.0")
EOF
scp -q "$TMP/dc.yml" pve24:/tmp/dc.new.yml
ssh pve24 "sudo pct push 201 /tmp/dc.new.yml /tmp/dc.new.yml && rm -f /tmp/dc.new.yml"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/monitoring/_backups
cp /tmp/dc.new.yml /opt/monitoring/docker-compose.yml.candidate
( cd /opt/monitoring && docker compose -f docker-compose.yml.candidate config -q ) && echo compose-valid
ls /opt/monitoring/_backups/docker-compose.yml.before-portal0160-* >/dev/null 2>&1 \
  || cp -a /opt/monitoring/docker-compose.yml /opt/monitoring/_backups/docker-compose.yml.before-portal0160-$TS
mv /opt/monitoring/docker-compose.yml.candidate /opt/monitoring/docker-compose.yml && rm -f /tmp/dc.new.yml
cd /opt/monitoring && docker compose up -d --force-recreate portal
sleep 2
docker ps --format \"{{.Names}} {{.Image}} {{.Status}}\" | grep portal
rm -rf /opt/portal/static.old /opt/portal/bff.old
'"

echo "== B5. 驗證:端點回歸 + 新端點通路(CT201 視角) =="
for ep in health overview alerts brief services security game life power host/ct201 actions clawd/chat; do
  printf "/api/%s → " "$ep"
  ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 http://127.0.0.1:8088/api/$ep"
  echo
done
# 閘門:直達無 Remote-User → allowed:false;POST → 403
ssh pve24 "sudo pct exec 201 -- curl -s -m 8 http://127.0.0.1:8088/api/clawd/chat" | grep -q '"allowed":false' \
  && echo "閘門 allowed:false OK" || { echo "閘門異常:直達竟 allowed?"; exit 1; }
[ "$(ssh pve24 "sudo pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST \
    -H 'Content-Type: application/json' -d '{\"question\":\"x\"}' http://127.0.0.1:8088/api/clawd/chat")" = "403" ] \
  && echo "閘門 POST 403 OK" || { echo "閘門 POST 未擋"; exit 1; }

echo "== 完成(TS=$TS)。驗收(體感,用 portal.hl):"
echo "   ① 對右下角 Clawd 按右鍵(手機長按)→ 問答框;問「今天備份策略是什麼?」之類,"
echo "      10–40s 回答(它翻 ForAI 文件,唯讀);"
echo "   ② 每問全新:框裡的第二問不會知道第一問;關框重開連畫面都清空;"
echo "   ③ 左鍵戳一下照舊(台詞泡泡;框開著時泡泡讓位);"
echo "   ④ 直達 :8088 右鍵開框會顯示「僅在 portal.hl 登入後提供」=閘門正常;"
echo "   ⑤ 限速與生活助理共池 6 次/分;審計:~/.local/state/life-chat/life-chat.log 找 CLAWD 行。=="
echo "回滾:cp ~/_backups/life-chat.py.before-clawd-$TS ~/.local/bin/life-chat.py + 殺 PID 重拉;"
echo "     portal 照舊:src tgz + compose 備份蓋回 + up -d --force-recreate portal"
