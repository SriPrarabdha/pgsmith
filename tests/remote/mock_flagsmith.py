"""A scriptable stand-in for Flagsmith, for failure-path tests.

  POST /_configure {"path": {"status": 429, "body": "...", "headers": {...}}, ...}
  POST /_reset
  GET  /_requests   -> every other request received: method, path, headers, body
Any other request is recorded and answered from the configuration (404 if none).
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES: dict = {}
SEEN: list = []
LOCK = threading.Lock()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        body = self._body()
        if self.path == "/_configure":
            with LOCK:
                ROUTES.update(json.loads(body))
            return self._send(204)
        if self.path == "/_reset":
            with LOCK:
                ROUTES.clear()
                SEEN.clear()
            return self._send(204)
        if self.path == "/_requests":
            with LOCK:
                return self._send(200, json.dumps(SEEN).encode(), {"Content-Type": "application/json"})
        with LOCK:
            SEEN.append({"method": self.command, "path": self.path, "headers": dict(self.headers),
                         "body": body.decode("utf-8", "replace")})
            r = ROUTES.get(self.path)
        if r is None:
            return self._send(404)
        self._send(r.get("status", 200), r.get("body", "").encode(), r.get("headers"))

    do_GET = do_POST = do_PUT = _handle


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8080), H).serve_forever()
