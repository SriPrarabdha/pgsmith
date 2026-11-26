"""Deliver queued exposures and events (flagsmith.track_exposure / track_event)
to Flagsmith's events API, as the SDK's event processor does.

Each batch is claimed in a transaction (DELETE ... FOR UPDATE SKIP LOCKED),
POSTed, and committed only once delivered, so an event is never lost to a failed
request and several senders (this command, the database's own events_tick())
can run at once. Retries follow the SDK: 408, 429 and 5xx up to three attempts
with jittered backoff, then the batch goes back to the queue; 401/403 stops
sending for that environment; any other 4xx drops the batch (counted as rejected).
"""
from __future__ import annotations

import logging
import random
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import psycopg
import requests

from .sync import check_api_url, fetch_document, key_fingerprint

log = logging.getLogger("pg_flagsmith.events")

RETRIED = {408, 429, 500, 502, 503, 504}
ATTEMPTS = 3
TIMEOUT = 3.0


class _Retryable(Exception):
    pass


def default_events_url(api_url: str) -> str:
    host = urlsplit(api_url).hostname or ""
    if host in ("edge.api.flagsmith.com", "api.flagsmith.com"):
        return "https://events.api.flagsmith.com/v1/events"
    return api_url.rstrip("/") + "/events"


@dataclass
class Sender:
    dsn: str
    api_url: str
    server_keys: list[str]
    events_url: str | None = None
    batch_size: int = 1000
    env_keys: dict[str, str] = field(default_factory=dict)   # environment key -> server key
    refused: set[str] = field(default_factory=set)
    session: requests.Session = field(default_factory=requests.Session)

    def __post_init__(self) -> None:
        check_api_url(self.api_url)
        self.events_url = self.events_url or default_events_url(self.api_url)
        check_api_url(self.events_url)

    def _learn_keys(self) -> None:
        for key in self.server_keys:
            if key not in self.env_keys.values():
                doc = fetch_document(self.api_url, key)
                self.env_keys[doc["api_key"]] = key

    def _post(self, payload: str, server_key: str) -> int:
        """POST with the SDK's retries; returns the final status (raises _Retryable if still failing)."""
        status = None
        for attempt in range(1, ATTEMPTS + 1):
            if attempt > 1:
                time.sleep(random.uniform(0, 2 ** (attempt - 2)))
            try:
                r = self.session.post(self.events_url, data=payload.encode(), timeout=TIMEOUT, headers={
                    "Content-Type": "application/json; charset=utf-8",
                    "X-Environment-Key": server_key,
                    "Flagsmith-SDK-User-Agent": "pg-flagsmith-events"})
                status = r.status_code
            except (requests.ConnectionError, requests.Timeout) as e:
                log.warning("events: attempt %d failed: %s", attempt, e)
                continue
            if status not in RETRIED:
                return status
            log.warning("events: attempt %d got %d", attempt, status)
        raise _Retryable(f"status {status}")

    def drain_once(self, conn: psycopg.Connection, max_batches: int = 100) -> dict:
        """Send what is queued now. Returns counts per environment."""
        self._learn_keys()
        out: dict[str, dict] = {}
        pending = conn.execute("SELECT env_key FROM flagsmith.events_pending()").fetchall()
        for (env_key,) in pending:
            stats = out.setdefault(env_key, {"delivered": 0, "deduplicated": 0, "rejected": 0, "batches": 0})
            key = self.env_keys.get(env_key)
            if key is None:
                stats["skipped"] = "no server-side key for this environment"
                continue
            if env_key in self.refused:
                stats["skipped"] = "events API refused the key"
                continue
            for _ in range(max_batches):
                try:
                    with conn.transaction():
                        n_claimed, n_events, payload = conn.execute(
                            "SELECT * FROM flagsmith.events_claim(%s, %s)", (env_key, self.batch_size)).fetchone()
                        if not n_claimed:
                            break
                        status = self._post(payload, key)
                        if status in (401, 403):
                            self.refused.add(env_key)
                            log.error("events API refused key %s (%d): stopped sending for %s",
                                      key_fingerprint(key), status, env_key)
                            raise _Retryable("refused")
                        outcome = "delivered" if status < 400 else "rejected"
                        if outcome == "rejected":
                            log.warning("events API rejected %d events with %d: dropped", n_events, status)
                        conn.execute("SELECT flagsmith.events_record(%s, %s, %s, %s)",
                                     (env_key, outcome, n_claimed, n_events))
                    stats["batches"] += 1
                    stats[outcome] += n_events
                    stats["deduplicated"] += n_claimed - n_events
                except _Retryable as e:          # rolled back: the events stay queued
                    stats["retry_later"] = str(e)
                    break
        return out


def run(dsn: str, api_url: str, server_keys: list[str], poll: float | None, events_url: str | None = None,
        batch_size: int = 1000) -> int:
    sender = Sender(dsn, api_url, server_keys, events_url=events_url, batch_size=batch_size)
    with psycopg.connect(dsn, autocommit=True) as conn:
        while True:
            res = sender.drain_once(conn)
            if res:
                log.info("events %s", res)
            if not poll:
                return 0 if all("retry_later" not in r for r in res.values()) else 1
            time.sleep(poll)
