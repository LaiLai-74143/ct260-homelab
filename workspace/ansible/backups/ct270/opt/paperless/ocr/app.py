"""RapidOCR sidecar(待辦15追加,2026-07-05):
1. POST /ocr:收 PDF,回內嵌隱形文字層的雙層 PDF(pre-consume script 呼叫;僅 PDF——
   paperless 在 pre-consume 前已依原始 mime 選 parser,圖片換型成 PDF 會令 image parser 炸掉)。
2. consume watcher:掃 /consume 圖片檔 → 轉雙層 PDF(原圖刪除);paperless 端以
   CONSUMER_IGNORE_PATTERNS 忽略圖片與 *.tmp,只會吃到成品 PDF。
PP-OCRv5 mobile(onnxruntime),模型烘在 image 內,執行期零外聯。
任何失敗:endpoint 回 4xx/5xx(呼叫端 fail-open 落回 tesseract);watcher 記 failed 不重試。"""
import os
import threading
import time
import unicodedata

import numpy as np
import pymupdf
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import Response

from ocr_engine import make_engine

DPI = 300
MAX_PAGES = 50          # 超過整份原樣退回(交 tesseract),避免部分頁有文字層騙過 paperless skip 模式
MIN_EXISTING_TEXT = 50  # PDF 已有文字層(數位原生)就不重跑
MIN_SCORE = 0.3
CONSUME_DIR = os.environ.get("CONSUME_DIR", "/consume")
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp", ".bmp", ".gif"}
# 嵌入字型必須是 TTF(glyf):pymupdf 內建 china-t 無可攜 ToUnicode(pdfminer 萃取成 CID 亂碼),
# OTF(CFF)subset_fonts 會炸(Reserved charstring byte)。subset 後每份約 +40KB。
FONT_PATH = os.environ.get("OCR_FONT", "/app/fonts/NotoSansTC.ttf")

IMAGE_MAGIC = [
    (b"\xff\xd8", "jpeg"), (b"\x89PNG", "png"), (b"II*\x00", "tiff"),
    (b"MM\x00*", "tiff"), (b"BM", "bmp"), (b"GIF8", "gif"),
]

engine = make_engine()
engine_lock = threading.Lock()  # rapidocr 執行緒安全未知,序列化推理(2C 也無並行紅利)
app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"ok": True}


def sniff(data: bytes):
    if data[:5] == b"%PDF-":
        return "pdf"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    for magic, kind in IMAGE_MAGIC:
        if data[: len(magic)] == magic:
            return kind
    return None


def ocr_page(page) -> int:
    """OCR 單頁並疊隱形文字層(render_mode=3),回傳寫入行數。
    座標:pixmap 是顯示座標(含旋轉),insert_text 要未旋轉座標 → 乘 derotation_matrix。
    旋轉頁的文字層方向會偏(拍照件 rotation 恆 0,可接受)。"""
    zoom = DPI / 72.0
    pix = page.get_pixmap(dpi=DPI, colorspace=pymupdf.csRGB, alpha=False)
    img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, 3)
    img = img[:, :, ::-1].copy()  # RGB→BGR(rapidocr 吃 opencv 慣例)
    with engine_lock:
        res = engine(img)
    boxes = getattr(res, "boxes", None)
    txts = getattr(res, "txts", None) or ()
    scores = getattr(res, "scores", None) or [1.0] * len(txts)
    if boxes is None or not len(txts):
        return 0
    n = 0
    for box, txt, score in zip(boxes, txts, scores):
        if not txt or score < MIN_SCORE:
            continue
        txt = unicodedata.normalize("NFKC", txt)  # 全形數字/符號→半形,利於搜尋
        xs = [float(p[0]) for p in box]
        ys = [float(p[1]) for p in box]
        h = (max(ys) - min(ys)) / zoom
        if h <= 1:
            continue
        origin = pymupdf.Point(min(xs) / zoom, max(ys) / zoom - h * 0.2) * page.derotation_matrix
        try:
            page.insert_text(origin, txt, fontsize=max(h * 0.85, 4),
                             fontname="notoTC", fontfile=FONT_PATH, render_mode=3)
            n += 1
        except Exception:
            continue
    return n


def build_searchable(data: bytes, kind: str):
    """回 (bytes, status)。status=lines=N 時 bytes 是雙層 PDF;skipped-* 時原樣退回。"""
    if kind == "pdf":
        doc = pymupdf.open(stream=data, filetype="pdf")
    else:
        img_doc = pymupdf.open(stream=data, filetype=kind)
        pdf_bytes = img_doc.convert_to_pdf()
        img_doc.close()
        doc = pymupdf.open(stream=pdf_bytes, filetype="pdf")
    try:
        if doc.page_count > MAX_PAGES:
            return data, "skipped-too-many-pages"
        if kind == "pdf" and sum(len(p.get_text().strip()) for p in doc) >= MIN_EXISTING_TEXT:
            return data, "skipped-has-text"
        total = sum(ocr_page(page) for page in doc)
        if total:
            try:
                doc.subset_fonts()  # 需 fonttools;失敗僅膨脹不失功能
            except Exception as e:
                print(f"subset_fonts failed (PDF will be large): {e}", flush=True)
        return doc.tobytes(garbage=3, deflate=True), f"lines={total}"
    finally:
        doc.close()


@app.post("/ocr")
def do_ocr(file: UploadFile = File(...)):
    data = file.file.read()
    if not data:
        raise HTTPException(400, "empty file")
    kind = sniff(data)
    if kind is None:
        raise HTTPException(415, "unsupported file type")
    try:
        out, status = build_searchable(data, kind)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"ocr failed: {e}")
    return Response(content=out, media_type="application/pdf", headers={"X-OCR": status})


def convert_one(path: str, failed: set):
    try:
        with open(path, "rb") as f:
            data = f.read()
        kind = sniff(data)
        if kind in (None, "pdf"):
            failed.add(path)
            return
        out, status = build_searchable(data, kind)
        if out[:5] != b"%PDF-":
            failed.add(path)
            return
        base = os.path.splitext(path)[0]
        target = base + ".pdf"
        if os.path.exists(target):
            target = f"{base}-{int(time.time())}.pdf"
        tmp = target + ".tmp"
        with open(tmp, "wb") as f:
            f.write(out)
        os.replace(tmp, target)
        os.unlink(path)
        print(f"watcher: {os.path.basename(path)} -> {os.path.basename(target)} ({status})", flush=True)
    except Exception as e:
        failed.add(path)
        print(f"watcher: convert failed {path}: {e}", flush=True)


def watch_consume():
    """圖片入 consume → 雙層 PDF。尺寸兩輪相同才動手,避免搬檔中途讀到半截。"""
    if not os.path.isdir(CONSUME_DIR):
        print(f"watcher: {CONSUME_DIR} missing, disabled", flush=True)
        return
    sizes: dict = {}
    failed: set = set()
    print(f"watcher: watching {CONSUME_DIR}", flush=True)
    while True:
        try:
            for root, _, names in os.walk(CONSUME_DIR):
                for name in names:
                    p = os.path.join(root, name)
                    if os.path.splitext(name)[1].lower() not in IMAGE_EXTS or p in failed:
                        continue
                    try:
                        sz = os.path.getsize(p)
                    except OSError:
                        continue
                    if sizes.get(p) != sz:
                        sizes[p] = sz
                        continue
                    convert_one(p, failed)
                    sizes.pop(p, None)
        except Exception as e:
            print(f"watcher: scan error: {e}", flush=True)
        time.sleep(3)


threading.Thread(target=watch_consume, daemon=True).start()
