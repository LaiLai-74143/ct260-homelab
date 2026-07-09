#!/usr/bin/env python3
"""fix-entity-registry: 修 xiaomi_miot 刪除重加後的 _2 後綴(在 CT270 跑,HA 須先停)。
①刪 entity registry 中指向已不存在 config entry 的孤兒條目(限 platform=xiaomi_miot);
②清 deleted_entities 中 xiaomi_miot 殘留(避免改名衝突);
③把現役 *_2 實體改回原名(僅當原名已釋出)。改前自備份。"""
import json
import shutil
import time

STORE = "/opt/homeassistant/config/.storage"
TS = time.strftime("%Y%m%d_%H%M%S")

reg_path = f"{STORE}/core.entity_registry"
shutil.copy2(reg_path, f"/root/_backups/core.entity_registry.before-fix2-{TS}")

valid_entries = {e["entry_id"]
                 for e in json.load(open(f"{STORE}/core.config_entries"))["data"]["entries"]}
doc = json.load(open(reg_path))
data = doc["data"]
ents = data["entities"]

orphans = [e for e in ents
           if e.get("platform") == "xiaomi_miot" and e.get("config_entry_id") not in valid_entries]
data["entities"] = [e for e in ents if e not in orphans]
print(f"孤兒條目移除:{len(orphans)}")

deleted = data.get("deleted_entities", [])
kept = [e for e in deleted if e.get("platform") != "xiaomi_miot"]
print(f"deleted_entities 清 xiaomi_miot 殘留:{len(deleted) - len(kept)}")
data["deleted_entities"] = kept

live_ids = {e["entity_id"] for e in data["entities"]}
renamed = 0
for e in data["entities"]:
    eid = e["entity_id"]
    if e.get("platform") == "xiaomi_miot" and eid.endswith("_2"):
        base = eid[:-2]
        if base not in live_ids:
            e["entity_id"] = base
            live_ids.discard(eid)
            live_ids.add(base)
            renamed += 1
print(f"_2 改回原名:{renamed}")

leftover = [e["entity_id"] for e in data["entities"]
            if e.get("platform") == "xiaomi_miot" and e["entity_id"].endswith("_2")]
if leftover:
    print("★ 仍留 _2(原名被佔,人工看):", leftover)

json.dump(doc, open(reg_path, "w"), ensure_ascii=False, indent=2)
print("registry 已寫回;備份=core.entity_registry.before-fix2-" + TS)
