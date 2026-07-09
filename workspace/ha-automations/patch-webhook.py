#!/usr/bin/env python3
"""patch-webhook: 對 ~/.local/bin/ntfy-webhook.py 打 HA 通知鏈補丁(冪等)。
①token 驗證迴圈加第三把 WEBHOOK_TOKEN_HA;②ACTIONS 加 notify-fire/notify-arrival/
ha-undo-arrival 三動作(quiet=成功不回發 TG);③tg_send 回報尊重 quiet+via 文案含 ha。
錨點未命中即 exit 1(上游檔漂移,人工核對),不寫半套。由 finish-ha-notify.sh 呼叫。"""
import py_compile
import sys
from pathlib import Path

TARGET = Path.home() / ".local/bin/ntfy-webhook.py"
src = TARGET.read_text()

if "WEBHOOK_TOKEN_HA" in src:
    print("already patched, skip")
    sys.exit(0)

ANCHOR_TOKENS = '''        for kind, tok in (("ntfy", CFG.get("WEBHOOK_TOKEN", "")),
                          ("portal", CFG.get("WEBHOOK_TOKEN_PORTAL", ""))):'''
NEW_TOKENS = '''        # 三 token(待辦49 M3 + HA 通知鏈 2026-07-09):ntfy 按鈕/portal BFF/HA rest_command
        # 各自獨立輪替;via 進 log+TG 文案供稽核
        for kind, tok in (("ntfy", CFG.get("WEBHOOK_TOKEN", "")),
                          ("portal", CFG.get("WEBHOOK_TOKEN_PORTAL", "")),
                          ("ha", CFG.get("WEBHOOK_TOKEN_HA", ""))):'''

ANCHOR_ACTIONS = '''    "restart-ctdmz-nft": {"desc": "重啟 CT203 ctdmz-nft（會清空 tailnet 通行證=需重驗）",
                          "cmd": ["ssh", "pve24-auto", "sudo", "pct", "exec", "203", "--",
                                  "systemctl", "restart", "ctdmz-nft"]},
}'''
NEW_ACTIONS = '''    "restart-ctdmz-nft": {"desc": "重啟 CT203 ctdmz-nft（會清空 tailnet 通行證=需重驗）",
                          "cmd": ["ssh", "pve24-auto", "sudo", "pct", "exec", "203", "--",
                                  "systemctl", "restart", "ctdmz-nft"]},
    # HA 家用通知鏈(2026-07-09):CT270 HA rest_command 打進來(WEBHOOK_TOKEN_HA);
    # 實作在 ha-notify.py(fire=TG+ntfy 雙推、arrival=ntfy+撤銷鈕、undo=HA API 關燈)。
    # quiet=成功不再回發 TG(fire 本身就發 TG、arrival 只需 ntfy;失敗仍回報)。
    "notify-fire":     {"desc": "火災警報通知（TG+ntfy）", "param": True, "quiet": True,
                        "cmd": (lambda p: [sys.executable,
                                           str(HOME / ".local/bin/ha-notify.py"), "fire", p])},
    "notify-arrival":  {"desc": "到家通知（ntfy+撤銷鈕）", "quiet": True,
                        "cmd": [sys.executable, str(HOME / ".local/bin/ha-notify.py"), "arrival"]},
    "ha-undo-arrival": {"desc": "撤銷到家（關主燈/除濕機/冷氣）",
                        "cmd": [sys.executable, str(HOME / ".local/bin/ha-notify.py"), "undo-arrival"]},
}'''

ANCHOR_TG = '''        emoji = "✅" if ok else "❌"
        tg_send(f"🔘 {'portal' if via == 'portal' else 'ntfy 按鈕'}：已執行 {label} — {spec['desc']}\\n"
                f"{emoji} 結果 rc={rc}（{dt:.1f}s）" + (f"\\n{out[-300:]}" if out else ""))'''
NEW_TG = '''        emoji = "✅" if ok else "❌"
        if not spec.get("quiet") or not ok:
            via_label = {"portal": "portal", "ha": "HA 自動化"}.get(via, "ntfy 按鈕")
            tg_send(f"🔘 {via_label}：已執行 {label} — {spec['desc']}\\n"
                    f"{emoji} 結果 rc={rc}（{dt:.1f}s）" + (f"\\n{out[-300:]}" if out else ""))'''

for name, anchor in (("token-loop", ANCHOR_TOKENS), ("actions-tail", ANCHOR_ACTIONS), ("tg-report", ANCHOR_TG)):
    if src.count(anchor) != 1:
        print(f"錨點未命中或不唯一:{name}(上游檔已漂移,人工核對後再跑)")
        sys.exit(1)

src = (src.replace(ANCHOR_TOKENS, NEW_TOKENS, 1)
          .replace(ANCHOR_ACTIONS, NEW_ACTIONS, 1)
          .replace(ANCHOR_TG, NEW_TG, 1))
TARGET.write_text(src)
py_compile.compile(str(TARGET), doraise=True)
print("patched + py_compile OK")
