#!/bin/bash
# finish-gate-portal-redirect.sh — 待辦49 追加:單一入口登入後自動轉跳 portal.hl
#
# 內容:把 CT260 源檔 ~/.config/homelab/authelia/gate.py(已改好:發證成功/不需開通
# 分支加 2s meta refresh 轉跳 https://portal.hl.lailai74143.com,失敗分支不轉跳)
# 部署到 CT203 /opt/authelia/gate/gate.py 並重啟 ts-gate。
# 冪等:重跑無害(備份檔帶時間戳,install 覆蓋同內容,restart 安全)。
# 回滾:cp /root/_backups/gate.py.before-portal-redirect-<TS> /opt/authelia/gate/gate.py
#       && systemctl restart ts-gate(CT203 內)
set -euo pipefail

SRC="$HOME/.config/homelab/authelia/gate.py"
TS=$(date +%Y%m%d_%H%M%S)

echo "== 0. 前置檢查 =="
python3 -m py_compile "$SRC" && echo "本地語法 OK"
SRC_SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
echo "源檔 sha256=$SRC_SHA"

echo "== 1. 傳輸到 pve24 =="
scp -q "$SRC" pve24:/tmp/gate.py.new

echo "== 2. push 進 CT203 + 備份 + 驗證 + 安裝 + 重啟 =="
ssh pve24 "sudo pct push 203 /tmp/gate.py.new /tmp/gate.py.new --perms 644"
ssh pve24 "sudo pct exec 203 -- sh -c '
set -e
cp -a /opt/authelia/gate/gate.py /root/_backups/gate.py.before-portal-redirect-'"$TS"'
echo \"備份: /root/_backups/gate.py.before-portal-redirect-'"$TS"'\"
REMOTE_SHA=\$(sha256sum /tmp/gate.py.new | cut -d\" \" -f1)
[ \"\$REMOTE_SHA\" = \"'"$SRC_SHA"'\" ] && echo \"sha256 一致\" || { echo \"sha256 不一致!\"; exit 1; }
python3 -m py_compile /tmp/gate.py.new && echo \"遠端語法 OK\"
install -m 0755 -o root -g root /tmp/gate.py.new /opt/authelia/gate/gate.py
rm -f /tmp/gate.py.new
systemctl restart ts-gate
sleep 1
systemctl is-active ts-gate
'"
ssh pve24 'rm -f /tmp/gate.py.new'

echo "== 3. 功能實測(CT203 內 curl 127.0.0.1:9092,偽造 header 僅本機可達) =="
echo "-- 3a. 內網直連分支:應含「不需要開通」+ portal.hl 轉跳、不寫 nft --"
ssh pve24 "sudo pct exec 203 -- sh -c '
R=\$(curl -s -H \"Remote-User: selftest\" -H \"X-Gate-Client: 192.168.20.60\" http://127.0.0.1:9092/)
echo \"\$R\" | grep -q \"不需要開通\" && echo \"分支訊息 OK\"
echo \"\$R\" | grep -q \"refresh\\\" content=\\\"2;url=https://portal.hl\" && echo \"轉跳 meta OK\"
nft list set inet ctdmz ts_authed_v4 | grep -q 192.168.20.60 && { echo \"不該寫入 nft!\"; exit 1; } || echo \"未寫 nft OK\"
'"
echo "-- 3b. tailnet 發證分支:應發證 + 轉跳,測完清除測試元素 --"
ssh pve24 "sudo pct exec 203 -- sh -c '
R=\$(curl -s -H \"Remote-User: selftest\" -H \"X-Gate-Client: 100.100.1.99\" http://127.0.0.1:9092/)
echo \"\$R\" | grep -q \"已開通內網通行\" && echo \"發證訊息 OK\"
echo \"\$R\" | grep -q \"refresh\\\" content=\\\"2;url=https://portal.hl\" && echo \"轉跳 meta OK\"
nft list set inet ctdmz ts_authed_v4 | grep -q 100.100.1.99 && echo \"nft 元素已寫入 OK\"
nft delete element inet ctdmz ts_authed_v4 \"{ 100.100.1.99 }\" && echo \"測試元素已清除\"
'"
echo "-- 3c. 失敗分支:缺 Remote-User 應 403、不轉跳 --"
ssh pve24 "sudo pct exec 203 -- sh -c '
R=\$(curl -s -w \"HTTP%{http_code}\" -H \"X-Gate-Client: 100.100.1.99\" http://127.0.0.1:9092/)
echo \"\$R\" | grep -q \"HTTP403\" && echo \"403 OK\"
echo \"\$R\" | grep -q \"refresh\" && { echo \"失敗分支不該轉跳!\"; exit 1; } || echo \"不轉跳 OK\"
'"

echo "== 全部通過。回滾備份: CT203:/root/_backups/gate.py.before-portal-redirect-$TS =="
