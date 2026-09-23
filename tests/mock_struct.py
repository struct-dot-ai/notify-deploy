"""Minimal stand-in for POST /api/deployments/ used by the tests.

Every request is appended to REQUESTS_FILE as one JSON line:
{"authorization": ..., "body": {...}, "code": <status returned>}.

Behaviour by bearer token:
  sk-bad    -> 401
  sk-down   -> 500 every time
  sk-flaky  -> 503 on the first request, then normal
  anything  -> 200 with an id derived from the idempotency key, so the same
               key always returns the same id (like the real endpoint).
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REQUESTS_FILE = os.environ.get("REQUESTS_FILE", "requests.jsonl")
_flaky_seen = {"count": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, code, payload, record):
        record["code"] = code
        with open(REQUESTS_FILE, "a") as f:
            f.write(json.dumps(record) + "\n")
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode()
        auth = self.headers.get("Authorization", "")
        record = {"path": self.path, "authorization": auth, "raw": raw}
        try:
            body = json.loads(raw)
        except ValueError:
            return self._reply(422, {"detail": "invalid json"}, record)
        record["body"] = body
        if self.path != "/api/deployments/":
            return self._reply(404, {"detail": "not found"}, record)
        if auth == "Bearer sk-bad":
            return self._reply(401, {"detail": "invalid key"}, record)
        if auth == "Bearer sk-down":
            return self._reply(500, {"detail": "boom"}, record)
        if auth == "Bearer sk-flaky" and _flaky_seen["count"] == 0:
            _flaky_seen["count"] += 1
            return self._reply(503, {"detail": "try again"}, record)
        for field in ("repository", "sha", "environment", "idempotencyKey"):
            if not body.get(field):
                return self._reply(422, {"detail": f"{field} required"}, record)
        dep_id = "dep_" + hashlib.sha256(body["idempotencyKey"].encode()).hexdigest()[:12]
        return self._reply(
            200,
            {"id": dep_id, "source": "custom", "sha": body["sha"], "environment": body["environment"],
             "metadata": {"id": "not-the-top-level-id"}},
            record,
        )


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
