#!/usr/bin/env bash
# finish-agents-hl.sh — 部署 agents.hl(Agent Control Center;HTTPS + Authelia SSO)
# ─────────────────────────────────────────────────────────────────────────────
# 內容:CT203 Caddy 新增 https://agents.hl.lailai74143.com
#   - LE wildcard(hl_tls)、forward_auth 走 Authelia(受保護服務 #7)
#   - reverse_proxy 192.168.20.60:8300(CT260 agenthub BFF;SPA 同源 + /api/events SSE)
#   - 既有各站(opencode.hl / portal.hl / opencode-app.hl…)一律不動
# 為何:手機開一個網址管理各 LXC AI agent;此站可觸發指令 → 必須 SSO,不開 Basic 旁門。
# 在哪跑:CT260(codex-ops),身分 codex。需 ssh pve24 + sudo -n pct。
#   金鑰上鎖先 hl-unlock。後端須先在 CT260 起(uvicorn :8300)。
# 做法:本地 SoT 整檔推送(操作規範 §3),含備份 + validate + 失敗自動回滾 + 自測。
# 回滾:見檔尾輸出(CT203 備份檔還原 + restart caddy)。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
HOST="$(hostname 2>/dev/null || true)"
[ "$HOST" = "codex-ops" ] || { echo "✗ 請在 CT260(codex-ops)執行(目前: ${HOST:-?})"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Caddyfile"
DOMAIN=agents.hl.lailai74143.com
SSO_DOMAIN=opencode.hl.lailai74143.com        # 回歸對照(既有 SSO 站不受影響)
BACKEND=192.168.20.60:8300                     # CT260 agenthub BFF
CT203_IP=10.60.60.10                           # Caddy 對外 IP(--resolve 用)
C_REMOTE=/etc/caddy/Caddyfile
BAK_NAME="Caddyfile.before-agents-$TS"
BKDIR="$HOME/_backups"
mkdir -p "$BKDIR"

echo "== 0. preflight =="
[ -f "$SRC" ] || { echo "✗ 找不到 $SRC"; exit 1; }
grep -q "https://${DOMAIN}" "$SRC" || { echo "✗ 源檔無 ${DOMAIN} 站,中止"; exit 1; }
grep -q "https://${SSO_DOMAIN}" "$SRC" || { echo "✗ 源檔缺既有 SSO 站,中止"; exit 1; }
# agents.hl 站「必須」帶 forward_auth(SSO),且後端指向 20.60:8300
python3 - "$SRC" "$DOMAIN" "$BACKEND" <<'PY'
import sys, re
src, domain, backend = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
m = re.search(rf"(?m)^https://{re.escape(domain)}\s*\{{", text)
if not m:
    raise SystemExit("✗ 找不到 domain 區塊")
i = m.start()
j = text.find("\nhttps://", i + 1)
block = text[i:j if j > 0 else None]
if "forward_auth" not in block:
    raise SystemExit("✗ agents.hl 站必須含 forward_auth(SSO),中止")
if backend not in block:
    raise SystemExit(f"✗ agents.hl 後端位址不符(應 {backend})")
print(f"  源檔區塊檢查 OK(含 Authelia forward_auth、後端 {backend})")
PY
# 後端必須在 CT260 先起來,否則推了路由也是 502
curl -sf -m5 -o /dev/null "http://127.0.0.1:8300/api/agents" \
  || { echo "✗ 後端 127.0.0.1:8300 未回應(先在 CT260 起 uvicorn :8300)"; exit 1; }
echo "  後端 :8300 探活 OK"
ssh -o BatchMode=yes -o ConnectTimeout=8 pve24 true \
  || { echo "✗ pve24 ssh 不可達(先 hl-unlock?)"; exit 1; }

echo "== 1. 拉 live 備份到 CT260 + CT203 =="
ssh pve24 "sudo -n pct exec 203 -- cat $C_REMOTE" > "$BKDIR/$BAK_NAME"
cp -a "$BKDIR/$BAK_NAME" "$BKDIR/$BAK_NAME.local"
ssh pve24 "sudo -n pct exec 203 -- cp -a $C_REMOTE $C_REMOTE.before-agents-$TS"
echo "  CT260:$BKDIR/$BAK_NAME"
echo "  CT203:$C_REMOTE.before-agents-$TS"

echo "== 2. 整檔推送 Caddyfile → validate → restart =="
scp -q "$SRC" pve24:/tmp/Caddyfile.agents
ssh pve24 "sudo -n pct push 203 /tmp/Caddyfile.agents $C_REMOTE --perms 644 && rm -f /tmp/Caddyfile.agents"
if ssh pve24 "sudo -n pct exec 203 -- caddy validate --config $C_REMOTE" >/tmp/agents-v.log 2>&1; then
  echo "  validate OK → restart caddy"
  ssh pve24 "sudo -n pct exec 203 -- systemctl restart caddy"
  sleep 2
  st=$(ssh pve24 "sudo -n pct exec 203 -- systemctl is-active caddy" || true)
  if [ "$st" != "active" ]; then
    echo "✗ caddy 非 active($st),自動回滾"
    ssh pve24 "sudo -n pct exec 203 -- cp -a $C_REMOTE.before-agents-$TS $C_REMOTE && sudo -n pct exec 203 -- systemctl restart caddy"
    exit 1
  fi
else
  echo "✗ validate 失敗,自動回滾:"
  cat /tmp/agents-v.log
  ssh pve24 "sudo -n pct exec 203 -- cp -a $C_REMOTE.before-agents-$TS $C_REMOTE"
  exit 1
fi

echo "== 3. 自測(CT203 內;經 Caddy + 直打後端)=="
DOMAIN="$DOMAIN" SSO_DOMAIN="$SSO_DOMAIN" BACKEND="$BACKEND" CT203_IP="$CT203_IP" \
python3 - <<'PY'
import os, subprocess
dom, sso, backend, ip = (os.environ[k] for k in ("DOMAIN", "SSO_DOMAIN", "BACKEND", "CT203_IP"))
script = f"""
set -e
echo -n "  {dom} 未登入(經 Caddy)   → "
curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {dom}:443:{ip} https://{dom}/
echo " (應 302/401 = SSO 生效)"
echo -n "  後端 {backend}/api/agents 直打 → "
curl -s -o /dev/null -w "%{{http_code}}" -m8 http://{backend}/api/agents
echo " (應 200 = 反代目標存活)"
echo -n "  {sso} 未登入(回歸既有站) → "
curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {sso}:443:{ip} https://{sso}/
echo " (應 302/401 = 未被波及)"
gate=$(curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {dom}:443:{ip} https://{dom}/)
back=$(curl -s  -o /dev/null -w "%{{http_code}}" -m8 http://{backend}/api/agents)
sso_c=$(curl -sk -o /dev/null -w "%{{http_code}}" -m8 --resolve {sso}:443:{ip} https://{sso}/)
[ "$gate" = "302" ] || [ "$gate" = "401" ] || {{ echo "✗ agents.hl 未擋未登入(得 $gate)"; exit 1; }}
[ "$back" = "200" ] || {{ echo "✗ 後端探活失敗(得 $back)"; exit 1; }}
[ "$sso_c" = "302" ] || [ "$sso_c" = "401" ] || {{ echo "✗ 既有 SSO 站回歸異常(得 $sso_c)"; exit 1; }}
echo "  自測通過(SSO 生效 + 後端存活 + 既有站無恙)"
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
PY

echo
echo "✅ 完成。手機(Tailscale 連線中)瀏覽器開:"
echo "   https://${DOMAIN}   (先過 Authelia 登入)"
echo "   前置:當日若首次打內網,仍先過 gate.hl 取通行證。"
echo "   後端提醒:CT260 的 uvicorn :8300 需常駐(nohup 或 systemd),SSH 斷了別讓它停。"
echo
echo "回滾:"
echo "  ssh pve24 'sudo -n pct exec 203 -- cp -a $C_REMOTE.before-agents-$TS $C_REMOTE && sudo -n pct exec 203 -- systemctl restart caddy'"
echo "  # 或從 CT260 備份:"
echo "  scp $BKDIR/$BAK_NAME pve24:/tmp/Caddyfile.rollback && \\"
echo "  ssh pve24 'sudo -n pct push 203 /tmp/Caddyfile.rollback $C_REMOTE --perms 644 && sudo -n pct exec 203 -- systemctl restart caddy'"
