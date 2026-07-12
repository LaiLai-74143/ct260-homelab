#!/usr/bin/env python3
"""dibao-brief-backfill: 一次性回填(0.19.1)——為既有邸報件補 AI 導讀。

對象:origin='rss' 且 full_text 尚無「【AI 導讀】」的件;批 10 條問 DeepSeek,
以 dibao-ingest v2 的 build_full_text 重組正文(導讀+原題+有料節選+發布註記)。
直接寫 ~/.local/state/archive-svc/archive.db(svc 在跑也安全:短交易+timeout 15s)。
冪等可重跑:已回填的自動不入列;單批失敗只跳過該批,原 full_text 不動。
用法:dibao-brief-backfill.py [--dry-run] [--limit N](dry-run 只印首批前後對照)
"""
import importlib.util
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
DB_FILE = HOME / ".local/state/archive-svc/archive.db"
BATCH = 10

# 共用已裝的 dibao-ingest(_deepseek/extract_json_array/build_full_text 的 SoT)
_spec = importlib.util.spec_from_file_location("dibao", HOME / ".local/bin/dibao-ingest.py")
dibao = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dibao)
if not hasattr(dibao, "build_full_text"):  # 裝的還是 v1 → 先裝 v2 再跑(免燒 API 後半路崩)
    print("~/.local/bin/dibao-ingest.py 非 v2(缺 build_full_text),先裝 v2 再跑 backfill",
          file=sys.stderr)
    sys.exit(1)

SYSTEM_PROMPT = """你是「邸報」編輯。對輸入的每一條既有邸報條目(中文標題、一句話摘要、原文節選),
寫 2-4 句繁體中文(zh-TW)導讀,約 80-160 字:這在講什麼、核心內容或主張、為何值得注意。
節選若資訊太少(例如只有連結),就用你對該主題的背景知識解釋名詞與脈絡,
但不得虛構原文的具體數據與結論,背景推測以「(背景)」標明。
只返回嚴格 JSON 陣列,不要 markdown、不要解釋、不要額外欄位:
[{"i": <輸入編號>, "brief": "..."}]"""


def parse_old(full_text: str) -> tuple[str, str, str]:
    """拆 v1 格式 f"{原題}\\n\\n{節選}\\n\\n(邸報僅存節選;…)" → (原題,節選,pub)。
    現庫 38 筆尾註皆無「原文發布」段(bootstrap 版)→ pub='?';
    有的話只抓日期字元(不吃全/半形收尾符)。節選經 _strip_html 無換行,仍防禦多段。"""
    parts = [p for p in full_text.split("\n\n") if p.strip()]
    if not parts:
        return "?", "", "?"
    note = parts[-1] if parts[-1].lstrip().startswith("(邸報") else ""
    body = parts[:-1] if note else parts
    m = re.search(r"原文發布 ([0-9?: -]+)", note)
    pub = m.group(1).strip() if m else "?"
    title = body[0] if body else "?"
    snippet = " ".join(body[1:]) if len(body) > 1 else ""
    return title, snippet, pub


def classify_briefs(batch: list[dict]) -> dict[int, str]:
    payload = json.dumps([{"i": n, "title": r["title"], "summary": r["summary"],
                           "excerpt": r["full_text"][:400]} for n, r in enumerate(batch)],
                         ensure_ascii=False)
    content, _ = dibao._deepseek(SYSTEM_PROMPT, payload)
    if not content.strip():  # reasoning 吃光預算回空 content → 重試一次
        content, _ = dibao._deepseek(SYSTEM_PROMPT, payload)
    out = {}
    for row in dibao.extract_json_array(content):
        if not isinstance(row, dict):
            continue
        n = row.get("i")
        brief = re.sub(r"\s+", " ", str(row.get("brief") or "")).strip()[:600]
        if isinstance(n, int) and 0 <= n < len(batch) and brief:
            out[n] = brief
    return out


def main():
    dry = "--dry-run" in sys.argv
    limit = 0
    if "--limit" in sys.argv:
        try:
            limit = int(sys.argv[sys.argv.index("--limit") + 1])
        except (IndexError, ValueError):
            print("用法:dibao-brief-backfill.py [--dry-run] [--limit N]", file=sys.stderr)
            sys.exit(2)
    if not DB_FILE.exists():
        print(f"缺 {DB_FILE}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(DB_FILE, timeout=15)
    rows = [{"id": r[0], "title": r[1], "summary": r[2], "full_text": r[3]}
            for r in conn.execute(
                "SELECT id,title,summary,full_text FROM items "
                "WHERE origin='rss' AND full_text NOT LIKE '%【AI 導讀】%' "
                "ORDER BY created_at").fetchall()]
    if limit:
        rows = rows[:limit]
    if not rows:
        print("無待回填件(全部已含導讀)")
        return

    done = failed = 0
    for off in range(0, len(rows), BATCH):
        batch = rows[off:off + BATCH]
        try:
            briefs = classify_briefs(batch)
        except Exception as e:  # noqa: BLE001
            failed += len(batch)
            print(f"batch@{off} 導讀失敗 {type(e).__name__}: {str(e)[:120]}——跳過本批(可重跑)",
                  file=sys.stderr)
            continue
        now = datetime.now(timezone.utc).isoformat()  # 與 svc _now() 同格式
        for n, r in enumerate(batch):
            brief = briefs.get(n)
            if not brief:
                failed += 1
                continue
            title, snippet, pub = parse_old(r["full_text"])
            new_ft = dibao.build_full_text(title, snippet, brief, pub)
            if dry:
                print(f"--- {r['id']} {r['title']}\n[舊] {r['full_text'][:150]}…\n[新] {new_ft[:300]}…\n")
                continue
            conn.execute("UPDATE items SET full_text=?, updated_at=? WHERE id=?",
                         (new_ft, now, r["id"]))
            done += 1
        if not dry:
            conn.commit()
            print(f"batch@{off} 回填 {min(off + BATCH, len(rows))}/{len(rows)}")
        if dry:
            break  # dry-run 只看首批
    conn.close()
    print(f"完成:updated={done} skipped={failed} dry={dry}")
    sys.exit(0 if (dry or done) else 1)


if __name__ == "__main__":
    main()
