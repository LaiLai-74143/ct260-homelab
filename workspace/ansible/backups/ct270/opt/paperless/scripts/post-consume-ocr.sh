#!/usr/bin/env bash
# 待辦15追加(2026-07-05):入庫完成後把原件送 sidecar /text,以 RapidOCR 純文字覆寫
# document.content 並重建搜尋索引。處理兩類原件:
# ① 圖片(手機 app「分享原始照片」API 直傳):不經 pre-consume 換型(parser 依原始 mime
#    先定)也不經 consume watcher → 否則只能落 tesseract,中文品質差。
# ② sidecar 自產雙層 PDF(帶 producer 標記):總字數 ≤50 的短件被 paperless 判「無文字」
#    (parsers.py VALID_TEXT_LENGTH=50),照樣 ghostscript 產 archive 且 content 取自 archive,
#    subset 字型 ToUnicode 被改壞 → 整齊 -0x100 錯字(品項→品霅);/text 對標記件直接回
#    層內乾淨文字。無標記的 PDF(數位原生/外來)不動。
# fail-open:任何失敗一律 exit 0,保留原 content。
set -u
URL="${OCR_SIDECAR_TEXT_URL:-http://ocr:8080/text}"
MARK="paperless-ocr-sidecar rapidocr"
[ -n "${DOCUMENT_ID:-}" ] || exit 0
SRC="${DOCUMENT_SOURCE_PATH:-}"
[ -n "$SRC" ] && [ -r "$SRC" ] || exit 0
# 原件副檔名由 paperless 依偵測到的 mime 命名,可信
case "$(printf '%s' "${SRC##*.}" | tr 'A-Z' 'a-z')" in
    jpg|jpeg|png|tif|tiff|webp|bmp|gif) ;;
    pdf) grep -qa "$MARK" "$SRC" || exit 0 ;;  # producer 標記在未壓縮 Info dict,可直接 grep
    *) exit 0 ;;
esac
TMP="$(mktemp /tmp/postocr.XXXXXX)" || exit 0
trap 'rm -f "$TMP"' EXIT
# --noproxy '*':容器帶 squid proxy env,到 sidecar 是 compose 網內直連,不得繞道
if ! curl -sfS --noproxy '*' --max-time 600 -F "file=@${SRC}" -o "$TMP" "$URL"; then
    echo "post-consume-ocr: sidecar unreachable, keep tesseract content (doc ${DOCUMENT_ID})" >&2
    exit 0
fi
[ -s "$TMP" ] || { echo "post-consume-ocr: empty OCR text, keep tesseract content (doc ${DOCUMENT_ID})" >&2; exit 0; }
export OCR_TEXT_FILE="$TMP"
python3 - >&2 <<'EOF' || echo "post-consume-ocr: content update failed (doc ${DOCUMENT_ID})" >&2
import os
import sys

sys.path.insert(0, "/usr/src/paperless/src")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "paperless.settings")
import django

django.setup()
from documents import index
from documents.models import Document

pk = int(os.environ["DOCUMENT_ID"])
text = open(os.environ["OCR_TEXT_FILE"], encoding="utf-8").read().strip()
if not text:
    sys.exit(0)
doc = Document.objects.get(pk=pk)
doc.content = text
doc.save(update_fields=["content", "modified"])
index.add_or_update_document(doc)  # AsyncWriter:索引鎖忙時排隊背景寫
print(f"post-consume-ocr: doc {pk} content -> RapidOCR ({len(text)} chars)")
EOF
exit 0
