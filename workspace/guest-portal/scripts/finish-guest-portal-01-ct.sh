#!/bin/bash
# finish-guest-portal-01-ct.sh — 建立 CT205 schedule(DMZ VLAN60),基礎環境 + systemd 骨架。
#
# 在哪跑:pve24(24Bay PVE)root 身份。SSH 到 pve24 後:
#   sudo bash /root/finish-guest-portal-01-ct.sh
#   (本檔由 CT260 交付到 pve24:/root/;見 handoff 說明)
#
# 做什麼:CTID 205 / hostname schedule / VLAN60 10.60.60.11 / 512M・1core・rootfs 4G,
#   unprivileged;net0 的 bridge+tag 從 CT203 複製(不硬編);裝 python3、建目錄與 gp 服務帳號、
#   落 SESSION_SECRET、寫 systemd unit(硬化)。應用碼由 02-deploy 推入後才真正起服務。
#
# 為何不進 DMZ 防火牆規則:CT203(.10)與 CT205(.11)同 pve24 同 VLAN60 bridge=同 L2 直通,
#   Caddy→app 走 bridge 不經路由器,零新規則。對外經 CT203 Caddy :80 host 分流(段D)。
#
# 冪等:CT 已存在則跳過建立、只補環境;重跑無害。
# 回滾:pct stop 205 && pct destroy 205(全新 CT,無牽連)。
set -euo pipefail

CTID=205
HOSTNAME_=schedule
IP=10.60.60.11
CIDR=24
GW=10.60.60.1
SIBLING=203          # 複製其 net0 bridge+tag 與 rootfs 儲存池
ENVF=/opt/guest-portal/.env

[ "$(id -u)" = "0" ] || { echo "✗ 請以 root 跑(pve24)"; exit 1; }
command -v pct >/dev/null || { echo "✗ 找不到 pct,這台不是 PVE?"; exit 1; }

echo "== 0. 前置檢查 =="
if pct status "$CTID" >/dev/null 2>&1; then
    echo "✓ CT$CTID 已存在,跳過建立,只補環境"
    CREATED=0
else
    CREATED=1
    # IP 衝突預檢(.11 不該有人回應)
    if ping -c1 -W1 "$IP" >/dev/null 2>&1; then
        echo "✗ $IP 已有裝置回應,恐 IP 衝突,中止"; exit 1
    fi
    # 從 CT203 學 net0 的 bridge 與 tag(避免硬編錯 bridge 名)
    NET0=$(pct config "$SIBLING" | sed -n 's/^net0: //p')
    BRIDGE=$(echo "$NET0" | tr ',' '\n' | sed -n 's/^bridge=//p')
    TAG=$(echo "$NET0"    | tr ',' '\n' | sed -n 's/^tag=//p')
    [ -n "$BRIDGE" ] || { echo "✗ 無法從 CT$SIBLING 解析 bridge,中止"; exit 1; }
    echo "   借用 CT$SIBLING 網路:bridge=$BRIDGE tag=${TAG:-（無 tag）}"
    # rootfs 儲存池同樣沿用 CT203
    STORAGE=$(pct config "$SIBLING" | sed -n 's/^rootfs: \([^:]*\):.*/\1/p')
    [ -n "$STORAGE" ] || { echo "✗ 無法解析 CT$SIBLING 儲存池,中止"; exit 1; }
    echo "   rootfs 儲存池=$STORAGE"
    # Debian 12/13 模板(app 純 stdlib python3,兩者皆可;用 pvesm 依 content 偵測,回 volid)
    TEMPLATE=$(pvesm list local --content vztmpl 2>/dev/null | awk '/debian-1[23].*amd64/{print $1; exit}')
    [ -n "$TEMPLATE" ] || { echo "✗ local 無 debian-12/13 模板,先 pveam update && pveam download local debian-13-standard,中止"; exit 1; }
    echo "   模板=$TEMPLATE"

    echo "== 1. pct create CT$CTID =="
    NETOPT="name=eth0,bridge=$BRIDGE,ip=$IP/$CIDR,gw=$GW"
    [ -n "$TAG" ] && NETOPT="$NETOPT,tag=$TAG"
    pct create "$CTID" "$TEMPLATE" \
        --hostname "$HOSTNAME_" \
        --cores 1 --memory 512 --swap 256 \
        --rootfs "$STORAGE:4" \
        --net0 "$NETOPT" \
        --nameserver "$GW" \
        --unprivileged 1 --onboot 1 --features nesting=0 \
        --description "guest-portal 對外唯讀分享站(行程+借貸);schedule.lailai74143.com;VLAN60 DMZ"
    pct start "$CTID"
    echo "   等網路就緒…"
    for i in $(seq 1 15); do
        pct exec "$CTID" -- ping -c1 -W1 "$GW" >/dev/null 2>&1 && break
        sleep 1
    done
fi

echo "== 2. CT 內:python3 + 目錄 + 服務帳號 =="
pct exec "$CTID" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3; }
id gp >/dev/null 2>&1 || useradd --system --home /opt/guest-portal --shell /usr/sbin/nologin gp
mkdir -p /opt/guest-portal/bff /opt/guest-portal/data
chown -R gp:gp /opt/guest-portal
echo "python3=$(python3 --version 2>&1)"
'

echo "== 3. SESSION_SECRET + .env(冪等:已存在則不覆寫金鑰)=="
pct exec "$CTID" -- bash -c "
set -e
if [ -f $ENVF ] && grep -q '^SESSION_SECRET=' $ENVF; then
    echo '✓ .env 已有 SESSION_SECRET,保留'
else
    SECRET=\$(python3 -c 'import secrets;print(secrets.token_hex(32))')
    cat > $ENVF <<EOF
GUEST_MODE=live
GUEST_STATIC=/opt/guest-portal/bff/dist
GUEST_DATA=/opt/guest-portal/data/guest.json
GUEST_AUDIT_LOG=/opt/guest-portal/data/audit.jsonl
SESSION_SECRET=\$SECRET
GUEST_COOKIE_SECURE=1
GUEST_BIND=0.0.0.0
GUEST_PORT=8300
GUEST_LOG_WRONG_PW=mask
EOF
    chown gp:gp $ENVF && chmod 600 $ENVF
    echo '✓ .env 已生成(SESSION_SECRET 落地,600)'
fi
"

echo "== 4. systemd unit(硬化)=="
pct exec "$CTID" -- bash -c 'cat > /etc/systemd/system/guest-portal.service <<EOF
[Unit]
Description=guest-portal (schedule.lailai74143.com) — 對外唯讀分享站
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=gp
WorkingDirectory=/opt/guest-portal/bff
EnvironmentFile=/opt/guest-portal/.env
ExecStart=/usr/bin/python3 -m app.server
Restart=on-failure
RestartSec=3
# ── 硬化:公網面服務,最小權限 ──
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
ReadWritePaths=/opt/guest-portal/data
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable guest-portal.service >/dev/null 2>&1
echo "✓ unit 已裝並 enable(尚未 start;待 02-deploy 推入應用碼)"'

echo
echo "✅ CT$CTID 骨架完成(建立=$CREATED)。下一步:在 CT260 跑 finish-guest-portal-02-deploy.sh 推入應用碼並啟動。"
