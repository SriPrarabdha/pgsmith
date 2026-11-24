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

import psycopg
import requests
from flagsmith.mappers import (
    map_environment_document_to_context,
    map_environment_document_to_identity_overrides_segments,
)

log = logging.getLogger("pg_flagsmith.sync")


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


def fetch_document(api_url: str, server_key: str, timeout: float = 20) -> dict:
    r = requests.get(api_url.rstrip("/") + "/environment-document/",
                     headers={"X-Environment-Key": server_key, "User-Agent": "pg-flagsmith-sync"},
                     timeout=timeout)
    r.raise_for_status()
    return r.json()


def document_to_load_args(doc: dict) -> tuple[str, str, str]:
    """(context json, identity_overrides json, source_rev) for flagsmith.load_context()."""
    ctx = map_environment_document_to_context(doc)
    io = map_environment_document_to_identity_overrides_segments(doc)
    return dumps(ctx), dumps(io), str(doc.get("updated_at") or "")


def load_document(conn: psycopg.Connection, doc: dict, source: str = "pusher") -> tuple[int, str]:
    ctx, io, rev = document_to_load_args(doc)
    with conn.transaction():
        row = conn.execute(
            "SELECT flagsmith.load_context(%s::json, source => %s, source_rev => %s, identity_overrides => %s::json)",
            (ctx, source, rev, io)).fetchone()
        outcome = conn.execute(
            "SELECT outcome FROM flagsmith.load_log WHERE env_key = %s ORDER BY load_id DESC LIMIT 1",
            (doc["api_key"],)).fetchone()
    return row[0], outcome[0] if outcome else "loaded"


@dataclass
class Syncer:
    dsn: str
    api_url: str
    server_keys: list[str]
    lock: threading.Lock = field(default_factory=threading.Lock)
    last_error: str | None = None
    last_sync: float = 0.0
    syncs: int = 0

    def sync_all(self) -> list[dict]:
        results = []
        with self.lock, psycopg.connect(self.dsn, autocommit=True) as conn:
            for key in self.server_keys:
                t0 = time.perf_counter()
                try:
                    doc = fetch_document(self.api_url, key)
                    sid, outcome = load_document(conn, doc)
                    res = {"environment": doc["api_key"], "name": doc.get("name"), "snapshot_id": sid,
                           "outcome": outcome, "ms": round((time.perf_counter() - t0) * 1000, 1)}
                    self.last_error = None
                except Exception as e:  # keep serving the last snapshot ("fail static")
                    res = {"server_key": key[:8] + "...", "error": str(e)[:500]}
                    self.last_error = res["error"]
                    log.error("sync failed: %s", res["error"])
                log.info("sync %s", res)
                results.append(res)
            self.last_sync = time.time()
            self.syncs += 1
        return results


def verify_signature(secret: str, body: bytes, signature: str | None) -> bool:
    if not secret:
        return True
    if not signature:
        return False
    mac = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(mac, signature)


def serve(syncer: Syncer, port: int, poll_seconds: float, webhook_secret: str = "") -> None:
    """Webhook receiver (POST /webhook) with a polling backstop; GET /healthz."""
    trigger = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # quieter default logging
            log.debug(fmt, *args)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path.rstrip("/") not in ("/webhook", ""):
                self.send_error(404)
                return
            if not verify_signature(webhook_secret, body, self.headers.get("X-Flagsmith-Signature")):
                self.send_error(401, "bad signature")
                return
            trigger.set()
            self.send_response(202)
            self.end_headers()

        def do_GET(self):
            if self.path.rstrip("/") == "/healthz":
                ok = syncer.last_error is None and syncer.syncs > 0
                payload = json.dumps({"ok": ok, "last_sync": syncer.last_sync, "syncs": syncer.syncs,
                                      "last_error": syncer.last_error}).encode()
                self.send_response(200 if ok else 503)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.send_error(404)

    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log.info("listening on :%s (POST /webhook, GET /healthz); polling every %ss", port, poll_seconds)
    syncer.sync_all()
    while True:
        fired = trigger.wait(timeout=poll_seconds)
        if fired:
            time.sleep(0.5)  # coalesce bursts of webhooks into one sync
            trigger.clear()
        syncer.sync_all()
