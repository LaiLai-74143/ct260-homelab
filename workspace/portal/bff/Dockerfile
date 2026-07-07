# portal BFF —— 單容器:FastAPI /api + Vite 靜態產物(掛 /app/static)
# 基底 pin;requirements pin;唯讀:不裝 ssh、不帶任何寫入憑證
FROM python:3.13.5-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV PORTAL_MODE=live \
    PORTAL_STATIC=/app/static \
    PORTAL_DATA=/app/data

EXPOSE 8088
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8088"]
