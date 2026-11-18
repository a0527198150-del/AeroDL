FROM denoland/deno:bin-2.9.8 AS deno
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 DENO_NO_UPDATE_CHECK=1
COPY --from=deno /deno /usr/local/bin/deno
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt \
    && deno --version \
    && yt-dlp --version
COPY main.py /app/main.py
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "10000", "--workers", "1"]
