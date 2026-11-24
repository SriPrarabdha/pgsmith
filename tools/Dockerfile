# pg-flagsmith sync service: webhook receiver + polling backstop
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md ./
COPY tools ./tools
COPY extension ./extension
RUN pip install --no-cache-dir . && python extension/build.py
EXPOSE 8080
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')"
CMD ["pg-flagsmith", "serve", "--port", "8080", "--poll", "30"]
