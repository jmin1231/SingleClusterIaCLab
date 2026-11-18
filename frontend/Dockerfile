FROM cgr.dev/chainguard/python:latest-dev@sha256:88d8715285b78746679a86fa126fe01e68b7940c3299ee3b4cf8245d4b17095f AS build
USER root
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target /app/packages -r requirements.txt

FROM cgr.dev/chainguard/python:latest@sha256:d914788ef74519450a69bc5cce6a1cc747dbefb95a3d431daa4ff707767fea8a
WORKDIR /app
COPY --from=build /app/packages /app/packages
COPY app.py .
COPY templates templates
ENV PYTHONPATH=/app/packages
USER 65532
ENTRYPOINT ["python", "-m", "gunicorn", "--bind", "0.0.0.0:443", "--workers", "2", "--access-logfile", "-", "--certfile", "/etc/app/tls/tls.crt", "--keyfile", "/etc/app/tls/tls.key", "app:app"]
