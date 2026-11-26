# pg-flagsmith sync service: webhook receiver + polling backstop.
# Runs as an unprivileged user; configure it with environment variables only
# (PGFS_DSN, FLAGSMITH_API_URL, FLAGSMITH_SERVER_KEYS, FLAGSMITH_WEBHOOK_SECRET).
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY pyproject.toml README.md ./
COPY tools ./tools
COPY extension ./extension
RUN pip install . && python extension/build.py \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin pgfs
USER 10001
EXPOSE 8080
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')"
CMD ["pg-flagsmith", "serve", "--host", "0.0.0.0", "--port", "8080", "--poll", "30"]
