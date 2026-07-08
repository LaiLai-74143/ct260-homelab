#!/bin/bash
# finish-mcsm-access.sh — 待辦49:開通 PC40(192.168.40.4)→ MCSManager web(10.70.70.20:23333)
# 變更=兩條「新增」:OpenWrt 防火牆 rule 一條 + CT100 本機 nft 一條;不動任何既有規則。
# 冪等:重跑無害(規則存在即跳過;備份帶時間戳)。
# 用法:./finish-mcsm-access.sh [--with-phone]
#   --with-phone:CT100 nft 額外點名 10.60.60.10(發證後手機經 CT203 masq;OpenWrt 側
#   dmz proto-all 既有規則已涵蓋,無需加 OpenWrt 規則)。
# 回滾:
#   OpenWrt: uci delete firewall.allow_pc40_to_game_mcsm && uci commit firewall && /etc/init.d/firewall reload
#   CT100:   cp /root/nftables.conf.before-mcsm-<TS> /etc/nftables.conf && nft -f /etc/nftables.conf
#   ★ 備份帶時間戳且僅在實際改動前產生;回滾一律取「最早」的 before-mcsm TS。
set -euo pipefail

case "${1:-}" in
  ""|--with-phone) WITH_PHONE="${1:-}" ;;
  *) echo "未知參數:$1(僅支援 --with-phone)"; exit 1 ;;
esac
TS=$(date +%Y%m%d_%H%M%S)
RTR() { ssh openwrt "$@"; }   # ~/.ssh/config Host openwrt=192.168.10.1:52438 root(dropbear 金鑰,V7 §4.2)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p ~/_backups

echo "== 0. 連線預檢 =="
RTR "echo openwrt-OK"        || { echo "ssh openwrt 連不上,中止"; exit 1; }
ssh pve24 'echo pve24-OK'    || { echo "ssh pve24 連不上,中止"; exit 1; }

echo "== 1. OpenWrt:zone 先驗 + 僅在需改動時備份(router 本機 + CT260 雙份)+ 加規則 =="
RTR "uci show firewall | grep -q \"name='trusted'\"" || { echo "zone trusted 不存在,中止"; exit 1; }
RTR "uci show firewall | grep -q \"name='game'\""    || { echo "zone game 不存在,中止"; exit 1; }
if RTR "uci -q get firewall.allow_pc40_to_game_mcsm" >/dev/null 2>&1; then
  echo "OpenWrt 規則已存在(config/staged),跳過備份與 uci set"
else
  RTR "cp /etc/config/firewall /etc/config/firewall.before-mcsm-$TS"
  RTR "cat /etc/config/firewall" > ~/_backups/firewall.before-mcsm-"$TS"
  [ -s ~/_backups/firewall.before-mcsm-"$TS" ] || { echo "CT260 側備份為空,中止"; exit 1; }
  RTR "uci set firewall.allow_pc40_to_game_mcsm=rule && \
uci set firewall.allow_pc40_to_game_mcsm.name='Allow-PC40-To-Game-MCSM-23333' && \
uci set firewall.allow_pc40_to_game_mcsm.src='trusted' && \
uci set firewall.allow_pc40_to_game_mcsm.src_ip='192.168.40.4' && \
uci set firewall.allow_pc40_to_game_mcsm.dest='game' && \
uci set firewall.allow_pc40_to_game_mcsm.dest_ip='10.70.70.20' && \
uci set firewall.allow_pc40_to_game_mcsm.dest_port='23333' && \
uci set firewall.allow_pc40_to_game_mcsm.proto='tcp' && \
uci set firewall.allow_pc40_to_game_mcsm.target='ACCEPT' && \
uci commit firewall"
fi
# reload 無條件跑(對已載入規則重載無害):補救「commit 成功但上次 reload 失敗」的殘局
RTR "/etc/init.d/firewall reload"
RTR "uci show firewall.allow_pc40_to_game_mcsm"
# running ruleset 驗證(fw4 以規則名作 comment,對 config-only/staged 殘局 fail-fast)
RTR "nft list ruleset | grep -q 'Allow-PC40-To-Game-MCSM-23333'" \
  || { echo "running ruleset 未見新規則(檢查 uci changes 是否有未 commit 殘留),中止"; exit 1; }
echo "running ruleset 已載入新規則 OK"

echo "== 3. OpenWrt reload 後回歸抽查(既有跨 VLAN 路徑仍通) =="
curl -sm4 -o /dev/null -w "CT260→Loki 3100:%{http_code}\n" http://10.80.80.11:3100/ready \
  || { echo "既有放行路徑失效!檢查 firewall reload"; exit 1; }

echo "== 4. CT100:取回 nftables.conf,本地錨點編輯(fail-fast) =="
ssh pve24 'sudo pct exec 100 -- cat /etc/nftables.conf' > "$TMP/nft.conf"
grep -q "mc_backend_guard" "$TMP/nft.conf" || { echo "取回內容異常,中止"; exit 1; }
# 僅未套用過才留 CT260 側備份(避免重跑產生「名為 before、內容為 after」的假備份)
grep -q "define PC40_IP" "$TMP/nft.conf" || cp "$TMP/nft.conf" ~/_backups/ct100-nftables.conf.before-mcsm-"$TS"
WITH_PHONE="$WITH_PHONE" python3 - "$TMP/nft.conf" <<'EOF'
import os, sys
p = sys.argv[1]; s = open(p).read()
def sub_once(text, old, new, marker, why):
    if marker in text:
        return text  # 已套用過(冪等)
    out = text.replace(old, new, 1)
    assert out != text, f"錨點未命中:{why}"
    return out

A_DEF = "define MONITOR_IP = 10.70.70.11"
s = sub_once(s, A_DEF, A_DEF + """

# [CONST: PC40_IP] PC40 user workstation (trusted VLAN40, routed via OpenWrt; 待辦49 2026-07-08)
define PC40_IP = 192.168.40.4""", "define PC40_IP", "PC40_IP define")

A_DROP = "        # Drop all other access to backend Java port."
s = sub_once(s, A_DROP, """        # Allow PC40 to reach MCSManager web UI (via OpenWrt inter-VLAN; 待辦49 2026-07-08).
        iifname "eth2" ip saddr $PC40_IP ip daddr $MC_BACKEND_IP tcp dport $MCS_WEB_PORT accept

""" + A_DROP, "saddr $PC40_IP", "PC40 rule")

if os.environ.get("WITH_PHONE") == "--with-phone":
    s = sub_once(s, "define PC40_IP = 192.168.40.4", """define PC40_IP = 192.168.40.4

# [CONST: TS_GATE_IP] CT203 subnet-router masq source (tailnet 發證後手機; 待辦49 2026-07-08)
define TS_GATE_IP = 10.60.60.10""", "define TS_GATE_IP", "TS_GATE_IP define")
    s = sub_once(s, A_DROP, """        # Allow authed tailnet phone (masq as CT203) to reach MCSManager web UI (待辦49 2026-07-08).
        iifname "eth2" ip saddr $TS_GATE_IP ip daddr $MC_BACKEND_IP tcp dport $MCS_WEB_PORT accept

""" + A_DROP, "saddr $TS_GATE_IP", "TS_GATE rule")

open(p, "w").write(s); print("nft.conf edited")
EOF

echo "== 5. CT100:先驗(nft -c)→ 僅在內容有變時備份+換檔 → running state 缺規則才套用 =="
scp -q "$TMP/nft.conf" pve24:/tmp/ct100-nft.new
ssh pve24 "sudo pct push 100 /tmp/ct100-nft.new /tmp/nftables.conf.new && rm -f /tmp/ct100-nft.new"
ssh pve24 "sudo pct exec 100 -- sh -c '
set -e
nft -c -f /tmp/nftables.conf.new
if cmp -s /tmp/nftables.conf.new /etc/nftables.conf; then
  echo \"檔案內容相同(冪等重跑),不另備份\"
else
  cp /etc/nftables.conf /root/nftables.conf.before-mcsm-$TS
  cp /tmp/nftables.conf.new /etc/nftables.conf
fi
rm -f /tmp/nftables.conf.new
# running state 缺新規則才 nft -f(涵蓋「檔案已換但上次套用失敗」殘局;重跑不無謂 flush)
nft list table inet mc_backend_guard | grep -q \"192.168.40.4\" || nft -f /etc/nftables.conf
nft list table inet mc_backend_guard | grep -q \"192.168.40.4\" \
  || { echo \"running ruleset 未見 PC40 規則,中止\"; exit 1; }
echo \"-- 23333 相關規則 --\"
nft list table inet mc_backend_guard | grep 23333
'"
if [ "$WITH_PHONE" = "--with-phone" ]; then
  ssh pve24 'sudo pct exec 100 -- nft list table inet mc_backend_guard' | grep -q "10.60.60.10" \
    || { echo "--with-phone 但 running ruleset 未見 10.60.60.10,中止"; exit 1; }
  echo "手機(10.60.60.10)規則已載入 OK"
fi

echo "== 6. 回歸:CT201 → MCSM 監控面必須仍通(200) =="
ssh pve24 'sudo pct exec 201 -- curl -sm5 -o /dev/null -w "CT201→MCSM 23333:%{http_code}\n" http://10.70.70.20:23333/' \
  | grep -q ":200" || { echo "CT201→MCSM 回歸失敗!"; exit 1; }
echo "CT201→MCSM 23333:200 OK"

echo "== 完成。PC40 瀏覽器開 http://10.70.70.20:23333 應可達;備份:router+CT100 本機 & ~/_backups(TS=$TS) =="
