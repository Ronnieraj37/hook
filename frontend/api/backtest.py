"""Vercel Python function: GET /api/backtest?q=<base64url JSON>  (POST with a JSON body works too).

Request JSON: {pool, start?, days, depositUsd, range: {loPct, hiPct} | {full: true}, rules: {down, up},
               keeperFeeBps, slippagePct, delaySec, keeperCostUsd, keeperMode, mode?: "single" | "windows"}
The history never changes, so a GET answer is cached by Vercel's CDN: the same backtest is computed once.

Local development:  python3 api/backtest.py   (serves on http://127.0.0.1:8787, Next.js dev proxies to it)
"""
from __future__ import annotations

import base64
import json
import os
import sys
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _engine  # noqa: E402

MAX_DAYS = 200


def compute(req: dict) -> dict:
    req["days"] = min(float(req.get("days", 30)), MAX_DAYS)
    if req.get("mode") == "windows":
        return _engine.run_windows(req, int(req.get("windowDays", 30)), int(req.get("everyDays", 7)))
    return _engine.run(req)


class handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: dict, cache: bool) -> None:
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        if cache:
            self.send_header("Cache-Control", "public, max-age=3600, s-maxage=31536000, immutable")
        else:
            self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _run(self, req: dict, cache: bool) -> None:
        try:
            self._send(200, compute(req), cache)
        except (ValueError, KeyError, TypeError) as exc:
            self._send(400, {"error": str(exc)}, False)
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            self._send(500, {"error": f"backtest failed: {exc}"}, False)

    def do_GET(self) -> None:  # noqa: N802
        q = parse_qs(urlparse(self.path).query).get("q", [""])[0]
        if not q:
            self._send(200, {"ok": True, "pools": list(_engine.POOL_LABELS)}, False)
            return
        try:
            req = json.loads(base64.urlsafe_b64decode(q + "=" * (-len(q) % 4)))
        except Exception:  # noqa: BLE001
            self._send(400, {"error": "q must be base64url-encoded JSON"}, False)
            return
        self._run(req, cache=True)

    def do_POST(self) -> None:  # noqa: N802
        n = int(self.headers.get("content-length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            self._send(400, {"error": "body must be JSON"}, False)
            return
        self._run(req, cache=False)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8787"))
    print(f"backtest API on http://127.0.0.1:{port}/api/backtest")
    HTTPServer(("127.0.0.1", port), handler).serve_forever()
