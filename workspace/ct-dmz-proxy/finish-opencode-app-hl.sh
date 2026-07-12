#!/usr/bin/env bash
# finish-opencode-app-hl.sh — 部署 opencode-app.hl(官方 App 用 HTTPS + Basic 透傳)
# ─────────────────────────────────────────────────────────────────────────────
# 內容:CT203 Caddy 新增 https://opencode-app.hl.lailai74143.com
#   - LE wildcard(hl_tls)、無 forward_auth
#   - reverse_proxy 192.168.20.60:4096,客戶端 Authorization Basic 原樣轉後端
#   - 既有 opencode.hl(SSO)不動
# 為何:原生 App 擋 cleartext HTTP,又不會走 Authelia cookie → 需 HTTPS 入口。
# 在哪跑:CT260(codex-ops),身分 codex。需 ssh pve24 + sudo -n pct。
#   金鑰上鎖先 hl-unlock。
# 做法:本地 SoT 整檔推送(操作規範 §3),含備份 + validate + 失敗自動回滾 + 自測。
# 回滾:見檔尾輸出(CT203 備份檔還原 + restart caddy)。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
HOST="$(hostname 2>/dev/null || true)"
[ "$HOST" = "codex-ops" ] || { echo "✗ 請在 CT260(codex-ops)執行(目前: ${HOST:-?})"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Caddyfile"
DOMAIN=opencode-app.hl.lailai74143.com
SSO_DOMAIN=opencode.hl.lailai74143.com
C_REMOTE=/etc/caddy/Caddyfile
BAK_NAME="Caddyfile.before-opencode-app-$TS"
ENVF="$HOME/.config/homelab/opencode.env"
BKDIR="$HOME/_backups"
mkdir -p "$BKDIR"

echo "== 0. preflight =="
[ -f "$SRC" ] || { echo "✗ 找不到 $SRC"; exit 1; }
grep -q "https://${DOMAIN}" "$SRC" || { echo "✗ 源檔無 ${DOMAIN} 站,中止"; exit 1; }
grep -q "https://${SSO_DOMAIN}" "$SRC" || { echo "✗ 源檔缺既有 SSO 站,中止"; exit 1; }
# App 站不得帶 forward_auth(否則又卡 SSO)
python3 - "$SRC" "$DOMAIN" <<'PY'
import sys, re
src, domain = sys.argv[1], sys.argv[2]
text = open(src).read()
# 站台區塊以「行首 https://host {」為準(略過註解行)
m = re.search(rf"(?m)^https://{re.escape(domain)}\s*\{{", text)
if not m:
    raise SystemExit("domain block missing")
i = m.start()
j = text.find("\nhttps://", i + 1)
block = text[i:j if j > 0 else None]
if "forward_auth" in block:
    raise SystemExit("✗ opencode-app 站不可含 forward_auth")
if "192.168.20.60:4096" not in block:
    raise SystemExit("✗ opencode-app 後端位址不符")
print("  源檔區塊檢查 OK(無 Authelia、後端 20.60:4096)")
PY
ssh -o BatchMode=yes -o ConnectTimeout=8 pve24 true \
  || { echo "✗ pve24 ssh 不可達(先 hl-unlock?)"; exit 1; }
[ -f "$ENVF" ] || { echo "✗ 缺 $ENVF(測 Basic 需要)"; exit 1; }

echo "== 1. 拉 live 備份到 CT260 + CT203 =="
ssh pve24 "sudo -n pct exec 203 -- cat $C_REMOTE" > "$BKDIR/$BAK_NAME"
cp -a "$BKDIR/$BAK_NAME" "$BKDIR/$BAK_NAME.local"
ssh pve24 "sudo -n pct exec 203 -- cp -a $C_REMOTE $C_REMOTE.before-opencode-app-$TS"
echo "  CT260:$BKDIR/$BAK_NAME"
echo "  CT203:$C_REMOTE.before-opencode-app-$TS"

echo "== 2. 整檔推送 Caddyfile → validate → restart =="
scp -q "$SRC" pve24:/tmp/Caddyfile.opencode-app
ssh pve24 "sudo -n pct push 203 /tmp/Caddyfile.opencode-app $C_REMOTE --perms 644 && rm -f /tmp/Caddyfile.opencode-app"
if ssh pve24 "sudo -n pct exec 203 -- caddy validate --config $C_REMOTE" >/tmp/opencode-app-v.log 2>&1; then
  echo "  validate OK → restart caddy"
  ssh pve24 "sudo -n pct exec 203 -- systemctl restart caddy"
  sleep 2
  st=$(ssh pve24 "sudo -n pct exec 203 -- systemctl is-active caddy" || true)
  if [ "$st" != "active" ]; then
    echo "✗ caddy 非 active($st),自動回滾"
    ssh pve24 "sudo -n pct exec 203 -- cp -a $C_REMOTE.before-opencode-app-$TS $C_REMOTE && sudo -n pct exec 203 -- systemctl restart caddy"
    exit 1
  fi
else
  echo "✗ validate 失敗,自動回滾:"
  cat /tmp/opencode-app-v.log
  ssh pve24 "sudo -n pct exec 203 -- cp -a $C_REMOTE.before-opencode-app-$TS $C_REMOTE"
  exit 1
fi

echo "== 3. 自測(CT203; Basic 用 header 檔 + bash -s,避免 %{http_code}/引號被多層 shell 吃掉) =="
APP_DOMAIN="$DOMAIN" SSO_DOMAIN="$SSO_DOMAIN" python3 - <<'PY'
import os, subprocess, base64
from pathlib import Path
env = {}
for line in Path.home().joinpath(".config/homelab/opencode.env").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
user = env.get("OPENCODE_SERVER_USERNAME") or "opencode"
pw = env.get("OPENCODE_SERVER_PASSWORD") or ""
assert pw, "empty password"
tok = base64.b64encode(f"{user}:{pw}".encode()).decode()
app = os.environ["APP_DOMAIN"]
sso = os.environ["SSO_DOMAIN"]
Path("/tmp/oc-auth.hdr").write_text(f"Authorization: Basic {tok}\n")
subprocess.run(["scp", "-q", "/tmp/oc-auth.hdr", "pve24:/tmp/oc-auth.hdr"], check=True, timeout=20)
subprocess.run(
    ["ssh", "-o", "BatchMode=yes", "pve24",
     "sudo -n pct push 203 /tmp/oc-auth.hdr /tmp/oc-auth.hdr --perms 600 && rm -f /tmp/oc-auth.hdr"],
    check=True, timeout=30,
)
script = f"""
set -e
echo -n "  {app}/global/health + Basic → "
curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {app}:443:10.60.60.10 -H @/tmp/oc-auth.hdr https://{app}/global/health
echo " (應 200)"
echo -n "  {app}/global/health 無認證   → "
curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {app}:443:10.60.60.10 https://{app}/global/health
echo " (應 401)"
echo -n "  {sso}/ 無認證(回歸 SSO)      → "
curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {sso}:443:10.60.60.10 https://{sso}/
echo " (應 302/401)"
code=$(curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {app}:443:10.60.60.10 -H @/tmp/oc-auth.hdr https://{app}/global/health)
code_no=$(curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {app}:443:10.60.60.10 https://{app}/global/health)
rm -f /tmp/oc-auth.hdr
[ "$code" = "200" ] || {{ echo "✗ App 站 Basic 探活失敗 code=$code"; exit 1; }}
[ "$code_no" = "401" ] || [ "$code_no" = "403" ] || {{ echo "✗ 無認證應 401,得 $code_no"; exit 1; }}
echo "  探活通過"
"""
r = subprocess.run(
    ["ssh", "-o", "BatchMode=yes", "pve24",
     "sudo", "-n", "pct", "exec", "203", "--", "bash", "-s"],
    input=script, text=True, capture_output=True, timeout=60,
)
print(r.stdout, end="")
if r.returncode != 0:
    print(r.stderr, end="")
    raise SystemExit(r.returncode)
Path("/tmp/oc-auth.hdr").unlink(missing_ok=True)
PY

echo
echo "✅ 完成。官方 App 請填:"
echo "   Server URL: https://${DOMAIN}"
echo "   Username:   opencode"
echo "   Password:   (CT260 ~/.config/homelab/opencode.env 的 OPENCODE_SERVER_PASSWORD)"
echo "   前置:手機 Tailscale 連線中;當日若要打內網其他服務仍先過 gate.hl。"
echo
echo "回滾:"
echo "  ssh pve24 'sudo -n pct exec 203 -- cp -a $C_REMOTE.before-opencode-app-$TS $C_REMOTE && sudo -n pct exec 203 -- systemctl restart caddy'"
echo "  # 或從 CT260 備份:"
echo "  scp $BKDIR/$BAK_NAME pve24:/tmp/Caddyfile.rollback && \\"
echo "  ssh pve24 'sudo -n pct push 203 /tmp/Caddyfile.rollback $C_REMOTE --perms 644 && sudo -n pct exec 203 -- systemctl restart caddy'"
