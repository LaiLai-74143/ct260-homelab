#!/bin/bash
# 待辦14b 收尾:pve24 host 本體裝 wazuh-agent。
# 為何留人工:CT260 codex-admin 在 pve24 的 sudo 僅 pct/qm/pvesh/pvesm,無法 apt(拓樸 §1.2);
#             agent/deb 已由 CT260 scp 至 /home/codex-admin/(sha512 於本腳本驗證)。
# 用法:root@pve24# bash /home/codex-admin/finish-14.sh
# 回滾:apt-get remove --purge wazuh-agent && rm -rf /var/ossec;manager 端 dashboard 刪 agent。
set -euo pipefail
DEB=/home/codex-admin/wazuh-agent_4.14.6-1_amd64.deb
SHA=52d64ae04699fa79f075354ec91eb279173af3a3c1ff4588cece315c941e25fee17cb3519f5fbff9b259e185d1c44fdf088f557eda7be30474f632cb61d483c5

[ "$(id -u)" = 0 ] || { echo "請以 root 執行"; exit 1; }
if [ -x /var/ossec/bin/wazuh-control ]; then echo "wazuh-agent 已安裝,跳過"; exit 0; fi

echo "$SHA  $DEB" | sha512sum -c -
WAZUH_MANAGER=10.80.80.12 apt-get install -y "$DEB"
systemctl enable --now wazuh-agent
sleep 8
/var/ossec/bin/wazuh-control status | grep wazuh-agentd

echo "OK。manager 端確認(應多出 24bay-pve,Active):"
echo "  pct exec 204 -- docker exec single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l"
echo "裝完可刪:rm /home/codex-admin/wazuh-agent_4.14.6-1_amd64.deb /home/codex-admin/finish-14.sh"
