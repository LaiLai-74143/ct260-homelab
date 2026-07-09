#!/usr/bin/env python3
"""ct270-helper: 在 CT270 宿主執行的唯讀輔助(finish-ha-notify.sh push 過來跑)。
子命令:
  entry-id       印 xiaomi_miot config entry 的 entry_id(reload 用)
  list-motion    列 xiaomi_miot 的人體感應 binary_sensor(entity_id 一行一個)
  check-devices  印 xiaomi_miot 設備數與最新建立時間(reload 後比對用)
只讀 .storage,不印任何 token/密碼。"""
import json
import sys

STORE = "/opt/homeassistant/config/.storage"


def entries():
    return json.load(open(f"{STORE}/core.config_entries"))["data"]["entries"]


def reg():
    return json.load(open(f"{STORE}/core.entity_registry"))["data"]["entities"]


def devices():
    return json.load(open(f"{STORE}/core.device_registry"))["data"]["devices"]


cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "entry-id":
    for e in entries():
        if e["domain"] == "xiaomi_miot":
            print(e["entry_id"])
            break
elif cmd == "list-motion":
    for e in reg():
        eid = e["entity_id"]
        if (e.get("platform") == "xiaomi_miot" and eid.startswith("binary_sensor.")
                and ("motion" in eid or "occupancy" in eid or "presence" in eid)):
            print(eid)
elif cmd == "check-devices":
    ds = [d for d in devices()
          if any(i and i[0] == "xiaomi_miot" for i in d.get("identifiers", []))]
    latest = max((d.get("created_at") or "" for d in ds), default="")
    print(f"xiaomi_miot devices={len(ds)} latest_created={latest[:19]}")
else:
    print(__doc__)
    sys.exit(2)
