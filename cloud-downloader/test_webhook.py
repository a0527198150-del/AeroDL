"""Unit tests for webhook authorization and URL validation (no real downloads)."""
import hashlib
import hmac
import json
import os
from urllib.parse import urlencode
import unittest

os.environ["GITHUB_WEBHOOK_SECRET"] = "a-long-test-secret"
os.environ["GITHUB_REPO"] = "a0527198150-del/AeroDL"
os.environ["GITHUB_ALLOWED_USER"] = "a0527198150-del"

from fastapi.testclient import TestClient
import main


class FakeQueue:
    def __init__(self):
        self.items = []
    def put_nowait(self, item):
        self.items.append(item)
    def qsize(self):
        return len(self.items)


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        main.jobs = FakeQueue()
        main._seen.clear()

    def send(self, obj, signature=True, event="issues"):
        body = json.dumps(obj).encode("utf8")
        headers = {"X-GitHub-Event": event, "Content-Type": "application/json"}
        if signature:
            headers["X-Hub-Signature-256"] = "sha256=" + hmac.new(
                b"a-long-test-secret", body, hashlib.sha256
            ).hexdigest()
        return self.client.post("/github/webhook", content=body, headers=headers)

    def payload(self, url="https://www.youtube.com/watch?v=sample"):
        return {
            "action": "opened",
            "repository": {"full_name": "a0527198150-del/AeroDL"},
            "issue": {
                "number": 42,
                "title": "[download] authorized test",
                "body": "Download URL\n\n" + url,
                "user": {"login": "a0527198150-del"},
            },
        }

    def test_form_encoded_issue_queued(self):
        data = self.payload()
        body = urlencode({"payload": json.dumps(data)}).encode("utf-8")
        sig = "sha256=" + hmac.new(b"a-long-test-secret", body, hashlib.sha256).hexdigest()
        response = self.client.post("/github/webhook", content=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Hub-Signature-256": sig,
            "X-GitHub-Event": "issues",
        })
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["queued"], 42)
        self.assertEqual(len(main.jobs.items), 1)

    def test_form_encoded_missing_payload_rejected(self):
        body = b"wrongfield=hello"
        sig = "sha256=" + hmac.new(b"a-long-test-secret", body, hashlib.sha256).hexdigest()
        response = self.client.post("/github/webhook", content=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Hub-Signature-256": sig,
            "X-GitHub-Event": "issues",
        })
        self.assertEqual(response.status_code, 400)
        self.assertEqual(len(main.jobs.items), 0)

    def test_unsupported_content_type_rejected(self):
        data = self.payload()
        body = json.dumps(data).encode("utf-8")
        sig = "sha256=" + hmac.new(b"a-long-test-secret", body, hashlib.sha256).hexdigest()
        response = self.client.post("/github/webhook", content=body, headers={
            "Content-Type": "text/plain",
            "X-Hub-Signature-256": sig,
            "X-GitHub-Event": "issues",
        })
        self.assertEqual(response.status_code, 415)

    def test_valid_issue_queued(self):
        response = self.send(self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["queued"], 42)
        self.assertEqual(len(main.jobs.items), 1)

    def test_duplicate_issue_only_queued_once(self):
        self.send(self.payload())
        self.send(self.payload())
        self.assertEqual(len(main.jobs.items), 1)

    def test_bad_or_missing_signature_rejected(self):
        self.assertEqual(self.send(self.payload(), signature=False).status_code, 401)
        self.assertEqual(len(main.jobs.items), 0)

    def test_wrong_repo_ignored(self):
        data = self.payload()
        data["repository"]["full_name"] = "someone/else"
        self.assertTrue(self.send(data).json().get("ignored"))
        self.assertEqual(len(main.jobs.items), 0)

    def test_wrong_user_ignored(self):
        data = self.payload()
        data["issue"]["user"]["login"] = "attacker"
        self.assertTrue(self.send(data).json().get("ignored"))
        self.assertEqual(len(main.jobs.items), 0)

    def test_untrusted_host_rejected(self):
        response = self.send(self.payload("https://example.com/audio.mp3"))
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["ok"])
        self.assertEqual(len(main.jobs.items), 0)

    def test_no_playlist_mode_argument(self):
        # This prototype intentionally limits jobs to single audio items.
        self.assertEqual(main.download_url("https://youtu.be/abc"), "https://youtu.be/abc")
        for url in ["https://www.youtube.com.evil.com/watch?v=abc", "http://youtube.com/watch?v=x"]:
            with self.assertRaises(ValueError):
                main.download_url(url)

    def test_invalid_ping_signature_rejected(self):
        self.assertEqual(self.send({"zen": "hi"}, signature=False, event="ping").status_code, 401)


if __name__ == "__main__":
    unittest.main()
