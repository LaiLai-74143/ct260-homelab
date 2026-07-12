#!/bin/bash
# finish-archive-infra.sh — 拾遺歸檔(待辦49 拾遺板塊)基建三件:
#   1) CT260 archive-svc 安裝/更新(rev 不符自動重啟)+ cron 常駐(@reboot + */5 自癒)
#   2) OpenWrt 放行 10.80.80.11 → 192.168.20.60 tcp/5003(照 LifeChat-5002 模板,不加 SNAT)
#   3) CT201 portal.env 補 ARCHIVE_URL/ARCHIVE_TOKEN(token 走暫存檔,不經 ps)
# 在哪跑:CT260(codex@codex-ops)~/workspace/archive-svc/。冪等:重跑無害。
# 前置:~/.config/homelab/archive.env(ARCHIVE_TOKEN)與 deepseek.env 已存在。
# 回滾:ssh openwrt "uci delete firewall.allow_monitor_to_ct260_archive; uci commit firewall; /etc/init.d/firewall reload"
#       + CT201 portal.env 蓋回 /opt/portal/_backups/portal.env.before-archive-<TS>
#       + CT260 crontab 刪 archive-svc-run.sh 兩行
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
ENV=~/.config/homelab/archive.env
SRC=~/workspace/archive-svc
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前檢 =="
[ -f "$ENV" ] || { echo "缺 $ENV(先生成 ARCHIVE_TOKEN)"; exit 1; }
grep -q '^ARCHIVE_TOKEN=' "$ENV" || { echo "$ENV 缺 ARCHIVE_TOKEN"; exit 1; }
[ -f ~/.config/homelab/deepseek.env ] || { echo "缺 deepseek.env"; exit 1; }
ssh -o ConnectTimeout=6 openwrt true || { echo "openwrt ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }
ssh -o ConnectTimeout=6 pve24 true   || { echo "pve24 ssh 不可達(金鑰上鎖?先 hl-unlock)"; exit 1; }

echo "== 1. CT260 安裝/更新 + rev 檢查重啟 =="
install -m 644 "$SRC/archive-svc.py" ~/.local/bin/archive-svc.py
install -m 755 "$SRC/archive-svc-run.sh" ~/.local/bin/archive-svc-run.sh
FILE_REV=$(grep -oP 'SERVICE_REV = "\K[^"]+' ~/.local/bin/archive-svc.py)
RUN_REV=$(curl -s -m 4 http://127.0.0.1:5003/health | grep -oP '"rev": "\K[^"]+' || true)
if [ "$RUN_REV" != "$FILE_REV" ]; then
  echo "rev 不符(跑著=$RUN_REV 檔案=$FILE_REV)→ 重啟"
  pkill -f '/home/codex/.local/bin/archive-svc.py' 2>/dev/null || true
  sleep 1
  ~/.local/bin/archive-svc-run.sh &
  sleep 1.5
fi
curl -s -m 4 http://127.0.0.1:5003/health | grep -q '"ok": true' || { echo "archive-svc :5003 起不來,見 ~/.local/state/archive-svc/archive-svc.log"; exit 1; }
echo "archive-svc rev=$(curl -s -m 4 http://127.0.0.1:5003/health | grep -oP '\"rev\": \"\K[^\"]+') ✓"

# grep -v 零輸出時 exit 1,pipefail 下會讓子殼在 echo 前中止 → crontab 收空輸入=清空
# 全部 cron(獨立驗證揪出的 footgun)——|| true 保底
( crontab -l 2>/dev/null | grep -v 'archive-svc-run.sh' || true ;
  echo '# archive-svc: 拾遺歸檔(六部剪藏+DeepSeek 歸納) :5003 (待辦#49, added 2026-07-11)' ;
  echo '@reboot sleep 25 && /home/codex/.local/bin/archive-svc-run.sh' ;
  echo '*/5 * * * * /home/codex/.local/bin/archive-svc-run.sh' ) | crontab -
echo "cron 行數(應為2):$(crontab -l | grep -c 'archive-svc-run.sh' || true)"

echo "== 2. OpenWrt 放行 5003(冪等) =="
if ssh openwrt "uci -q get firewall.allow_monitor_to_ct260_archive.name" >/dev/null 2>&1; then
  echo "規則已存在,跳過"
else
  ssh openwrt "cp /etc/config/firewall /etc/config/firewall.bak-archive-$TS"
  mkdir -p ~/_backups
  ssh openwrt "cat /etc/config/firewall" > ~/_backups/openwrt-firewall.before-archive-$TS
  ssh openwrt "
    uci set firewall.allow_monitor_to_ct260_archive=rule
    uci set firewall.allow_monitor_to_ct260_archive.name='Allow-Monitor-To-CT260-Archive-5003'
    uci set firewall.allow_monitor_to_ct260_archive.src='service'
    uci set firewall.allow_monitor_to_ct260_archive.src_ip='10.80.80.11'
    uci set firewall.allow_monitor_to_ct260_archive.dest='servers'
    uci set firewall.allow_monitor_to_ct260_archive.dest_ip='192.168.20.60'
    uci set firewall.allow_monitor_to_ct260_archive.dest_port='5003'
    uci set firewall.allow_monitor_to_ct260_archive.proto='tcp'
    uci set firewall.allow_monitor_to_ct260_archive.target='ACCEPT'
    uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1"
fi
ssh openwrt "nft list ruleset | grep -q 'Archive-5003'" && echo "nft 已載入 Archive-5003 ✓" \
  || { echo "nft 驗證失敗"; exit 1; }
# 回歸抽查:既有 5001/5002 放行不受影響
ssh pve24 "sudo pct exec 201 -- curl -s -m 4 -o /dev/null -w '%{http_code}' http://192.168.20.60:5001/health" \
  | grep -q 200 && echo "回歸:CT201→CT260:5001 仍通 ✓" || { echo "回歸失敗:5001 不通了"; exit 1; }
ssh pve24 "sudo pct exec 201 -- curl -s -m 4 http://192.168.20.60:5002/health" | grep -q '"ok": true' \
  && echo "回歸:CT201→CT260:5002 仍通 ✓" || { echo "回歸失敗:5002 不通了"; exit 1; }

echo "== 3. CT201 portal.env 補鍵(token 經暫存檔,不經 ps) =="
TOK=$(grep '^ARCHIVE_TOKEN=' "$ENV" | cut -d= -f2-)
[ -n "$TOK" ] || { echo "env 缺 ARCHIVE_TOKEN"; exit 1; }
umask 077
cat > "$TMP/archive.frag" <<EOF
ARCHIVE_URL=http://192.168.20.60:5003
ARCHIVE_TOKEN=$TOK
EOF
scp -q "$TMP/archive.frag" pve24:/tmp/archive.frag.$$
ssh pve24 "sudo pct push 201 /tmp/archive.frag.$$ /tmp/archive.frag && rm -f /tmp/archive.frag.$$"
ssh pve24 "sudo pct exec 201 -- bash -c '
set -e
mkdir -p /opt/portal/_backups
cp -a /opt/portal/portal.env /opt/portal/_backups/portal.env.before-archive-$TS
grep -v \"^ARCHIVE_\" /opt/portal/portal.env > /opt/portal/portal.env.new
cat /tmp/archive.frag >> /opt/portal/portal.env.new
cp /opt/portal/portal.env.new /opt/portal/portal.env && rm -f /opt/portal/portal.env.new /tmp/archive.frag
chmod 600 /opt/portal/portal.env
grep -c \"^ARCHIVE_\" /opt/portal/portal.env | xargs echo \"portal.env ARCHIVE_ 鍵數(應為2):\"
'"

echo "== 4. CT201 視角通路驗證 =="
ssh pve24 "sudo pct exec 201 -- curl -s -m 4 http://192.168.20.60:5003/health" | grep -q '"ok": true' \
  && echo "CT201→CT260:5003 /health ✓" || { echo "5003 不通"; exit 1; }
code=$(ssh pve24 "sudo pct exec 201 -- curl -s -m 6 -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer wrong' http://192.168.20.60:5003/list")
[ "$code" = 401 ] && echo "錯 token → 401 ✓" || { echo "預期 401 實得 $code"; exit 1; }

echo "== 完成(TS=$TS)。下一步:finish-portal-0180.sh 部署前端+BFF 0.18.0 =="
