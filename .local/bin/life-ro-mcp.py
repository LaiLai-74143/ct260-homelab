#!/usr/bin/env python3
"""life-ro-mcp: life-ops 的唯讀子集 MCP 包裝(生活助理專用,待辦49 生活對話框)。

生活助理(life-chat.py 起的 claude -p)只掛這個 server——模型物理上只有讀取工具;
寫入(calendar_add/update/delete、add_transaction、settle_transaction、add_person)
一律走「提案單→使用者確認→life-chat.py 服務端執行」,不經模型之手。

實作:import 本尊 /home/codex/life-ops-mcp/server.py,過濾 TOOLS/DISPATCH 後
跑同款 stdio JSON-RPC loop。SoT=本尊 server.py;那邊改 schema 這邊自動跟。
"""
import json
import sys

sys.path.insert(0, "/home/codex/life-ops-mcp")
import server as lo  # noqa: E402

RO = (
    "calendar_agenda", "calendar_conflicts", "prep_check",
    "find_person", "list_debts", "balance_by_person", "overdue_debts",
)
TOOLS = [t for t in lo.TOOLS if t["name"] in RO]


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        m, mid = req.get("method"), req.get("id")
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "life-ro", "version": "1.0"}}})
        elif m == "notifications/initialized":
            pass
        elif m == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif m == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif m == "tools/call":
            name = req["params"]["name"]
            args = req["params"].get("arguments", {}) or {}
            if name not in RO:
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text",
                                              "text": f"ERROR: {name} 非唯讀工具,生活助理不可直接執行"}],
                                 "isError": True}})
                continue
            try:
                text = lo.DISPATCH[name](args)
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text", "text": text}]}})
            except Exception as e:  # noqa: BLE001
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text", "text": f"ERROR: {e}"}],
                                 "isError": True}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid,
                  "error": {"code": -32601, "message": f"method not found: {m}"}})


if __name__ == "__main__":
    main()
