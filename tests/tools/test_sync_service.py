"""The webhook receiver's hardening: signatures, sizes, health."""
from __future__ import annotations

import hashlib
import hmac
import http.client
import threading
import types

import pytest

from tools.pgflagsmith.sync import MAX_WEBHOOK_BYTES, check_api_url, key_fingerprint, make_server, verify_signature


@pytest.fixture()
def server():
    syncer = types.SimpleNamespace(failing=False, syncs=0, last_sync=0.0)
    trigger = threading.Event()
    httpd = make_server(syncer, trigger, "127.0.0.1", 0, webhook_secret="s3cret")
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield httpd.server_address[1], trigger, syncer
    httpd.shutdown()


def post(port, body: bytes, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("POST", "/webhook", body=body, headers=headers or {})
    r = c.getresponse()
    return r.status


def test_only_signed_webhooks_trigger_a_sync(server):
    port, trigger, _ = server
    body = b'{"event_type": "FLAG_UPDATED"}'
    assert post(port, body) == 401
    assert post(port, body, {"X-Flagsmith-Signature": "00" * 32}) == 401
    assert not trigger.is_set()
    sig = hmac.new(b"s3cret", body, hashlib.sha256).hexdigest()
    assert post(port, body, {"X-Flagsmith-Signature": sig}) == 202
    assert trigger.is_set()


def test_oversized_and_malformed_requests_are_refused(server):
    port, trigger, _ = server
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.putrequest("POST", "/webhook")
    c.putheader("Content-Length", str(MAX_WEBHOOK_BYTES + 1))
    c.endheaders()
    assert c.getresponse().status == 413
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.putrequest("POST", "/webhook")
    c.putheader("Content-Length", "-5")
    c.endheaders()
    assert c.getresponse().status == 400
    assert not trigger.is_set()


def test_health_reports_without_details(server):
    port, _, syncer = server
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", "/healthz")
    r = c.getresponse()
    assert r.status == 503 and b"error" not in r.read()
    syncer.syncs = 1
    c.request("GET", "/healthz")
    assert c.getresponse().status == 200


def test_unsigned_mode_must_be_explicit():
    with pytest.raises(SystemExit):
        make_server(types.SimpleNamespace(), threading.Event(), "127.0.0.1", 0)


def test_helpers():
    assert not verify_signature("", b"x", "abc")
    assert key_fingerprint("ser.abcdefghijkl").startswith("ser.…") and "abcdefgh" not in key_fingerprint("ser.abcdefghijkl")
    for bad in ["ftp://x/api/v1/", "https://u:p@x/api/v1/", "x"]:
        with pytest.raises(ValueError):
            check_api_url(bad)
    check_api_url("https://flagsmith.example.com/api/v1/")
