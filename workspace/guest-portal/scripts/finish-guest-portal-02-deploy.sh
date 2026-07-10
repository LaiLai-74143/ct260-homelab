#!/bin/bash
# finish-guest-portal-02-deploy.sh — build 前端 + 打包 app → 推入 CT205 → 啟動/重啟服務。
#
# 在哪跑:CT260(codex-ops)一般使用者身份(需 hl-unlock 解鎖 ssh agent):
#   hl-unlock && bash ~/workspace/guest-portal/scripts/finish-guest-portal-02-deploy.sh
#
# 前置:finish-guest-portal-01-ct.sh 已在 pve24 跑過(CT205 存在、.env/unit 就緒)。
# 冪等:重跑=滾動更新;失敗保留舊版(.old 自癒挪回)。
# 回滾:pct exec 205 -- systemctl stop guest-portal;或推回上一版 bundle。
set -euo pipefail
cd "$HOME"   # pct enter→su codex 會把 cwd 留在 /root(codex 無權限),find 等工具還原 cwd 會炸

CTID=205
ROOT=~/workspace/guest-portal
TS=$(date +%Y%m%d_%H%M%S)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 0. 前端 build(CT260 本機;CT205 不裝 node)=="
# node_modules 不入庫;deps 與 portal 完全一致 → 缺則 symlink 借用(免重複 npm install)
if [ ! -e "$ROOT/frontend/node_modules" ]; then
    if [ -d ~/workspace/portal/frontend/node_modules ]; then
        ln -s ~/workspace/portal/frontend/node_modules "$ROOT/frontend/node_modules"
        echo "   node_modules 缺 → 已 symlink 借用 portal 的(deps 相同)"
    else
        ( cd "$ROOT/frontend" && npm install ) >/dev/null
    fi
fi
( cd "$ROOT/frontend" && npm run build ) >/dev/null
[ -f "$ROOT/frontend/dist/index.html" ] || { echo "✗ dist 缺 index.html,中止"; exit 1; }

echo "== 1. 打包 app(*.py)+ dist =="
# bundle 結構:解到 /opt/guest-portal/bff → bff/app/*.py + bff/dist/*
mkdir -p "$TMP/bff"
cp -r "$ROOT/bff/app" "$TMP/bff/app"
find "$TMP/bff/app" -name '__pycache__' -type d -prune -exec rm -rf {} +
# 不把 mock fixture 帶上線(live 讀 /opt/guest-portal/data/guest.json;fixtures 僅 mock 用)
rm -f "$TMP/bff/app/fixtures/guest.json"
cp -r "$ROOT/frontend/dist" "$TMP/bff/dist"
tar -C "$TMP" -czf "$TMP/gp-bundle.tgz" bff
SHA=$(sha256sum "$TMP/gp-bundle.tgz" | cut -d' ' -f1)
echo "   bundle sha256=$SHA"

echo "== 2. 傳輸 pve24 → pct push CT$CTID =="
scp -q "$TMP/gp-bundle.tgz" pve24:/tmp/gp-bundle.tgz
ssh pve24 "sudo pct push $CTID /tmp/gp-bundle.tgz /tmp/gp-bundle.tgz && rm -f /tmp/gp-bundle.tgz"

echo "== 3. CT$CTID:sha 驗證 + 原子換版 + 重啟 + 存活檢查 =="
ssh pve24 "sudo pct exec $CTID -- bash -c '
set -e
sha=\$(sha256sum /tmp/gp-bundle.tgz | cut -d\" \" -f1)
[ \"\$sha\" = \"$SHA\" ] || { echo \"✗ sha 不符(傳輸損毀)\"; exit 1; }
mkdir -p /root/_backups
# 自癒:上次死在換版中途 → 把 .old 挪回
[ -d /opt/guest-portal/bff ] || mv /opt/guest-portal/bff.old /opt/guest-portal/bff
# 首次部署才備份(此時 bff 可能只有空骨架;有內容才備份)
if [ -d /opt/guest-portal/bff/app ]; then
    tar -C /opt/guest-portal -czf /root/_backups/gp-bff-before-$TS.tgz bff 2>/dev/null || true
fi
rm -rf /opt/guest-portal/bff.new /opt/guest-portal/bff.old
mkdir -p /opt/guest-portal/bff.new
tar -C /opt/guest-portal/bff.new -xzf /tmp/gp-bundle.tgz --strip-components=1
[ -f /opt/guest-portal/bff.new/app/server.py ] || { echo \"✗ bundle 內容異常(無 server.py)\"; exit 1; }
[ -f /opt/guest-portal/bff.new/dist/index.html ] || { echo \"✗ bundle 缺 dist/index.html\"; exit 1; }
[ -d /opt/guest-portal/bff ] && mv /opt/guest-portal/bff /opt/guest-portal/bff.old
mv /opt/guest-portal/bff.new /opt/guest-portal/bff
chown -R gp:gp /opt/guest-portal/bff
rm -f /tmp/gp-bundle.tgz
systemctl restart guest-portal.service
sleep 2
if systemctl is-active --quiet guest-portal.service; then
    echo \"✓ 服務 active\"
    rm -rf /opt/guest-portal/bff.old
else
    echo \"✗ 服務未起,回退舊版\"
    rm -rf /opt/guest-portal/bff
    mv /opt/guest-portal/bff.old /opt/guest-portal/bff
    systemctl restart guest-portal.service || true
    journalctl -u guest-portal.service -n 20 --no-pager || true
    exit 1
fi
'"

echo "== 4. 健康檢查(CT 內本機打 :8300)=="
ssh pve24 "sudo pct exec $CTID -- bash -c '
h=\$(python3 -c \"import urllib.request,json;print(urllib.request.urlopen(\\\"http://127.0.0.1:8300/api/health\\\",timeout=5).read().decode())\" 2>&1)
echo \"   /api/health → \$h\"
echo \"\$h\" | grep -q \\\"ok\\\":\ true || echo \"（注意:資料檔尚未由 hl-write-guest 推上來屬正常,accounts=0）\"
'"

echo
echo "✅ 部署完成。app 在 CT$CTID:8300 監聽。"
echo "   下一步:段C 建帳號與資料管線(hl-guest / hl-write-guest),段D 接 CT203 Caddy + CF hostname。"
