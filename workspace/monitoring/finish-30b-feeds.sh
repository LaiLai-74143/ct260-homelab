#!/bin/bash
# finish-30b-feeds.sh — 待辦30 訂閱源:squid 放行 RSS 域名(永久白名單,agent 改 squid 被攔)
# → 加 6 個推薦源 → 刷新 → 驗證晨報「今日訊息」有實料。
# 在 CT260 以一般使用者執行:bash ~/workspace/monitoring/finish-30b-feeds.sh
# 冪等:重跑無害。回滾:squid.conf 刪該 acl 行+reconfigure;FreshRSS UI 退訂即可。
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)

echo "== 1. CT202 squid:RSS 域名永久放行 =="
ssh pve24 "sudo pct exec 202 -- bash -c '
set -e
cp -a /etc/squid/squid.conf /etc/squid/squid.conf.before-todo30-feeds-$TS
grep -q \"RSS 訂閱源\" /etc/squid/squid.conf || sed -i \"/acl ok dstdomain .home-assistant.io api.met.no/a acl ok dstdomain .ithome.com.tw technews.tw hnrss.org .servethehome.com selfh.st feeds.arstechnica.com   # FreshRSS RSS 訂閱源(待辦30,2026-07-09 使用者點名)\" /etc/squid/squid.conf
squid -k parse >/dev/null && squid -k reconfigure && echo feeds-whitelisted
'"

echo "== 2. 加 6 個推薦源(Google Reader API quickadd) =="
set -a; . ~/.config/homelab/freshrss.env; set +a
BASE="$FRESHRSS_URL/api/greader.php"
AUTH=$(curl -sm10 "$BASE/accounts/ClientLogin" --data-urlencode "Email=$FRESHRSS_USER" --data-urlencode "Passwd=$FRESHRSS_API_PASSWORD" | grep '^Auth=' | cut -d= -f2-)
[ -n "$AUTH" ] || { echo ClientLogin 失敗; exit 1; }
T=$(curl -sm10 -H "Authorization: GoogleLogin auth=$AUTH" "$BASE/reader/api/0/token")
for f in "https://www.ithome.com.tw/rss" "https://technews.tw/feed/" "https://hnrss.org/frontpage" \
         "https://www.servethehome.com/feed/" "https://selfh.st/rss/" "https://feeds.arstechnica.com/arstechnica/index"; do
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$f")
  r=$(curl -sm20 -H "Authorization: GoogleLogin auth=$AUTH" -X POST "$BASE/reader/api/0/subscription/quickadd?quickadd=$enc" --data-urlencode "T=$T")
  echo "$f → $(echo "$r" | head -c 100)"
done
curl -sm10 -H "Authorization: GoogleLogin auth=$AUTH" "$BASE/reader/api/0/subscription/list?output=json" \
  | python3 -c "import json,sys; s=json.load(sys.stdin)['subscriptions']; print('訂閱數:',len(s)); [print(' -',x['title']) for x in s]"

echo "== 3. 刷新(www-data 跑 CLI,不再弄壞擁有權) =="
ssh pve24 "sudo pct exec 270 -- docker exec -u www-data freshrss ./cli/actualize-user.php --user $FRESHRSS_USER" >/dev/null 2>&1 || true
sleep 5

echo "== 4. 驗證:未讀>0 + 晨報實料 =="
UN=$(curl -sm10 -H "Authorization: GoogleLogin auth=$AUTH" "$BASE/reader/api/0/unread-count?output=json" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('max',0))")
echo "未讀:$UN"
python3 ~/.local/bin/homelab-notify.py --write-brief --dry-run >/dev/null 2>&1
python3 - <<'PY'
import json,os
d=json.load(open(os.path.expanduser('~/.local/state/homelab-notify/brief.json')))
b=[s['body'] for s in d['sections'] if s['h']=='今日訊息']
print('今日訊息:', b[0][:200] if b else '段落缺席?!')
PY
echo "== 完成。之後訂閱增減直接在 UI(rss.home.arpa:8082);新域名記得比照第 1 步加 squid 白名單 =="
