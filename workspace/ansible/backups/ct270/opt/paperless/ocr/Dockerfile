# RapidOCR sidecar(待辦15追加,2026-07-05):PP-OCRv5 mobile(onnxruntime)→ 雙層 PDF HTTP API
# + consume 圖片 watcher。模型檔隨 build context(./models)COPY 進 site-packages,
# warmup 僅離線驗檔,rebuild 不需 modelscope;pip 走永久白名單(pypi.org/files.pythonhosted.org),
# base image 若本地無快取需 dockerhub 暫時窗。執行期零外聯。
FROM docker.io/library/python:3.12-slim
# opencv(rapidocr 依賴)需要的系統庫
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY models/ /usr/local/lib/python3.12/site-packages/rapidocr/models/
COPY ocr_engine.py warmup.py ./
RUN python warmup.py
COPY fonts/ /app/fonts/
COPY app.py ./
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
