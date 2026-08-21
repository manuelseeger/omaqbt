#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import hashlib
import json
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

root = Path(".").resolve()
tmp = Path(tempfile.mkdtemp(prefix="omaqbt-contract-"))
log = tmp / "requests.json"
secret_log = tmp / "secret-calls.log"
sid_file = tmp / "sid"
sid_file.write_text("fixture-session-one")
forbidden_file = tmp / "forbidden"
login_banned_file = tmp / "login-banned"
state_dir = tmp / "runtime" / "omaqbt"
bin_dir = tmp / "bin"
bin_dir.mkdir()
secret_stub = bin_dir / "secret-tool"
secret_stub.write_text("""#!/bin/sh
printf '%s\\n' \"$*\" >>\"$QBT_SECRET_LOG\"
if [ \"${QBT_STUB_MISSING:-0}\" = 1 ]; then
  exit 1
fi
if [ \"${QBT_STUB_WRONG:-0}\" = 1 ]; then
  printf %s wrong-fixture-password
else
  printf %s fixture-password
fi
""")
secret_stub.chmod(0o700)

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()
base = f"http://127.0.0.1:{port}"

env = os.environ.copy()
env.update({
    "PATH": str(bin_dir) + os.pathsep + env["PATH"],
    "QBT_FIXTURE_PORT": str(port),
    "QBT_FIXTURE_LOG": str(log),
    "QBT_FIXTURE_SID_FILE": str(sid_file),
    "QBT_FIXTURE_FORBIDDEN_FILE": str(forbidden_file),
    "QBT_FIXTURE_LOGIN_BANNED_FILE": str(login_banned_file),
    "QBT_SECRET_LOG": str(secret_log),
    "QBT_STATE_DIR": str(state_dir),
    "QBT_BASE": base + "/",
    "QBT_USERNAME": "admin",
})

server = subprocess.Popen(["python3", "tests/fixtures/server.py"], env=env)
try:
    for _ in range(100):
        try:
            urllib.request.urlopen(base + "/health", timeout=0.1).read()
            break
        except Exception:
            time.sleep(0.03)
    else:
        raise AssertionError("fixture server did not start")
    if log.exists():
        log.unlink()

    def qbt(*args, extra_env=None):
        run_env = env.copy()
        if extra_env:
            run_env.update(extra_env)
        return subprocess.run(["./qbt", *args], env=run_env, text=True, capture_output=True)

    def requests():
        return json.loads(log.read_text() or "[]") if log.exists() else []

    def secret_calls():
        return secret_log.read_text().splitlines() if secret_log.exists() else []

    # Explicit options override environment values; URL normalization removes the slash.
    first = qbt("--base-url", base + "/", "--username", "admin", "status",
                extra_env={"QBT_BASE": "http://203.0.113.50", "QBT_USERNAME": "wrong"})
    assert first.returncode == 0, first.stderr
    data = json.loads(first.stdout)
    assert data == {
        **data,
        "api": True,
        "error": "",
        "altSpeed": True,
        "dlSpeed": 2202009,
        "upSpeed": 143360,
    }, (data, first.stderr)
    assert len(data["torrents"]) == 2
    debian = next(row for row in data["torrents"] if row["name"] == "debian.iso")
    assert debian["savePath"] == "/home/user/Downloads"
    assert debian["contentPath"] == "/home/user/Downloads/debian.iso"
    assert debian["dlLimit"] == 1048576
    assert debian["upLimit"] == 0
    assert debian["seqDl"] is True
    assert debian["ratioLimit"] == -2
    assert len(secret_calls()) == 1
    reqs = requests()
    assert [r["path"] for r in reqs].count("/api/v2/auth/login") == 1
    assert any(r["path"] == "/api/v2/sync/maindata" and not r["authorized"] for r in reqs)
    assert any(r["path"] == "/api/v2/sync/maindata" and r["authorized"] for r in reqs)
    assert all(r["referer"] == base + "/" for r in reqs)

    key = hashlib.sha256((base + "\0admin").encode()).hexdigest()
    connection = state_dir / "connections" / key
    cookie_file = connection / "cookies.txt"
    rid_file = connection / "rid.json"
    assert cookie_file.is_file() and rid_file.is_file()
    assert stat.S_IMODE(connection.stat().st_mode) == 0o700
    assert stat.S_IMODE(cookie_file.stat().st_mode) == 0o600
    assert stat.S_IMODE(rid_file.stat().st_mode) == 0o600

    # A second process reuses SID and RID without touching Secret Service or login.
    before = len(requests())
    second = qbt("status")
    assert second.returncode == 0, second.stderr
    data2 = json.loads(second.stdout)
    assert data2["api"] is True
    assert data2["dlSpeed"] == 100
    assert {row["name"] for row in data2["torrents"]} == {"debian.iso"}
    assert data2["torrents"][0]["savePath"] == "/home/user/Downloads"
    assert len(secret_calls()) == 1
    later = requests()[before:]
    assert not any(r["path"] == "/api/v2/auth/login" for r in later)
    assert all(r["authorized"] for r in later)

    # An expired cookie causes one login and one replay, never a retry loop.
    sid_file.write_text("fixture-session-two")
    before = len(requests())
    expired = qbt("status")
    assert expired.returncode == 0, expired.stderr
    assert json.loads(expired.stdout)["api"] is True
    expired_reqs = requests()[before:]
    assert [r["path"] for r in expired_reqs].count("/api/v2/auth/login") == 1
    sync_reqs = [r for r in expired_reqs if r["path"] == "/api/v2/sync/maindata"]
    assert len(sync_reqs) == 2
    assert sync_reqs[0]["authorized"] is False and sync_reqs[1]["authorized"] is True
    assert len(secret_calls()) == 2

    # Every remote-safe mutation remains available through the authenticated API.
    torrent_dir = Path(tempfile.mkdtemp(prefix="qbt-upload-"))
    torrent_file = torrent_dir / "upload me.torrent"
    torrent_file.write_bytes(b"d8:announce4:teste")
    commands = [
        ("add", "magnet:?xt=urn:btih:abc"),
        ("add", "file://" + str(torrent_file)),
        ("add", "--stopped", "--savepath", "/remote/downloads", "--category", "linux", "magnet:?xt=urn:btih:def"),
        ("start", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        ("stop", "all"),
        ("delete", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        ("delete", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--files"),
        ("prio", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "1", "0"),
        ("turtle",),
        ("limit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "dl", "1048576"),
        ("limit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "up", "262144"),
        ("sequential", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        ("sharelimit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "1"),
    ]
    for command in commands:
        result = qbt(*command)
        assert result.returncode == 0, (command, result.stderr)
    files = qbt("files", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert files.returncode == 0, files.stderr
    assert json.loads(files.stdout)[0]["name"] == "debian.iso"
    missing_file = qbt("add", "/no/such/file.torrent")
    assert missing_file.returncode != 0
    bad_limit = qbt("limit", "all", "sideways", "1")
    assert bad_limit.returncode != 0

    reqs = requests()
    posts = [r["path"] for r in reqs if r["method"] == "POST" and r["authorized"]]
    for path in (
        "/api/v2/torrents/add", "/api/v2/torrents/start", "/api/v2/torrents/stop",
        "/api/v2/torrents/delete", "/api/v2/torrents/filePrio",
        "/api/v2/transfer/toggleSpeedLimitsMode", "/api/v2/torrents/setDownloadLimit",
        "/api/v2/torrents/setUploadLimit", "/api/v2/torrents/toggleSequentialDownload",
        "/api/v2/torrents/setShareLimits",
    ):
        assert path in posts, path
    bodies = " ".join(r["body"] for r in reqs if r["method"] == "POST" and r["authorized"])
    assert "deleteFiles=true" in bodies and "deleteFiles=false" in bodies
    assert "hashes=all" in bodies
    assert 'name="torrents"' in bodies and 'filename="upload me.torrent"' in bodies
    assert "stopped=true" in bodies and "savepath=%2Fremote%2Fdownloads" in bodies
    assert "ratioLimit=1" in bodies and "seedingTimeLimit=-2" in bodies
    assert "/api/v2/torrents/pause" not in posts and "/api/v2/torrents/resume" not in posts

    # Multipart input is replayable after an authentication refresh and accepted once.
    sid_file.write_text("fixture-session-three")
    before = len(requests())
    replayed_upload = qbt("add", str(torrent_file))
    assert replayed_upload.returncode == 0, replayed_upload.stderr
    upload_reqs = requests()[before:]
    add_reqs = [r for r in upload_reqs if r["path"] == "/api/v2/torrents/add"]
    assert len(add_reqs) == 2
    assert add_reqs[0]["authorized"] is False and add_reqs[1]["authorized"] is True
    assert all('filename="upload me.torrent"' in r["body"] for r in add_reqs)
    assert [r["path"] for r in upload_reqs].count("/api/v2/auth/login") == 1

    # Endpoint and username select isolated cookie/RID directories.
    before_logins = [r["path"] for r in requests()].count("/api/v2/auth/login")
    localhost_base = f"http://localhost:{port}"
    isolated = qbt("--base-url", localhost_base, "--username", "admin", "status")
    assert isolated.returncode == 0 and json.loads(isolated.stdout)["api"] is True, isolated.stderr
    assert [r["path"] for r in requests()].count("/api/v2/auth/login") == before_logins + 1
    other_key = hashlib.sha256((localhost_base + "\0admin").encode()).hexdigest()
    assert other_key != key
    assert (state_dir / "connections" / other_key / "cookies.txt").is_file()

    # Missing and rejected credentials are distinct, parseable status failures.
    login_count = lambda: [r["path"] for r in requests()].count("/api/v2/auth/login")
    before_missing_logins = login_count()
    missing = qbt("--username", "missing", "status", extra_env={"QBT_STUB_MISSING": "1"})
    assert missing.returncode == 0
    missing_data = json.loads(missing.stdout)
    assert missing_data["api"] is False
    assert "no Secret Service password" in missing_data["error"]
    assert login_count() == before_missing_logins
    wrong = qbt("--username", "wrong", "status", extra_env={"QBT_STUB_WRONG": "1"})
    assert wrong.returncode == 0
    wrong_data = json.loads(wrong.stdout)
    assert wrong_data["api"] is False
    assert "rejected the stored credentials" in wrong_data["error"]
    assert login_count() == before_missing_logins + 1
    no_username = qbt("--username", "", "status")
    assert no_username.returncode == 0
    assert "no username" in json.loads(no_username.stdout)["error"]
    assert login_count() == before_missing_logins + 1
    combined = missing.stdout + missing.stderr + wrong.stdout + wrong.stderr + no_username.stdout + no_username.stderr
    assert "fixture-password" not in combined
    assert "fixture-session" not in combined
    assert "leaked-secret-value" not in combined

    # qBittorrent defines login HTTP 403 as a temporary client-IP ban.
    sid_file.write_text("fixture-session-four")
    login_banned_file.touch()
    before = len(requests())
    banned = qbt("status")
    assert banned.returncode == 0
    banned_data = json.loads(banned.stdout)
    assert banned_data["api"] is False
    assert "client IP is banned" in banned_data["error"]
    banned_reqs = requests()[before:]
    assert [r["path"] for r in banned_reqs].count("/api/v2/auth/login") == 1
    assert "fixture-password" not in banned.stdout + banned.stderr
    login_banned_file.unlink()

    # A protected route that remains forbidden is sanitized after one refresh.
    forbidden_file.touch()
    before = len(requests())
    blocked = qbt("status")
    assert blocked.returncode == 0
    blocked_data = json.loads(blocked.stdout)
    assert blocked_data["api"] is False
    assert "rejected after login" in blocked_data["error"]
    blocked_reqs = requests()[before:]
    assert [r["path"] for r in blocked_reqs].count("/api/v2/auth/login") == 1
    blocked_output = blocked.stdout + blocked.stderr
    assert "leaked-secret-value" not in blocked_output
    assert "leaked-password" not in blocked_output
    assert "fixture-session" not in blocked_output
    forbidden_file.unlink()

    # Invalid URLs fail before curl or Secret Service. Cover every rejected component.
    invalid_urls = [
        "http://203.0.113.50:8080",
        "ftp://localhost:21",
        "http://user:secret@localhost:8080",
        "http://localhost:8080?x=1",
        "http://localhost:8080#frag",
        "http:///missing-host",
        "http://localhost:8080/ok\nheader",
    ]
    request_count = len(requests())
    secret_count = len(secret_calls())
    for invalid_url in invalid_urls:
        invalid = qbt("--base-url", invalid_url, "status")
        assert invalid.returncode != 0, invalid_url
        assert "invalid base URL" in invalid.stderr
    assert len(requests()) == request_count
    assert len(secret_calls()) == secret_count

    # HTTPS transport failures remain a parseable status; actions fail nonzero.
    transport = qbt("--base-url", "https://127.0.0.1:1", "--username", "admin", "status")
    assert transport.returncode == 0
    transport_data = json.loads(transport.stdout)
    assert transport_data["api"] is False
    assert "TLS or transport failure" in transport_data["error"]
    transport_action = qbt("--base-url", "https://127.0.0.1:1", "--username", "admin", "start", "all")
    assert transport_action.returncode != 0


    # State-directory symlinks are rejected before network access.
    real_state = tmp / "real-state"
    real_state.mkdir()
    linked_state = tmp / "linked-state"
    linked_state.symlink_to(real_state, target_is_directory=True)
    symlinked = qbt("status", extra_env={"QBT_STATE_DIR": str(linked_state)})
    assert symlinked.returncode != 0
    assert "refusing symlinked state dir" in symlinked.stderr
finally:
    server.terminate()
    server.wait(timeout=5)
    shutil.rmtree(tmp, ignore_errors=True)

print("api-contract ok")
PY
