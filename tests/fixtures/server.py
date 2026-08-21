#!/usr/bin/env python3
import json
import os
from http import cookies
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote_plus, urlparse

ROOT = Path(__file__).resolve().parent
LOG = Path(os.environ["QBT_FIXTURE_LOG"])
FULL = json.loads((ROOT / "maindata-full.json").read_text())
DELTA = json.loads((ROOT / "maindata-delta.json").read_text())
FILES = json.loads((ROOT / "files.json").read_text())
USERNAME = os.environ.get("QBT_FIXTURE_USERNAME", "admin")
PASSWORD = os.environ.get("QBT_FIXTURE_PASSWORD", "fixture-password")
COOKIE_NAME = os.environ.get("QBT_FIXTURE_COOKIE_NAME", "QBT_SID_8080")
ADDED = []


def current_sid():
    sid_file = os.environ.get("QBT_FIXTURE_SID_FILE")
    if sid_file:
        return Path(sid_file).read_text().strip()
    return os.environ.get("QBT_FIXTURE_SID", "fixture-session-one")


def protected_forbidden():
    flag_file = os.environ.get("QBT_FIXTURE_FORBIDDEN_FILE")
    return os.environ.get("QBT_FIXTURE_FORBIDDEN") == "1" or (
        flag_file and Path(flag_file).exists()
    )

def login_banned():
    flag_file = os.environ.get("QBT_FIXTURE_LOGIN_BANNED_FILE")
    return bool(flag_file and Path(flag_file).exists())


def record(method, path, body, query, headers, authorized):
    entries = []
    if LOG.exists():
        entries = json.loads(LOG.read_text() or "[]")
    entries.append({
        "method": method,
        "path": path,
        "body": body,
        "query": query,
        "cookie": headers.get("Cookie", ""),
        "referer": headers.get("Referer", ""),
        "authorized": authorized,
    })
    LOG.write_text(json.dumps(entries))


class FixtureServer(HTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _read(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _authorized(self):
        jar = cookies.SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except cookies.CookieError:
            return False
        return COOKIE_NAME in jar and jar[COOKIE_NAME].value == current_sid()

    def _send(self, code, body=b"", content_type="application/json", sid=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        if sid is not None:
            self.send_header("Set-Cookie", f"{COOKIE_NAME}={sid}; HttpOnly; SameSite=Strict; Path=/")
        self.end_headers()
        if body:
            self.wfile.write(body)
    def _forbidden(self):
        self._send(403, b"Set-Cookie: SID=leaked-secret-value; password=leaked-password")

    def do_GET(self):
        parsed = urlparse(self.path)
        authorized = self._authorized()
        record("GET", parsed.path, "", parse_qs(parsed.query), self.headers, authorized)
        if parsed.path == "/health":
            self._send(200, b"ok", "text/plain")
            return
        if os.environ.get("QBT_FIXTURE_ACCESS_DENIED") == "1":
            self._forbidden()
            return
        if not authorized or protected_forbidden():
            self._forbidden()
            return
        if parsed.path == "/api/v2/sync/maindata":
            rid = (parse_qs(parsed.query).get("rid") or ["0"])[0]
            payload = DELTA if rid not in ("", "0") else FULL
            self._send(200, json.dumps(payload).encode())
            return
        if parsed.path == "/api/v2/torrents/files":
            self._send(200, json.dumps(FILES).encode())
            return
        if parsed.path == "/api/v2/transfer/speedLimitsMode":
            self._send(200, b"1")
            return
        if parsed.path == "/api/v2/app/version":
            self._send(200, b"5.2.0", "text/plain")
            return
        if parsed.path == "/api/v2/torrents/info":
            rows = []
            for h, t in FULL["torrents"].items():
                row = dict(t)
                hid = h or t.get("infohash_v1") or ""
                row["hash"] = hid
                rows.append(row)
            rows.extend(ADDED)
            self._send(200, json.dumps(rows).encode())
            return
        if parsed.path == "/api/v2/app/preferences":
            bind = ""
            bind_file = os.environ.get("QBT_FIXTURE_BIND_FILE")
            if bind_file and Path(bind_file).exists():
                bind = Path(bind_file).read_text().strip()
            self._send(200, json.dumps({"current_network_interface": bind}).encode())
            return
        self._send(404, b"{}")

    def do_POST(self):
        parsed = urlparse(self.path)
        raw_body = self._read()
        body = raw_body.decode("utf-8", errors="replace")
        authorized = self._authorized()
        record("POST", parsed.path, body, parse_qs(parsed.query), self.headers, authorized)

        if os.environ.get("QBT_FIXTURE_ACCESS_DENIED") == "1":
            self._forbidden()
            return
        if parsed.path == "/api/v2/auth/login":
            if login_banned():
                self._forbidden()
                return
            fields = parse_qs(body, keep_blank_values=True)
            if fields.get("username") == [USERNAME] and fields.get("password") == [PASSWORD]:
                sid = current_sid()
                self._send(204, b"", "text/plain", sid=sid)
            else:
                self._send(200, b"Fails.", "text/plain")
            return
        if not authorized or protected_forbidden():
            self._forbidden()
            return
        if parsed.path == "/api/v2/torrents/add":
            import re
            fields = parse_qs(body, keep_blank_values=True)
            for url in fields.get("urls") or []:
                match = re.search(r"xt=urn:btih:([A-Za-z0-9]+)", url, re.I)
                if match and len(match.group(1)) == 40:
                    info_hash = match.group(1).lower()
                    ADDED.append({"hash": info_hash, "infohash_v1": info_hash, "name": info_hash, "size": 0})
            self._send(200, b"Ok.", "text/plain")
            return
        if parsed.path in (
            "/api/v2/torrents/start",
            "/api/v2/torrents/stop",
            "/api/v2/torrents/delete",
            "/api/v2/torrents/filePrio",
            "/api/v2/torrents/setDownloadLimit",
            "/api/v2/torrents/setUploadLimit",
            "/api/v2/torrents/toggleSequentialDownload",
            "/api/v2/torrents/setShareLimits",
            "/api/v2/transfer/toggleSpeedLimitsMode",
        ):
            self._send(200, b"Ok.", "text/plain")
            return
        if parsed.path in ("/api/v2/torrents/pause", "/api/v2/torrents/resume"):
            self._send(404, b"gone", "text/plain")
            return
        self._send(404, b"{}")


if __name__ == "__main__":
    port = int(os.environ["QBT_FIXTURE_PORT"])
    FixtureServer(("127.0.0.1", port), Handler).serve_forever()
