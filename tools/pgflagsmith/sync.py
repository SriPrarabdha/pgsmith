"""Mirror Flagsmith environments into Postgres.

The environment document is fetched with a server-side key and mapped to an
EvaluationContext by the official Python SDK's own mapper, so the mapping is
correct by construction; pg_flagsmith then loads it in one transaction.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import math
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import psycopg
import requests
from flagsmith.mappers import (
    map_environment_document_to_context,
    map_environment_document_to_identity_overrides_segments,
)

log = logging.getLogger("pg_flagsmith.sync")

MAX_DOCUMENT_BYTES = 64 * 1024 * 1024
MAX_WEBHOOK_BYTES = 1024 * 1024
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "flagsmith", "host.docker.internal"}


def key_fingerprint(key: str) -> str:
    """A log-safe name for a server-side key: its prefix and a short hash."""
    prefix = key.split(".", 1)[0] if "." in key else ""
    return f"{prefix}.…{hashlib.sha256(key.encode()).hexdigest()[:8]}"


def check_api_url(api_url: str) -> None:
    u = urlsplit(api_url)
    if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password:
        raise ValueError(f"not an http(s) API URL without credentials: {api_url!r}")
    if u.scheme == "http" and u.hostname not in LOCAL_HOSTS:
        log.warning("%s uses plain http: server-side keys travel unencrypted", api_url)


def _json_safe(o: Any) -> Any:
    """JSON has no infinities; the SDK uses -inf for identity-override priority."""
    if isinstance(o, float) and math.isinf(o):
        return "-Infinity" if o < 0 else "Infinity"
    if isinstance(o, dict):
        return {k: _json_safe(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_json_safe(v) for v in o]
    return o


def dumps(o: Any) -> str:
    return json.dumps(_json_safe(o), ensure_ascii=False, separators=(",", ":"))


def fetch_document_body(api_url: str, server_key: str, timeout: float = 20,
                        max_bytes: int = MAX_DOCUMENT_BYTES) -> bytes:
    """The environment document's raw body. Unconditional on purpose: Flagsmith
    (2.295) caches Last-Modified per worker, so If-Modified-Since can be answered
    304 for seconds after a change. An unchanged body is skipped by its hash."""
    headers = {"X-Environment-Key": server_key, "Accept": "application/json", "User-Agent": "pg-flagsmith-sync"}
    with requests.get(api_url.rstrip("/") + "/environment-document/", headers=headers, timeout=timeout,
                      stream=True) as r:
        r.raise_for_status()
        if int(r.headers.get("Content-Length") or 0) > max_bytes:
            raise ValueError(f"environment document over {max_bytes} bytes")
        body = bytearray()
        for chunk in r.iter_content(65536):
            body += chunk
            if len(body) > max_bytes:
                raise ValueError(f"environment document over {max_bytes} bytes")
        return bytes(body)


def fetch_document(api_url: str, server_key: str, timeout: float = 20, max_bytes: int = MAX_DOCUMENT_BYTES) -> dict:
    return json.loads(fetch_document_body(api_url, server_key, timeout, max_bytes))


def document_to_load_args(doc: dict) -> tuple[str, str, str]:
    """(context json, identity_overrides json, source_rev) for flagsmith.apply_context()."""
    ctx = map_environment_document_to_context(doc)
    io = map_environment_document_to_identity_overrides_segments(doc)
    return dumps(ctx), dumps(io), str(doc.get("updated_at") or "")


def load_document(conn: psycopg.Connection, doc: dict, source: str = "pusher") -> tuple[int, str]:
    """Load a document; returns (snapshot id, outcome: loaded | reused | unchanged | pinned)."""
    ctx, io, rev = document_to_load_args(doc)
    with conn.transaction():
        sid, outcome = conn.execute(
            "SELECT * FROM flagsmith.apply_context(%s::json, %s::json, %s, %s)", (ctx, io, source, rev)).fetchone()
    return sid, outcome


def mark_checked(conn: psycopg.Connection, env_key: str) -> None:
    """The environment is current (same document as last time): health() counts it as a check."""
    conn.execute("SELECT flagsmith.mark_checked(%s)", (env_key,))


@dataclass
class Syncer:
    dsn: str
    api_url: str
    server_keys: list[str]
    lock: threading.Lock = field(default_factory=threading.Lock)
    body_hashes: dict[str, str] = field(default_factory=dict)   # server key -> sha256 of the last loaded body
    env_keys: dict[str, str] = field(default_factory=dict)      # server key -> environment key
    failing: bool = False
    last_sync: float = 0.0
    syncs: int = 0

    def __post_init__(self) -> None:
        check_api_url(self.api_url)

    def sync_all(self) -> list[dict]:
        results = []
        with self.lock, psycopg.connect(self.dsn, autocommit=True) as conn:
            failing = False
            for key in self.server_keys:
                t0 = time.perf_counter()
                try:
                    body = fetch_document_body(self.api_url, key)
                    digest = hashlib.sha256(body).hexdigest()
                    if self.body_hashes.get(key) == digest:
                        mark_checked(conn, self.env_keys[key])
                        res = {"environment": self.env_keys[key], "outcome": "unchanged"}
                    else:
                        doc = json.loads(body)
                        sid, outcome = load_document(conn, doc)
                        self.env_keys[key] = doc["api_key"]
                        self.body_hashes[key] = digest
                        res = {"environment": doc["api_key"], "name": doc.get("name"), "snapshot_id": sid,
                               "outcome": outcome}
                    res["ms"] = round((time.perf_counter() - t0) * 1000, 1)
                except Exception as e:  # keep serving the last snapshot ("fail static")
                    failing = True
                    self.body_hashes.pop(key, None)
                    res = {"server_key": key_fingerprint(key), "error": str(e)[:500]}
                    log.error("sync failed for %s: %s", key_fingerprint(key), res["error"])
                log.info("sync %s", res)
                results.append(res)
            self.failing = failing
            self.last_sync = time.time()
            self.syncs += 1
        return results


def verify_signature(secret: str, body: bytes, signature: str | None) -> bool:
    """Flagsmith signs webhook bodies with HMAC-SHA256 (X-Flagsmith-Signature)."""
    if not secret or not signature:
        return False
    mac = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(mac, signature.strip().lower())


def make_server(syncer: "Syncer", trigger: threading.Event, host: str = "127.0.0.1", port: int = 8080,
                webhook_secret: str = "", allow_unsigned: bool = False) -> ThreadingHTTPServer:
    """The webhook receiver (POST /webhook) and health endpoint (GET /healthz).

    The webhook body is never trusted: a valid call only triggers a sync, which
    fetches the document itself. Calls must be signed unless allow_unsigned."""
    if not webhook_secret and not allow_unsigned:
        raise SystemExit("pg-flagsmith serve: set FLAGSMITH_WEBHOOK_SECRET (the webhook's signing secret in Flagsmith), "
                         "or pass --allow-unsigned-webhooks to accept unsigned calls")

    class Handler(BaseHTTPRequestHandler):
        timeout = 10                      # seconds a client may take to send its request
        server_version = "pg-flagsmith"
        sys_version = ""

        def log_message(self, fmt, *args):  # quieter default logging
            log.debug(fmt, *args)

        def do_POST(self):
            if self.path.rstrip("/") not in ("/webhook", ""):
                self.send_error(404)
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = -1
            if n < 0 or n > MAX_WEBHOOK_BYTES:
                self.send_error(413 if n > 0 else 400)
                return
            body = self.rfile.read(n)
            if webhook_secret and not verify_signature(webhook_secret, body, self.headers.get("X-Flagsmith-Signature")):
                self.send_error(401, "bad signature")
                return
            trigger.set()
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            if self.path.rstrip("/") == "/healthz":
                ok = not syncer.failing and syncer.syncs > 0
                payload = json.dumps({"ok": ok, "last_sync": syncer.last_sync, "syncs": syncer.syncs}).encode()
                self.send_response(200 if ok else 503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.send_error(404)

    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    return httpd


def serve(syncer: Syncer, port: int, poll_seconds: float, webhook_secret: str = "", host: str = "127.0.0.1",
          allow_unsigned: bool = False) -> None:
    """Webhook receiver with a polling backstop."""
    trigger = threading.Event()
    httpd = make_server(syncer, trigger, host, port, webhook_secret, allow_unsigned)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log.info("listening on %s:%s (POST /webhook, GET /healthz); polling every %ss", host, port, poll_seconds)
    syncer.sync_all()
    while True:
        fired = trigger.wait(timeout=poll_seconds)
        if fired:
            time.sleep(0.5)  # coalesce bursts of webhooks into one sync
            trigger.clear()
        syncer.sync_all()
