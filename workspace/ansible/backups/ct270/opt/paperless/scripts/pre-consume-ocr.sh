#!/usr/bin/env bash
# 待辦15追加(2026-07-05):把 PDF 入件先送 RapidOCR sidecar 換成雙層 PDF,
# paperless OCR_MODE 預設 skip 見文字層即直接採用。
# 僅處理 PDF:paperless 在 pre-consume 前已依原始 mime 選 parser,圖片在此換型會炸
# (圖片走 sidecar 的 consume watcher 或 tesseract)。
# fail-open:sidecar 掛/超時/回怪東西 → 一律 exit 0 原檔不動,落回 tesseract chi_tra。
set -u
URL="${OCR_SIDECAR_URL:-http://ocr:8080/ocr}"
[ -n "${DOCUMENT_WORKING_PATH:-}" ] || exit 0
head -c 5 "${DOCUMENT_WORKING_PATH}" 2>/dev/null | grep -q '%PDF-' || exit 0
TMP="$(mktemp /tmp/preocr.XXXXXX)" || exit 0
trap 'rm -f "$TMP" "$TMP.h"' EXIT
# --noproxy '*':容器帶 squid proxy env,到 sidecar 是 compose 網內直連,不得繞道
if curl -sfS --noproxy '*' --max-time 600 -D "$TMP.h" -F "file=@${DOCUMENT_WORKING_PATH}" -o "$TMP" "$URL"; then
    if [ -s "$TMP" ] && head -c 5 "$TMP" | grep -q '%PDF-'; then
        cat "$TMP" > "$DOCUMENT_WORKING_PATH"  # cat 覆寫,保留原檔權限
        # X-OCR:lines=N(已疊層)/skipped-*(原樣退回:已有文字層/自產件/頁數超限)
        STATUS="$(grep -i '^x-ocr:' "$TMP.h" 2>/dev/null | tr -d '\r' | awk '{print $2}')"
        echo "pre-consume-ocr: sidecar ${STATUS:-ok} ($(basename "$DOCUMENT_WORKING_PATH"))" >&2
    else
        echo "pre-consume-ocr: unexpected response, fallback to tesseract" >&2
    fi
else
    echo "pre-consume-ocr: sidecar unreachable, fallback to tesseract" >&2
fi
exit 0
