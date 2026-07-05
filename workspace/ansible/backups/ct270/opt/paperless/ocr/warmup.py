"""build 時執行一次:觸發 det/cls/rec 模型自 modelscope 下載並烘進 image 層,執行期零外聯。"""
import numpy as np

from ocr_engine import make_engine

eng = make_engine()
img = np.full((64, 256, 3), 255, dtype=np.uint8)
res = eng(img)
print("warmup ok:", type(res).__name__)
