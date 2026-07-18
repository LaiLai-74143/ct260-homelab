#!/bin/bash
# deploy-caddyfile.sh(2026-07-18,占位 token 事故後立法)——CT203 Caddyfile 唯一正規部署路徑。
# 在哪跑:CT260(codex),直接:  sh ~/workspace/ct-dmz-proxy/deploy-caddyfile.sh
# 做什麼:repo 去密模板 → 替入真 token(不落 argv/不進 git)→ scp+pct push CT203 →
#         caddy validate → systemctl restart caddy(admin off 不能 reload,斷 ~1s)→
#         打「帶 token 的 API 層」驗證(agents.hl 302 不算數——token 壞了它照樣 302)。
# 注意:auto-mode 下 agent 跑到 push/restart 會被分類器攔——由使用者執行,或 agent 備好後交接。
# 回滾:CT203 /root/_backups/Caddyfile.before-deploy-<ts> 還原 + systemctl restart caddy。
set -uo pipefail
SRC="$HOME/workspace/ct-dmz-proxy/Caddyfile"
ENVF="$HOME/.config/homelab/agenthub-api.env"
TMP=$(mktemp /tmp/Caddyfile.deploy.XXXXXX); chmod 600 "$TMP"
trap 'rm -f "$TMP"; ssh pve24-auto "rm -f /tmp/Caddyfile.deploy" 2>/dev/null' EXIT

python3 - "$SRC" "$ENVF" "$TMP" <<'EOF'
import sys, pathlib
src, envf, tmp = sys.argv[1:4]
tok = None
for line in pathlib.Path(envf).read_text().splitlines():
    if line.startswith('AGENTHUB_API_TOKEN='):
        tok = line.split('=', 1)[1].strip().strip('"').strip("'")
assert tok, f'AGENTHUB_API_TOKEN 不在 {envf}'
txt = pathlib.Path(src).read_text()
assert '{真值見上}' in txt, '模板裡找不到占位字樣(格式變了?先人工核對)'
pathlib.Path(tmp).write_text(txt.replace('{真值見上}', tok))
print('token 已替入(不顯示)')
EOF
[ $? -eq 0 ] || exit 1

scp -q "$TMP" pve24-auto:/tmp/Caddyfile.deploy || { echo "!! scp 失敗"; exit 1; }
ssh pve24-auto 'chmod 600 /tmp/Caddyfile.deploy
TS=$(date +%Y%m%d_%H%M%S)
sudo /usr/sbin/pct exec 203 -- cp /etc/caddy/Caddyfile /root/_backups/Caddyfile.before-deploy-$TS
sudo /usr/sbin/pct push 203 /tmp/Caddyfile.deploy /etc/caddy/Caddyfile >/dev/null
if sudo /usr/sbin/pct exec 203 -- caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    echo VALIDATE_OK
    sudo /usr/sbin/pct exec 203 -- systemctl restart caddy
    sleep 2; sudo /usr/sbin/pct exec 203 -- systemctl is-active caddy
else
    echo "VALIDATE_FAIL — 未重啟,現網跑的仍是舊檔;還原備份後排查"
    exit 1
fi
rm -f /tmp/Caddyfile.deploy' || exit 1

echo "== API 層驗證(token 那一跳;302 不算)=="
sleep 12
recent=$(journalctl -u agenthub --since "-40 seconds" --no-pager 2>/dev/null | grep "10.60.60.10" | tail -4)
if echo "$recent" | grep -q '" 200'; then echo "✅ 帶 token 請求回 200,部署完成"
elif echo "$recent" | grep -q '" 401'; then echo "❌ 401=token 又不對了!回滾並排查"; echo "$recent"; exit 1
else echo "ℹ️ 40 秒內無 App 流量;開 App 任一頁後跑:journalctl -u agenthub --since '-1 min' | grep 10.60.60.10 | tail"
fi
