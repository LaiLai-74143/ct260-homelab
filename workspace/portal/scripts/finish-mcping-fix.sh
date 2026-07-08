#!/bin/bash
# finish-mcping-fix.sh — 待辦49:CT100 nft 加一條「本機 loopback → 10.70.70.20:25565 accept」
# 原因:mc_backend_guard 兜底 `tcp dport 25565 drop` 未限定介面,連 CT100 本機 MCSM daemon
#      的 mcping 也被丟——玩家數永遠拿不到。僅新增不改舊;Velocity/外部防護不變
#      (drop 兜底仍在,只多放行 iifname "lo")。
# 冪等:重跑無害。回滾:cp /root/nftables.conf.before-mcping-<TS> /etc/nftables.conf && nft -f 之
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p ~/_backups

echo "== 1. 取回 + 錨點編輯(fail-fast) =="
ssh pve24 'sudo pct exec 100 -- cat /etc/nftables.conf' > "$TMP/nft.conf"
grep -q "mc_backend_guard" "$TMP/nft.conf" || { echo "取回內容異常,中止"; exit 1; }
if grep -q 'iifname "lo"' "$TMP/nft.conf"; then
  echo "已套用過(冪等),跳過編輯與套用"
else
  cp "$TMP/nft.conf" ~/_backups/ct100-nftables.conf.before-mcping-"$TS"
  python3 - "$TMP/nft.conf" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
A = "        # Drop all other access to backend Java port."
NEW = """        # Allow local MCSM daemon (mcping) to reach backend Java port via loopback (待辦49 2026-07-08).
        iifname "lo" ip daddr $MC_BACKEND_IP tcp dport $MC_JAVA_PORT accept

""" + A
assert A in s, "錨點未命中"
s = s.replace(A, NEW, 1)
open(p, "w").write(s); print("edited")
EOF
  echo "== 2. CT100:先驗(nft -c)→ 備份 → 套用 =="
  scp -q "$TMP/nft.conf" pve24:/tmp/ct100-nft.new
  ssh pve24 "sudo pct push 100 /tmp/ct100-nft.new /tmp/nftables.conf.new && rm -f /tmp/ct100-nft.new"
  ssh pve24 "sudo pct exec 100 -- sh -c '
set -e
nft -c -f /tmp/nftables.conf.new
cp /etc/nftables.conf /root/nftables.conf.before-mcping-$TS
cp /tmp/nftables.conf.new /etc/nftables.conf && rm -f /tmp/nftables.conf.new
nft -f /etc/nftables.conf
'"
fi

echo "== 3. 驗證:running ruleset + 本機連線 + 回歸(Velocity/CT201 路徑) =="
ssh pve24 'sudo pct exec 100 -- nft list table inet mc_backend_guard' | grep -q 'iifname "lo"' \
  || { echo "running ruleset 未見 loopback 規則,中止"; exit 1; }
ssh pve24 'sudo pct exec 100 -- bash -c "timeout 2 bash -c \"cat < /dev/null > /dev/tcp/10.70.70.20/25565\" && echo \"本機→25565 通\" || { echo \"本機→25565 仍不通\"; exit 1; }"'
ssh pve24 'sudo pct exec 102 -- bash -c "timeout 2 bash -c \"cat < /dev/null > /dev/tcp/10.70.70.20/25565\" && echo \"Velocity→25565 通(回歸OK)\" || { echo \"Velocity 路徑壞了!\"; exit 1; }"'
ssh pve24 'sudo pct exec 201 -- curl -sm5 -o /dev/null -w "CT201→MCSM 23333:%{http_code}\n" http://10.70.70.20:23333/' | grep -q ":200" \
  || { echo "CT201→MCSM 回歸失敗!"; exit 1; }
echo "CT201→MCSM 23333:200 OK"
echo "== 完成(TS=$TS)。接著到 MCSM UI 把 Fabric-MC ping IP 改 10.70.70.20 即點亮玩家數 =="
