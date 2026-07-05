"""共用引擎工廠:warmup(build 時烘模型)與 app(執行期)必須用同一組參數,
否則執行期會再嘗試下載模型(CT270 離網必炸)。改參數只能改這裡。
注意:ocr_version/lang_type/model_type 三者要一起指定,組合須存在於
rapidocr/default_models.yaml,否則 init 直接 ValueError(Invalid OCR configuration)。"""
from rapidocr import EngineType, LangDet, LangRec, ModelType, OCRVersion, RapidOCR


def make_engine():
    return RapidOCR(params={
        "Det.engine_type": EngineType.ONNXRUNTIME,
        "Det.ocr_version": OCRVersion.PPOCRV5,
        "Det.lang_type": LangDet.CH,
        "Det.model_type": ModelType.MOBILE,
        "Rec.engine_type": EngineType.ONNXRUNTIME,
        "Rec.ocr_version": OCRVersion.PPOCRV5,
        "Rec.lang_type": LangRec.CH,
        # rec 用 server 版(80MB):mobile 版實測在難字/密排會漏字(陳大文→陳、貳→贰);
        # det 留 mobile(框線無誤差,省算力)。2026-07-05 兩份難字測試件全對。
        "Rec.model_type": ModelType.SERVER,
    })
