#!/bin/bash
# finish-22-keylock.sh — 待辦22:金鑰雙軌+高權鑰 6h 自動上鎖(使用者自訂方案,2026-07-09 裁定)
# ★互動式:中途會要你「自訂並輸入」ops 鑰密碼(兩次)+解鎖一次——密碼不落地,只進 KDF。
# 在 CT260 以一般使用者、開著終端執行:bash ~/workspace/monitoring/finish-22-keylock.sh
#
# 架構(鎖線=直 root 面;pct 面=自動化命脈常開):
#   自動軌 ct260_auto_ed25519(不加密)→ pve24(codex-admin,sudo 僅 pct/qm/pvesh/pvesm)
#     + openwrt/routerpve(root,僅供夜間 ansible 設定備份)——authorized_keys 一律
#     from="192.168.20.60"+no-*-forwarding:金鑰外流到別台即失效。
#   互動軌 ct260_ops_ed25519 → 加 passphrase(檔案靜態加密)+ ssh-agent -t 6h(hl-unlock)。
#     鎖定時:agent(Claude)與任何人皆無法直連 openwrt/routerpve/dxp4800/pve24 直 ssh 面。
#   殘餘風險(明文入檔):auto 鑰在 openwrt/routerpve=root——為夜備連續性的已知取捨;
#     wazuh FIM 對 authorized_keys 變動有 L10 告警兜底。github 部署鑰維持明文(單 repo 限權)。
# 回滾:~/_backups/todo22-<TS>/ 蓋回全部;各節點 authorized_keys 刪 ct260-automation 行;
#       ssh-keygen -p 可再移除 passphrase(需知道密碼)。
set -euo pipefail
TS=$(date +%Y%m%d_%H%M%S)
BK=~/_backups/todo22-$TS; mkdir -p "$BK"
OPS=~/.ssh/ct260_ops_ed25519
AUTO=~/.ssh/ct260_auto_ed25519

echo "== 0. 前置:ops 鑰可用+三節點可達 =="
ssh-keygen -y -P '' -f "$OPS" >/dev/null 2>&1 || { echo "ops 鑰已加密或不可讀——本腳本需在未上鎖狀態跑"; exit 1; }
for h in pve24 openwrt routerpve; do ssh -o BatchMode=yes -o ConnectTimeout=6 $h 'echo ok' >/dev/null || { echo "$h 不可達"; exit 1; }; done

echo "== 1. 生成自動軌金鑰(冪等) =="
[ -f "$AUTO" ] || ssh-keygen -t ed25519 -N '' -C 'ct260-automation(todo22)' -f "$AUTO" -q
PUB=$(cat "$AUTO.pub")
OPTS='from="192.168.20.60",no-agent-forwarding,no-port-forwarding,no-X11-forwarding'

echo "== 2. ssh config:-auto 別名 + IdentityAgent(冪等) =="
cp -a ~/.ssh/config "$BK/ssh-config"
grep -q "Host pve24-auto" ~/.ssh/config || cat >> ~/.ssh/config <<'CFG'

# BEGIN CT260-AUTO(待辦22 雙軌:自動化專鑰不加密;互動鑰 ct260_ops=hl-unlock 6h)
Host pve24-auto
    HostName 192.168.20.5
    User codex-admin
    Port 22
    IdentityFile ~/.ssh/ct260_auto_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host openwrt-auto
    HostName 192.168.10.1
    User root
    Port 52438
    IdentityFile ~/.ssh/ct260_auto_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host routerpve-auto
    HostName 192.168.10.2
    User root
    Port 22
    IdentityFile ~/.ssh/ct260_auto_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
# END CT260-AUTO
CFG
grep -q "IdentityAgent" ~/.ssh/config || sed -i '1i # 待辦22:互動鑰經 agent 快取(hl-unlock 6h);socket 不在=退回 IdentityFile\nHost *\n    IdentityAgent ~/.ssh/agent.sock\n' ~/.ssh/config

echo "== 3. 三節點裝自動鑰(from= 綁 CT260;冪等) =="
ssh pve24 "mkdir -p ~/.ssh && cp -a ~/.ssh/authorized_keys ~/.ssh/authorized_keys.before-todo22-$TS 2>/dev/null || true
grep -qF 'ct260-automation' ~/.ssh/authorized_keys 2>/dev/null || echo '$OPTS $PUB' >> ~/.ssh/authorized_keys"
# dropbear 不支援 from=(OpenSSH 專屬),用其支援的 no-* 選項;來源面由防火牆(52438 放行拓樸)把關
ssh openwrt "cp -a /etc/dropbear/authorized_keys /root/_backups/dropbear-authorized_keys.before-todo22-$TS 2>/dev/null || true
sed -i '/ct260-automation/d' /etc/dropbear/authorized_keys 2>/dev/null || true
echo 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding $PUB' >> /etc/dropbear/authorized_keys"
# routerpve:CT260→infra 路徑有 SNAT,對端看到的來源=192.168.10.1(SSH_CLIENT 實測)
ssh routerpve "cp -a /etc/pve/priv/authorized_keys /root/_backups/pve-authorized_keys.before-todo22-$TS 2>/dev/null || true
sed -i '/ct260-automation/d' /root/.ssh/authorized_keys 2>/dev/null || true
echo 'from=\"192.168.10.1\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding $PUB' >> /root/.ssh/authorized_keys"

echo "== 4. 驗證 -auto 三別名 =="
ssh -o BatchMode=yes -o ConnectTimeout=6 openwrt-auto 'echo ok' >/dev/null 2>&1 || {
  echo "openwrt-auto 帶選項仍被拒,降級純鑰行(記錄取捨)"
  ssh openwrt "sed -i '/ct260-automation/d' /etc/dropbear/authorized_keys; echo '$PUB' >> /etc/dropbear/authorized_keys"
}
for h in pve24-auto openwrt-auto routerpve-auto; do
  ssh -o BatchMode=yes -o ConnectTimeout=6 $h 'echo ok' >/dev/null && echo "$h OK" || { echo "$h 失敗"; exit 1; }
done

echo "== 5. 自動化消費者切自動軌(備份於 $BK) =="
for f in ~/.local/bin/watchdog-ct201.sh ~/.local/bin/homelab-notify.py ~/.local/bin/ntfy-webhook.py ~/.local/bin/hl-run ~/.local/bin/hl-push; do
  cp -a "$f" "$BK/$(basename $f)"
done
cp -a ~/workspace/ansible/inventory/hosts.yml "$BK/hosts.yml"
cp -a ~/workspace/ansible/inventory/group_vars "$BK/group_vars" -r
sed -i 's|WD_SSH_HOST:-pve24}|WD_SSH_HOST:-pve24-auto}|' ~/.local/bin/watchdog-ct201.sh
sed -i 's|"ssh", "pve24"|"ssh", "pve24-auto"|g' ~/.local/bin/homelab-notify.py ~/.local/bin/ntfy-webhook.py
sed -i 's|\$SSH pve24 "sudo|\$SSH pve24-auto "sudo|g' ~/.local/bin/hl-run
sed -i 's|"pve24:/tmp/hlpush|"pve24-auto:/tmp/hlpush|; s|\$SSH pve24 "sudo pct push|\$SSH pve24-auto "sudo pct push|' ~/.local/bin/hl-push
sed -i 's|ansible_private_key_file: ~/.ssh/ct260_ops_ed25519|ansible_private_key_file: ~/.ssh/ct260_auto_ed25519|' \
  ~/workspace/ansible/inventory/group_vars/*.yml 2>/dev/null || true
python3 - <<'PY'
import re
p = __import__('os').path.expanduser('~/workspace/ansible/inventory/hosts.yml')
s = open(p).read()
# infra 三主機改走 -auto 別名(夜備連續);wazuhct 換 auto 鑰;manual dxp4800 維持 ops(鎖定=非日常)
s = s.replace('        pve24:\n        routerpve:\n        openwrt:',
              '        pve24:\n          ansible_host: pve24-auto\n'
              '        routerpve:\n          ansible_host: routerpve-auto\n'
              '        openwrt:\n          ansible_host: openwrt-auto')
s = s.replace('          ansible_private_key_file: ~/.ssh/ct260_ops_ed25519\n          ansible_paramiko_host_key_auto_add: true',
              '          ansible_private_key_file: ~/.ssh/ct260_auto_ed25519\n          ansible_paramiko_host_key_auto_add: true')
open(p,'w').write(s)
print('hosts.yml switched')
PY

echo "== 6. 回歸:watchdog 一輪 + ansible ping + webhook 健康 =="
~/.local/bin/watchdog-ct201.sh >/dev/null && echo watchdog-OK
( cd ~/workspace/ansible && ~/.venvs/ansible/bin/ansible -i inventory/hosts.yml -m ping 'all:!manual' -o | grep -c SUCCESS ) || true
curl -sm4 -o /dev/null -w "webhook /health %{http_code}\n" http://127.0.0.1:5001/health || true
~/.local/bin/hl-run ct201 'echo hl-run-ct201-ok'

echo "== 7. 安裝 hl-unlock/hl-lock + agent 常駐 =="
install -m 755 ~/workspace/monitoring/hl-unlock ~/.local/bin/hl-unlock
install -m 755 ~/workspace/monitoring/hl-lock ~/.local/bin/hl-lock
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/hl-ssh-agent.service <<'UNIT'
[Unit]
Description=hl ssh-agent(待辦22:高權鑰 6h 快取)

[Service]
Type=simple
ExecStartPre=/bin/rm -f %h/.ssh/agent.sock
ExecStart=/usr/bin/ssh-agent -D -a %h/.ssh/agent.sock

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now hl-ssh-agent
grep -q 'agent.sock' ~/.bashrc || echo 'export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"  # 待辦22' >> ~/.bashrc

echo ""
echo "== 非互動段完成。最後一步(設密碼)請你親跑:"
echo "   root 可直接:su - codex -c 'bash ~/workspace/monitoring/finish-22b-passphrase.sh'"
echo "   (root su 到 codex 免密碼;中途要你自訂 ops 鑰密碼) =="
