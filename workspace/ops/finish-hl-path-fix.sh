#!/bin/bash
# finish-hl-path-fix.sh — 封掉 hl-unlock「command not found / su 要密碼」的最後兩個門
# 背景(2026-07-09 晚):使用者 pct enter 260(root,最小 PATH 無 /usr/local/bin)→ su codex
#   (非登入,無 ~/.local/bin)→ hl-unlock 找不到;codex 的 bashrc 已由 agent 修好(門3),
#   本腳本補 root 側兩門(agent 執行被 auto-mode 分類器攔=容器內寫入,照慣例收斂成腳本)。
# 在哪跑:CT260,root 身份(pct enter 260 即可):
#   bash /home/codex/workspace/ops/finish-hl-path-fix.sh
# 冪等:重跑無害。
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "✗ 請以 root 跑(pct enter 260)"; exit 1; }

# ── 門1:root .bashrc 補 /usr/local/bin(pct enter 的最小 PATH 缺它)──
if grep -q hl-path-fix /root/.bashrc 2>/dev/null; then
    echo "✓ 門1 已修過,跳過"
else
    cat >> /root/.bashrc <<'EOF'

# hl-path-fix(2026-07-09):pct enter 進來的 root shell PATH 是最小集,缺 /usr/local/bin
# → hl-unlock/hl-lock 找不到。補回。
case ":$PATH:" in *":/usr/local/bin:"*) ;; *) PATH="/usr/local/sbin:/usr/local/bin:$PATH";; esac
EOF
    echo "✓ 門1:/root/.bashrc 已補 PATH"
fi

# ── 門2:wrapper 已是 codex 時直跑本尊(原版無條件 su - codex → 要 codex 帳號密碼=必失敗)──
cat > /usr/local/bin/hl-unlock <<'EOF'
#!/bin/bash
# root 便利包裝(2026-07-09):root shell 直打 hl-unlock / hl-lock,轉身為 codex 跑本尊。
# 金鑰與 agent 都在 codex 名下;passphrase 互動經 tty 直通。
# 2026-07-09b:已是 codex 時直跑本尊(su 會要 codex 帳號密碼=必失敗)。
n=$(basename "$0")
if [ "$(id -un)" = "codex" ]; then exec "/home/codex/.local/bin/$n"; fi
exec su - codex -c "XDG_RUNTIME_DIR=/run/user/\$(id -u) /home/codex/.local/bin/$n"
EOF
chmod 755 /usr/local/bin/hl-unlock
echo "✓ 門2:wrapper 已更新(hl-lock 是 symlink,一併生效)"

# ── 驗證 ──
bash -ic 'command -v hl-unlock' >/dev/null && echo "✓ root 互動 shell 找得到 hl-unlock"
su codex -c 'bash -ic "type hl-unlock"' | grep -q '.local/bin/hl-unlock' \
    && echo "✓ su codex 後解析到本尊(非 wrapper)"
echo "完成。三個門(root PATH / wrapper su / codex PATH)全封。"
