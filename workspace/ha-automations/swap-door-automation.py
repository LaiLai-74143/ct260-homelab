#!/usr/bin/env python3
"""swap-door-automation: 在 CT270 跑——automations.yaml 移除 door_motion_5s_lights_off
(5秒互鎖,實測雲端輪詢下不觸發),換上 door_closed_toggle_lights(關門切換主燈)。
新塊由 finish 腳本 push 到 /tmp/door-toggle.yaml。冪等;改前自備份。"""
import shutil
import time

PATH = "/opt/homeassistant/config/automations.yaml"
NEW_BLOCK = open("/tmp/door-toggle.yaml").read()

src = open(PATH).read()
if "door_closed_toggle_lights" in src:
    print("已是 toggle 版,跳過")
    raise SystemExit(0)

shutil.copy2(PATH, f"{PATH}.before-toggle-{time.strftime('%Y%m%d_%H%M%S')}")

if "door_motion_5s_lights_off" in src:
    head, _, rest = src.partition("\n- id: door_motion_5s_lights_off")
    # 互鎖塊到下一個頂層條目(或檔尾)為止
    nxt = rest.find("\n- id: ")
    src = head + (rest[nxt:] if nxt != -1 else "")
    print("已移除 door_motion_5s_lights_off")

src = src.rstrip() + "\n" + NEW_BLOCK
open(PATH, "w").write(src)
n = src.count("\n- id: ") + (1 if src.startswith("- id: ") else 0)
print(f"已寫回;現有自動化 {n} 條")
