#!/bin/bash
# finish-ha-door-toggle.sh — 換裝「關門切換主燈」自動化(2026-07-09 使用者裁決)
# 移除 door_motion_5s_lights_off(5秒互鎖,雲端輪詢下實測不觸發),
# 換上 door_closed_toggle_lights(門 on→off=關門 → 主燈整組切換,以 7cbf 現態為基準)。
# 在哪跑:CT260(codex@codex-ops),先 hl-unlock。冪等;automations.yaml 自備份。
set -euo pipefail
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

scp -q "$SELF_DIR/automation-door-toggle.yaml" pve24:/tmp/door-toggle.yaml
scp -q "$SELF_DIR/swap-door-automation.py" pve24:/tmp/swap-door.py
ssh pve24 "sudo pct push 270 /tmp/door-toggle.yaml /tmp/door-toggle.yaml && \
           sudo pct push 270 /tmp/swap-door.py /tmp/swap-door.py && \
           rm -f /tmp/door-toggle.yaml /tmp/swap-door.py && \
           sudo pct exec 270 -- python3 /tmp/swap-door.py && \
           sudo pct exec 270 -- rm -f /tmp/door-toggle.yaml /tmp/swap-door.py"

# reload+驗證(token 讀檔組請求)
python3 - <<'PYEOF'
import json, os, time, urllib.request
cfg = {}
for line in open(os.path.expanduser("~/.config/homelab/hass.env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); cfg[k] = v.strip()
def api(method, path, body=None):
    req = urllib.request.Request(cfg["HASS_URL"] + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + cfg["HASS_TOKEN"],
                                          "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=30)
api("POST", "/api/services/automation/reload", {})
time.sleep(3)
states = json.loads(api("GET", "/api/states").read())
ids = [s["attributes"].get("id") for s in states if s["entity_id"].startswith("automation.")]
assert "door_closed_toggle_lights" in ids, f"toggle 自動化未載入: {ids}"
assert "door_motion_5s_lights_off" not in ids, "互鎖舊條仍在?"
print("關門切換主燈 已載入 ✓;互鎖舊條已移除 ✓")
print("自動化 id:", ids)
PYEOF

echo "完成。驗收:關上胤樺房間門 → 主燈整組切換(開→全關/關→全開);再關一次切回來"
