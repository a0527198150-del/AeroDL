# AeroDL: GitHub Issues -> Render -> Google Drive

Prototype for processing **a single authorized audio file** per request. GitHub Actions does not download any media. Only an allowed GitHub issue author can trigger a download.

## Restrictions and caveats

- Only public YouTube HTTPS video links; **no playlists**, no cookies, and no arbitrary URLs.
- Maximum output 12 MiB; queue is in memory and is lost on Render restart.
- You must have the right to download and save the source material. Source websites may block downloads from data-center IPs.
- Render free instances can suspend or restart. A signed webhook can be delivered while the service is sleeping; check GitHub webhook deliveries for failures.
- Google Apps Script has execution and request-size limitations. Use a short permitted test file first.
- The current AeroDL repository is **public with Issues disabled**. Enabling Issues exposes request links. A separate private repository is recommended for requests.
- Do **not** commit personal credentials, API keys, tokens or secrets.

## Setup

### 1. Google Drive destination

Create a private folder in your Drive, for example `AeroDL Downloads`. Copy its folder ID from its URL after `/folders/`.

### 2. Google Apps Script receiver

1. Open https://script.google.com and create a new project.
2. Replace `Code.gs` with [drive_receiver.gs](drive_receiver.gs).
3. Open **Project settings -> Script properties** and define:
   - `DRIVE_FOLDER_ID`: folder ID from step 1.
   - `DRIVE_UPLOAD_SECRET`: a long newly generated random secret (at least 32 random bytes).
4. Select **Deploy -> New deployment -> Web app**.
5. Choose **Execute as: Me**, **Who has access: Anyone**; grant Drive permission. Copy the URL ending `/exec`. This publicly reachable endpoint requires an HMAC for upload. Keep the script project and secret private.

### 3. Render deployment

Merge the implementation after review. In Render, create a **Blueprint** from the GitHub repository using `render.yaml`; alternatively configure a Docker Web Service pointing at `cloud-downloader/Dockerfile` with context `cloud-downloader`.

Set these environment variables in Render:

| Variable | Value |
| --- | --- |
| `GITHUB_REPO` | Exact `owner/repo` where requests are opened |
| `GITHUB_ALLOWED_USER` | Exact allowed GitHub username |
| `GITHUB_WEBHOOK_SECRET` | Distinct random secret for GitHub webhook |
| `DRIVE_UPLOAD_SECRET` | Exact same secret as in Google Apps Script |
| `APPS_SCRIPT_URL` | Deployed Google Apps Script `/exec` URL |
| `GITHUB_NOTIFY_TOKEN` | Optional fine-grained PAT with Issues write permission only, to post Drive links in issues |
| `MAX_FILE_MB` | `12` |

If using a **different private request repo**, copy the issue template into that repo and set `GITHUB_REPO` to its full name.

### 4. GitHub webhook

In your request repository enable Issues, then go to **Settings -> Webhooks -> Add webhook**:

- Payload URL: `https://YOUR-SERVICE.onrender.com/github/webhook`
- Content type: `application/json`
- Secret: exactly `GITHUB_WEBHOOK_SECRET`.
- Events: Select individual events -> **Issues** only.
- Keep the webhook active.

GitHub sends a ping on creation. Check **Recent deliveries** for a successful response (HTTP 200).

### 5. End-to-end check

Create a new Issue using the Download to Drive template, using **one short public YouTube audio/video item you have permission to download**. Wait for the file to appear in your private Drive folder. If a notification token is configured, the issue receives a link to the resulting private file (which is accessible only to signed-in people authorized in Drive) or a failure message.

## Security

- Verifies GitHub HMAC-SHA256 signature and exact repository/author.
- Exact HTTPS hostname allowlist, bounded queue, single subprocess, time and size limits.
- Separate HMAC-SHA256 on uploads to Apps Script. No user passwords stored in repository.
- Files removed locally after upload.

## Reliability improvements for later

Use durable queue storage and status updates if this becomes more than a prototype; use direct Google Drive OAuth instead of Apps Script for larger files. Ordinary service accounts do not have a personal Drive storage quota.
