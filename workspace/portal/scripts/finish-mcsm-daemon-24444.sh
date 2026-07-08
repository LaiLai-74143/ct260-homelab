#!/bin/bash
# finish-mcsm-daemon-24444.sh — 待辦49:放行 MCSM daemon ws 埠 24444(網頁控制台即時終端)
# 為何要:MCSM 網頁(23333)已放行,但即時終端由瀏覽器直連 daemon ws://10.70.70.20:24444;
#         24444 未在 CT100 mc_backend_guard 白名單 → 面板載得出、終端連不上(xhr poll error)。
# 變更=兩處「新增」,比照既有 23333:
#   OpenWrt +Allow-PC40-To-Game-MCSM-Daemon-24444(trusted 192.168.40.4 → game :24444);
#           手機(dmz 10.60.60.10→game proto-all)OpenWrt 層既有涵蓋,不加 OpenWrt 規則。
#   CT100 nft +define MCS_DAEMON_PORT=24444 + PC40/TS_GATE 兩條 24444 accept(兜底 drop 前)。
# 冪等:重跑無害。回滾:
#   OpenWrt: uci delete firewall.allow_pc40_to_game_mcsdaemon && uci commit firewall && /etc/init.d/firewall reload
#   CT100:   cp /root/nftables.conf.before-24444-<TS> /etc/nftables.conf && nft -f /etc/nftables.conf
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)
RTR() { ssh openwrt "$@"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p ~/_backups

echo "== 0. 連線預檢 =="
RTR "echo openwrt-OK"     || { echo "ssh openwrt 連不上,中止"; exit 1; }
ssh pve24 'echo pve24-OK' || { echo "ssh pve24 連不上,中止"; exit 1; }

echo "== 1. OpenWrt:zone 先驗 + 僅在需改動時備份 + 加 PC40→24444 =="
RTR "uci show firewall | grep -q \"name='trusted'\"" || { echo "zone trusted 不存在,中止"; exit 1; }
RTR "uci show firewall | grep -q \"name='game'\""    || { echo "zone game 不存在,中止"; exit 1; }
if RTR "uci -q get firewall.allow_pc40_to_game_mcsdaemon" >/dev/null 2>&1; then
  echo "OpenWrt 規則已存在,跳過備份與 uci set"
else
  RTR "cp /etc/config/firewall /etc/config/firewall.before-24444-$TS"
  RTR "cat /etc/config/firewall" > ~/_backups/firewall.before-24444-"$TS"
  [ -s ~/_backups/firewall.before-24444-"$TS" ] || { echo "CT260 側備份為空,中止"; exit 1; }
  RTR "uci set firewall.allow_pc40_to_game_mcsdaemon=rule && \
uci set firewall.allow_pc40_to_game_mcsdaemon.name='Allow-PC40-To-Game-MCSM-Daemon-24444' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.src='trusted' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.src_ip='192.168.40.4' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.dest='game' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.dest_ip='10.70.70.20' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.dest_port='24444' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.proto='tcp' && \
uci set firewall.allow_pc40_to_game_mcsdaemon.target='ACCEPT' && \
uci commit firewall"
fi
RTR "/etc/init.d/firewall reload"
RTR "nft list ruleset | grep -q 'Allow-PC40-To-Game-MCSM-Daemon-24444'" \
  || { echo "OpenWrt running ruleset 未見 24444 規則,中止"; exit 1; }
echo "OpenWrt 24444 規則已載入 OK"

echo "== 2. CT100:取回 + 錨點編輯(define + 兩條 accept;fail-fast) =="
ssh pve24 'sudo pct exec 100 -- cat /etc/nftables.conf' > "$TMP/nft.conf"
grep -q "mc_backend_guard" "$TMP/nft.conf" || { echo "取回內容異常,中止"; exit 1; }
grep -q "MCS_DAEMON_PORT" "$TMP/nft.conf" || cp "$TMP/nft.conf" ~/_backups/ct100-nftables.conf.before-24444-"$TS"
python3 - "$TMP/nft.conf" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
def sub_once(text, old, new, marker, why):
    if marker in text:
        return text
    out = text.replace(old, new, 1)
    assert out != text, f"錨點未命中:{why}"
    return out

A_DEF = "define MCS_WEB_PORT = 23333"
s = sub_once(s, A_DEF, A_DEF + """

# [CONST: MCS_DAEMON_PORT] MCSManager daemon websocket port (即時終端;待辦49 2026-07-08)
define MCS_DAEMON_PORT = 24444""", "MCS_DAEMON_PORT", "MCS_DAEMON_PORT define")

# 在 23333 的 TS_GATE 那條之後補 24444 兩條(緊跟既有 23333 放行,語意成組)
A_RULE = '        iifname "eth2" ip saddr $TS_GATE_IP ip daddr $MC_BACKEND_IP tcp dport $MCS_WEB_PORT accept'
s = sub_once(s, A_RULE, A_RULE + """

        # Allow PC40 to reach MCSManager daemon websocket (web console terminal; 待辦49 2026-07-08).
        iifname "eth2" ip saddr $PC40_IP ip daddr $MC_BACKEND_IP tcp dport $MCS_DAEMON_PORT accept

        # Allow authed tailnet phone (masq as CT203) to reach MCSManager daemon websocket (待辦49 2026-07-08).
        iifname "eth2" ip saddr $TS_GATE_IP ip daddr $MC_BACKEND_IP tcp dport $MCS_DAEMON_PORT accept""",
    "MCS_DAEMON_PORT accept", "24444 accept rules")
open(p, "w").write(s); print("nft.conf edited")
EOF

echo "== 3. CT100:先驗(nft -c)→ 僅內容有變才備份+換檔 → running state 缺規則才套用 =="
scp -q "$TMP/nft.conf" pve24:/tmp/ct100-nft.new
ssh pve24 "sudo pct push 100 /tmp/ct100-nft.new /tmp/nftables.conf.new && rm -f /tmp/ct100-nft.new"
ssh pve24 "sudo pct exec 100 -- sh -c '
set -e
nft -c -f /tmp/nftables.conf.new
if cmp -s /tmp/nftables.conf.new /etc/nftables.conf; then
  echo \"檔案內容相同(冪等重跑),不另備份\"
else
  cp /etc/nftables.conf /root/nftables.conf.before-24444-$TS
  cp /tmp/nftables.conf.new /etc/nftables.conf
fi
rm -f /tmp/nftables.conf.new
nft list table inet mc_backend_guard | grep -q \"24444\" || nft -f /etc/nftables.conf
nft list table inet mc_backend_guard | grep -q \"24444\" || { echo \"running ruleset 未見 24444,中止\"; exit 1; }
echo \"-- 24444 相關規則 --\"
nft list table inet mc_backend_guard | grep 24444
'"

echo "== 4. 回歸:既有 23333 監控面 + 25565 遊戲路徑不受影響 =="
ssh pve24 'sudo pct exec 201 -- curl -sm5 -o /dev/null -w "CT201→MCSM 23333:%{http_code}\n" http://10.70.70.20:23333/' | grep -q ":200" \
  || { echo "CT201→MCSM 23333 回歸失敗!"; exit 1; }
ssh pve24 'sudo pct exec 102 -- bash -c "timeout 2 bash -c \"cat < /dev/null > /dev/tcp/10.70.70.20/25565\" && echo \"Velocity→25565 通(回歸OK)\" || { echo \"Velocity 路徑壞了!\"; exit 1; }"'
echo "CT201→MCSM 23333:200 OK"
echo "== 完成(TS=$TS)。PC40/手機重新整理 MCSM 網頁,終端應可連(ws://10.70.70.20:24444);"
echo "   備份:OpenWrt firewall.before-24444 + CT100 nftables.conf.before-24444 + CT260 ~/_backups =="
