# Notesnook Sync Server — Garage S3 Edition

Self-hosted Notesnook sync server with [Garage](https://garagehq.io/) as the S3
storage backend. Fork of [streetwriters/notesnook-sync-server](https://github.com/streetwriters/notesnook-sync-server)
(based on the [Dvalin21](https://github.com/Dvalin21/notesnook-sync-server) variant).

**This version uses Garage instead of MinIO.** If you want MinIO, use the MinIO
version of this repo instead.

## What's different from the MinIO version

| | MinIO version | Garage version |
|---|---|---|
| S3 backend | MinIO container | Garage container |
| S3 console URL | `minio.<domain>` | `garage.<domain>` |
| S3 API URL (app uses this) | `attach.<domain>` | `attach.<domain>` (same) |
| MinIO container | Yes | No (saves resources) |
| Caddy `S3_BACKEND` default | `notesnook-s3:9000` | `garage:3900` |
| Caddy `S3_CONSOLE_BACKEND` default | `notesnook-s3:9090` | `garage:3900` |

## Prerequisites

- **Docker** + **Docker Compose v2**
- **Domain with DNS control** (e.g. `keithtechco.com`)
- **TLS reverse proxy** (Nginx Proxy Manager, Caddy, nginx, etc.) —
  this stack does **not** handle TLS itself
- **SMTP server** (optional — for email 2FA / password reset)
- **Garage RPC secret** (generated below)

## Architecture

### Single port model

By design, this stack publishes **one port** externally: host `:8080`.

```
Host :8080  →  Caddy :80  →  routes by Host header to correct backend
```

Internal ports `5264` / `8264` / `7264` / `3000` / `3900` are **NOT** exposed
to the host or to clients. They're only reachable inside the Docker network.
This is a security hardening over the upstream stack.

### .env / subdomain mapping table

| Variable | Client field | Caddy `Host:` | Internal target |
|---|---|---|---|
| `NOTESNOOK_APP_PUBLIC_URL` | Sync URL | `sync.example.com` | `notesnook-server:5264` |
| `AUTH_SERVER_PUBLIC_URL` | Auth URL | `auth.example.com` | `identity-server:8264` |
| `MONOGRAPH_PUBLIC_URL` | Web URL | `notes.example.com` | `monograph-server:3000` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Attachments URL | `attach.example.com` | `garage:3900` |

Never mix these up. The Android client uses the first three exactly as shown
above. The web client uses `MONOGRAPH_PUBLIC_URL`.

### Caddy internal routing

| Host header | Routes to |
|---|---|
| `sync.example.com` | `notesnook-server:5264` |
| `auth.example.com` | `identity-server:8264` |
| `sse.example.com` | `sse-server:7264` |
| `notes.example.com` | `monograph-server:3000` |
| `attach.example.com` | `garage:3900` (S3 API) |
| `garage.example.com` | `garage:3900` (S3 console UI) |
| `cors.example.com` | `cors-proxy:3000` |

---

## Setup

### 1. Clone

```bash
git clone https://github.com/Dvalin21/notesnook-sync-server-garage.git
cd notesnook-sync-server-garage
```

### 2. Create `.env` from the template

```bash
cp .env.example .env
nano .env
```

Every `CHANGEME-*` value must be replaced. Here is every field explained:

| Variable | Required in compose? | Notes |
|---|---|---|
| `SERVER_DOMAIN` | Yes — required by `validate` service + Caddy `{$DOMAIN}` templating | Your domain, e.g. `example.com` |
| `INSTANCE_NAME` | Yes — required by `validate` service | Human name for this instance |
| `NOTESNOOK_API_SECRET` | Yes — required by `validate` service + identity server | Generate with `openssl rand -base64 48` |
| `DISABLE_SIGNUPS` | Yes — required by `validate` service | `false` to allow signups, `true` to lock down |
| `NOTESNOOK_APP_PUBLIC_URL` | Yes — required by `validate` service | `https://sync.example.com` |
| `AUTH_SERVER_PUBLIC_URL` | Yes — required by `validate` service | `https://auth.example.com` |
| `MONOGRAPH_PUBLIC_URL` | Yes — required by `validate` service + monograph container | `https://notes.example.com` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Yes — required by `validate` service | `https://attach.example.com` |
| `GARAGE_RPC_SECRET` | Yes — required by Garage container | 32-byte hex. Generate with `openssl rand -hex 32` |
| `GARAGE_ACCESS_KEY_ID` | Yes — required by `setup-garage` service | S3 access key. Generate with `openssl rand -base64 12` |
| `GARAGE_ACCESS_KEY_SECRET` | Yes — required by `setup-garage` service | S3 secret key. Generate with `openssl rand -base64 24` |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | No — optional, warn if missing | Leave blank if not using email features |
| `NOTESNOOK_CORS_ORIGINS` | No — used by `cors-proxy` only | Comma-separated origins, default `*`. Not checked by `validate`; the `cors-proxy` container receives it via env_file. |
| `TWILIO_*` | No — optional, passed to all services | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_SERVICE_SID` for SMS 2FA via `SMSSender`. Leave empty to disable SMS 2FA. |

### 3. Configure your TLS reverse proxy

This stack does **not** handle TLS itself. You need an external proxy that:

1. Terminates TLS for `*.example.com`
2. Forwards all requests to `http://<your-server-ip>:8080`
3. Preserves the original `Host:` header (this is how Caddy routes internally)

**Nginx Proxy Manager (NPM) — recommended:**

1. In NPM, go to **Proxies → Add Proxy Host**
2. Create proxy hosts for each subdomain (or one wildcard — see below)

**Option A — One wildcard proxy host** (simplest):

| Field | Value |
|---|---|
| Domain Name | `*.example.com` (wildcard) |
| Forward Hostname / IP | `<your-server-ip>` |
| Forward Port | `8080` |
| Scheme | `http` |
| Force SSL | On |
| HTTP → HTTPS Redirect | On |
| SSL | Let's Encrypt (or your own cert) |
| Secure | On |
| Block common exploits | On |
| Websockets Support | On |

**Critical:** In the Advanced tab, add this to ensure the Host header is preserved:

```
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

NPM usually preserves the Host header by default, but if Caddy routing breaks
(502 errors), add this explicitly.

**Option B — 7 individual proxy hosts** (if your apex hosts your own website):

Create 7 proxy hosts — one per subdomain — all pointing to
`http://<your-server-ip>:8080`:

1. `auth.example.com`
2. `sync.example.com`
3. `sse.example.com`
4. `notes.example.com`
5. `attach.example.com`
6. `garage.example.com`
7. `cors.example.com`

Leave `example.com` (apex) alone — keep your existing website config.
A wildcard `*.example.com` would also match the apex and send that traffic
to this Caddy (which returns 404), breaking your site.

**If using Caddy as your external proxy:**

```caddy
*.example.com {
    reverse_proxy localhost:8080
}
```

**If using nginx:**

```nginx
server {
    listen 443 ssl;
    server_name *.example.com;
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
    }
}
```

### 4. Start the stack

```bash
docker compose pull
docker compose up -d
```

**Watch the boot:**

```bash
docker compose logs -f
```

What you should see in order:

1. **`validate`** exits with `All required environment variables are set.`
2. **`init-dpdata`** exits with `Setting DataProtection volume permissions... Done.`
3. **`notesnook-db`** starts MongoDB and initiates a replica set
4. **`garage`** starts Garage S3 storage
5. **`setup-garage`** creates the `attachments` bucket, then exits
6. **`identity-server`** starts on port 8264
7. **`notesnook-server`** starts on port 5264
8. **`sse-server`** starts on port 7264
9. **`monograph-server`** starts on port 3000
10. **`cors-proxy`** starts on port 3000
11. **`caddy`** starts routing on port 80 (mapped to host port 8080)

**First boot takes 2–5 minutes.** MongoDB replica set initialization and
.NET DataProtection key generation happen on first startup.

### 5. Verify

Once all services show `(healthy)`, test each subdomain through Caddy on
port 8080. Replace `example.com` with your real `SERVER_DOMAIN`.

```bash
curl -fsS -H "Host: auth.example.com"   http://localhost:8080/.well-known/openid-configuration
curl -fsS -H "Host: sync.example.com"   http://localhost:8080/health
curl -fsS -H "Host: sse.example.com"    http://localhost:8080/health
curl -fsS -H "Host: notes.example.com"  http://localhost:8080/
curl -fsS -H "Host: attach.example.com" http://localhost:8080/
curl -fsS -H "Host: garage.example.com" http://localhost:8080/
curl -fsS -H "Host: cors.example.com"   http://localhost:8080/
```

Each should return `200` (or a valid page/JSON response). Auth, sync, and sse
are API-only services — they don't serve a web page at `/`, so use their
health/OIDC endpoints. Attach and garage route to Garage S3 and return `403`
without credentials — that's expected. Notes (Monograph) and cors return `200`
pages/JSON at `/`.

**Note on root paths:** API servers (auth, sync, sse) don't serve a web page at
`/` — auth uses `/.well-known/openid-configuration`, sync and sse have `/health`.
The CORS proxy (`cors.example.com`) returns JSON at `/`. Garage console and
Monograph serve full web pages at `/`.

### 6. Garage console

Open `https://garage.example.com` in a browser. You'll see the Garage login
page. Log in with:

- **Access key:** value of `GARAGE_ACCESS_KEY_ID` in `.env`
- **Secret key:** value of `GARAGE_ACCESS_KEY_SECRET` in `.env`

You should see the `attachments` bucket created by `setup-garage`.

### 7. Connect clients

**Android app — Server URLs:**

Open the Notesnook app → Settings → Sync → "Use custom server" (or similar).
Enter these exact values:

| Field in app | Value |
|---|---|
| Auth URL / Identity server | `https://auth.example.com` |
| Sync URL / Sync server | `https://sync.example.com` |
| Attachments URL / S3 URL | `https://attach.example.com` |
| Monograph URL (web only) | `https://notes.example.com` |

After entering these, tap **Test connection** (if available), then **Save**.
Then use **Sign up** or **Log in** to create your account.

**Desktop app — Server URLs:**

Settings → Servers → Add custom server. Same URLs as above.

**Web browser:**

Navigate to `https://notes.example.com` for the Monograph web client (read-only
note sharing — no account management).

---

## Test connection from the Android app

After entering the server URLs in the app's custom server settings:

1. Tap **Test connection** or **Verify** (if the app has this button)
2. The app should reach `AUTH_SERVER_PUBLIC_URL` and discover the OIDC metadata
3. Then it should reach `NOTESNOOK_APP_PUBLIC_URL` and confirm the sync endpoint
4. If both succeed, save the configuration
5. Use **Sign up** to create your first account (if `DISABLE_SIGNUPS=false`)

If the test fails:

| Symptom | Likely cause | Fix |
|---|---|---|
| "Cannot reach server" / timeout | URLs are wrong or server not reachable from the device | Verify the URLs resolve from your phone's network. Check that port 8080 is reachable. |
| SSL certificate error | Self-signed cert or wrong domain in URL | Make sure you're using `https://` with a valid certificate for the exact domain. |
| "Invalid server" / "Not a Notesnook server" | The URL points to the wrong service or returns an error | Double-check that `AUTH_SERVER_PUBLIC_URL` points to `auth.example.com` (identity server), not the sync server. |
| Signup fails after successful test | `DISABLE_SIGNUPS=true` or SMTP issue | Set `DISABLE_SIGNUPS=false` temporarily, restart identity-server, try again. |

---

## Garage admin login

- Console URL: **https://garage.example.com** (routed via Caddy)
- S3 API URL: **https://attach.example.com** (used by the Notesnook app)
- Username: value of `GARAGE_ACCESS_KEY_ID` in `.env`
- Password: value of `GARAGE_ACCESS_KEY_SECRET` in `.env`

---

## Maintenance

### Backups

```bash
# MongoDB
docker compose exec notesnook-db mongodump \
  --uri="mongodb://notesnook-db:27017/notesnook" \
  --archive=/backup/notesnook-$(date +%Y%m%d).archive

# Garage attachments (from host)
docker run --rm -v notesnook-sync-server-garage_s3data:/data -v /backup/s3:/backup \
  alpine tar czf /backup/s3/garage-$(date +%Y%m%d).tar.gz -C /data .
```

### Updates

```bash
git pull
docker compose pull
docker compose up -d
```

### Disaster recovery: DataProtection keys

The DataProtection volumes (`dpdata-identity`, `dpdata-notesnook`,
`dpdata-sse`, `dpdata-monograph`) contain encryption keys that the .NET
services use to protect data at rest. If you lose these volumes, users will
be locked out of their data. Back them up along with the database.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `setup-garage` fails with "Garage did not become ready" | Garage container not started or not reachable | Check `docker compose logs garage`. Ensure `GARAGE_RPC_SECRET` is set in `.env`. |
| `setup-garage` fails with "GARAGE_ACCESS_KEY_ID and GARAGE_ACCESS_KEY_SECRET must be set" | Missing S3 credentials | Set `GARAGE_ACCESS_KEY_ID` and `GARAGE_ACCESS_KEY_SECRET` in `.env`. |
| 502 errors from Caddy | Backend service not running or Host header stripped | Check `docker compose ps` — all services should be `(healthy)`. If using NPM, add `proxy_set_header Host $host;` in the Advanced tab. |
| All URLs return Monograph HTML | Caddy routing broken — Host header not reaching Caddy | Ensure your TLS proxy preserves the Host header. With NPM, check the Advanced tab has `proxy_set_header Host $host;`. Restart Caddy: `docker compose restart caddy`. |
| Apex domain returns 404 | Expected — apex is not part of this stack | If your apex hosts a website, do NOT create a proxy host for it in NPM. Use 7 individual subdomain hosts instead of a wildcard. |
| `validate` exits with "Error: Required environment variable X is not set" | Missing required env var | Check `.env` — all variables in the table above marked "Yes" must be set. |

---

## What this fork changed

Compared to the upstream [streetwriters/notesnook-sync-server](https://github.com/streetwriters/notesnook-sync-server):

1. **MongoDB 8.0.28** instead of 7.0.x — same binary, newer version
2. **MinIO pinned to `RELEASE.2025-09-07T16-13-09Z`** — avoids upstream drift
3. **Validation service** — checks required env vars before the stack starts
4. **DataProtection volume persistence** — `init-dpdata` service sets ownership
5. **Healthchecks on all services** — `nc -z` for .NET services, `node` for cors-proxy, `bun` for monograph
6. **Autoheal** — `willfarrell/autoheal` restarts unhealthy containers
7. **Single-port model** — only Caddy exposes port 8080; all other services are internal
8. **Garage S3 backend** — replaces MinIO with Garage for S3-compatible storage

---

## License

Same as upstream — see the upstream repository for license details.
