"""GitHub Issues webhook -> yt-dlp -> Google Apps Script -> Drive (prototype)."""
import base64
import hashlib
import hmac
import json
import logging
import os
import queue
import re
import subprocess
import tempfile
import threading
from pathlib import Path
from urllib.parse import urlsplit

import requests
from fastapi import FastAPI, HTTPException, Request

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("aerodl-cloud")
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
jobs = queue.Queue(maxsize=3)
_seen = set()
_seen_lock = threading.Lock()
URL_PATTERN = re.compile(r"https://[^\s<>\]\)]+")
ALLOWED_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}


def download_url(text: str) -> str:
    match = URL_PATTERN.search(text or "")
    if not match:
        raise ValueError("No HTTPS URL found")
    url = match.group(0).rstrip(".,;")
    try:
        parsed = urlsplit(url)
        host = (parsed.hostname or "").lower()
        if (parsed.scheme != "https" or host not in ALLOWED_HOSTS
                or parsed.username or parsed.password or parsed.port is not None):
            raise ValueError("Unsupported URL")
    except ValueError as exc:
        raise ValueError("Invalid or unsupported URL") from exc
    return url


def check_signature(body: bytes, header: str) -> bool:
    secret = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
    if not secret or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(header, expected)


def github_comment(number: int, message: str) -> None:
    token = os.environ.get("GITHUB_NOTIFY_TOKEN")
    repo = os.environ.get("GITHUB_REPO")
    if not token or not repo:
        return
    try:
        response = requests.post(
            f"https://api.github.com/repos/{repo}/issues/{number}/comments",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            json={"body": message},
            timeout=15,
        )
        response.raise_for_status()
    except requests.RequestException:
        log.exception("Unable to write issue status (issue #%s)", number)


def upload_to_drive(path: Path) -> str:
    endpoint = os.environ["APPS_SCRIPT_URL"]
    secret = os.environ["DRIVE_UPLOAD_SECRET"]
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    payload = {"name": path.name, "data": data}
    message = (path.name + "\n" + data).encode("utf-8")
    payload["signature"] = hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()
    response = requests.post(endpoint, json=payload, timeout=(20, 180))
    response.raise_for_status()
    result = response.json()
    if result.get("ok") is not True or not result.get("id"):
        raise RuntimeError("Drive receiver rejected the upload")
    return "https://drive.google.com/file/d/" + result["id"] + "/view"


COOKIE_FILE = Path("/etc/secrets/youtube-cookies.txt")


def build_download_command(output: Path, url: str) -> list[str]:
    """Construct a one-item download, optionally using a Render Secret File.

    The secret file is never read into GitHub/Render logs, environment variables,
    or command-line arguments. Only the path is passed to yt-dlp.
    """
    command = [
        "yt-dlp",
        "--no-playlist",
        "--max-downloads", "1",
        "--max-filesize", "30M",
        "--socket-timeout", "20",
        "--retries", "2",
        "--extract-audio", "--audio-format", "mp3",
        "--audio-quality", "2",
        "--output", str(output / "%(title).120B [%(id)s].%(ext)s"),
    ]
    if COOKIE_FILE.is_file():
        command.extend(["--cookies", str(COOKIE_FILE)])
    return [*command, url]


def process_issue(number: int, url: str) -> None:
    try:
        with tempfile.TemporaryDirectory(prefix="aerodl-") as directory:
            out = Path(directory)
            command = build_download_command(out, url)
            result = subprocess.run(command, capture_output=True, text=True, timeout=480, check=False)
            if result.returncode:
                log.error("Download failed for issue #%s (exit %s): %s",
                          number, result.returncode, result.stderr[-1200:])
                raise RuntimeError("The source could not be downloaded or converted")
            mp3s = list(out.glob("*.mp3"))
            if len(mp3s) != 1:
                raise RuntimeError("Expected one MP3 output")
            maximum = int(os.getenv("MAX_FILE_MB", "12")) * 1024 * 1024
            if not 0 < mp3s[0].stat().st_size <= maximum:
                raise RuntimeError("Output exceeds the configured size limit")
            link = upload_to_drive(mp3s[0])
        github_comment(number, "ההורדה הסתיימה. [פתיחת הקובץ ב-Google Drive](" + link + ")")
        log.info("Completed issue #%s", number)
    except Exception as exc:
        log.exception("Issue #%s failed", number)
        github_comment(number, "ההורדה נכשלה: " + str(exc)[:250])


def worker() -> None:
    while True:
        number, url = jobs.get()
        try:
            process_issue(number, url)
        finally:
            jobs.task_done()


threading.Thread(target=worker, daemon=True, name="download-worker").start()


@app.get("/health")
def health():
    return {"ok": True, "queued": jobs.qsize()}


@app.post("/github/webhook")
async def webhook(request: Request):
    if int(request.headers.get("content-length", "0")) > 131072:
        raise HTTPException(status_code=413, detail="Payload too large")
    body = await request.body()
    if len(body) > 131072:
        raise HTTPException(status_code=413, detail="Payload too large")
    if not check_signature(body, request.headers.get("x-hub-signature-256", "")):
        raise HTTPException(status_code=401, detail="Bad signature")
    event = request.headers.get("x-github-event", "")
    if event == "ping":
        return {"ok": True, "event": "ping"}
    if event != "issues":
        return {"ok": True, "ignored": "event"}
    content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    try:
        if content_type == "application/x-www-form-urlencoded":
            # GitHub's alternate webhook content type wraps JSON as payload=<urlencoded-json>.
            from urllib.parse import parse_qs
            form = parse_qs(body.decode("utf-8"), strict_parsing=True)
            items = form.get("payload", [])
            if len(items) != 1:
                raise ValueError("missing or ambiguous payload form field")
            payload = json.loads(items[0])
        elif content_type == "application/json":
            payload = json.loads(body)
        else:
            raise HTTPException(status_code=415, detail="Unsupported webhook content type")
        if not isinstance(payload, dict):
            raise ValueError("Webhook payload must be a JSON object")
    except (UnicodeDecodeError, ValueError) as exc:
        log.warning("Rejecting malformed GitHub webhook event=%s content_type=%s: %s",
                    event, content_type, str(exc)[:120])
        raise HTTPException(status_code=400, detail="Invalid webhook payload") from exc
    issue = payload.get("issue") or {}
    if (payload.get("action") != "opened"
            or (payload.get("repository") or {}).get("full_name") != os.environ.get("GITHUB_REPO")
            or (issue.get("user") or {}).get("login") != os.environ.get("GITHUB_ALLOWED_USER")
            or not (issue.get("title") or "").lower().startswith("[download]")):
        return {"ok": True, "ignored": "issue"}
    number = issue.get("number")
    if not isinstance(number, int):
        raise HTTPException(status_code=400, detail="Invalid issue number")
    try:
        url = download_url(issue.get("body", ""))
    except ValueError as exc:
        github_comment(number, "כתובת לא נתמכת. כרגע ניתן להשתמש רק בקישורי YouTube ב-HTTPS.")
        return {"ok": False, "reason": str(exc)}
    key = (os.environ["GITHUB_REPO"], number)
    with _seen_lock:
        if key in _seen:
            return {"ok": True, "duplicate": True}
        try:
            jobs.put_nowait((number, url))
        except queue.Full:
            github_comment(number, "תור ההורדות מלא. פתח בקשה חדשה מאוחר יותר.")
            return {"ok": False, "reason": "queue full"}
        _seen.add(key)
    return {"ok": True, "queued": number}
