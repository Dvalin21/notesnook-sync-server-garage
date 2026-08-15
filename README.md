# Notesnook Sync Server — Garage S3 Edition

Self-hosted Notesnook sync server with [Garage](https://garagehq.io/) as the S3
storage backend. Fork of [streetwriters/notesnook-sync-server](https://github.com/streetwriters/notesnook-sync-server)
(based on the [Dvalin21](https://github.com/Dvalin21/notesnook-sync-server) variant).

**This version uses Garage as the S3 backend.** No MinIO container — Garage provides
S3-compatible storage with a built-in web console.

## What's different from the MinIO version

| | MinIO version | Garage version |
|---|---|---|
| S3 backend | MinIO container | Garage container |
| S3 console URL | `minio.<domain>` | `garage.<domain>` |
| S3 API URL (app uses this) | `attach.<domain>` | `attach.<domain>` (same) |
| MinIO container | Yes | No (saves resources) |
| Caddy `S3_BACKEND` default | `notesnook-s3:9000` | `garage:3900` |
| Caddy `S3_CONSOLE_BACKEND` default | `notesnook-s3:9090` | `garage:3900` |

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

Fill in all the required values (see `.env.example` for placeholders and the
table below for what each variable does). At minimum you MUST set:

- `NOTESNOOK_API_SECRET` — random secret for token signing
- `GARAGE_RPC_SECRET` — 32-byte hex for Garage RPC encryption
- `GARAGE_ACCESS_KEY_ID` — S3 access key
- `GARAGE_ACCESS_KEY_SECRET` — S3 secret key
- `SERVER_DOMAIN` — your domain (e.g. `example.com`)

### 3. Create the S3 bucket (first run only)

The `setup-garage` service in the compose file creates the `attachments` bucket
automatically on first boot. It uses the credentials from your `.env`. If you
ever need to run it manually:

```bash
docker compose run --rm setup-garage
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
health/OIDC endpoints. Attach routes to Garage S3 and returns `403` without
credentials — that's expected. Garage's web console (`garage.example.com`)
runs on port 3902 internally and returns the web UI. Cors returns `200` JSON
at `/`. Notes (Monograph) serves a full web page at `/`.

**Note on root paths:** API servers (auth, sync, sse) don't serve a web page at
`/` — auth uses `/.well-known/openid-configuration`, sync and sse have `/health`.
Monograph serves the full web client. Cors is a JSON API. Attach and garage are
S3 endpoints that require auth (403 without credentials).

### 6. Configure Nginx Proxy Manager (or your TLS proxy)

The stack only exposes port 8080 on the host. You need a TLS proxy in front of it
to serve HTTPS. Nginx Proxy Manager (NPM) is the recommended option.

**Prerequisites:**

- NPM installed and reachable from the internet
- DNS records for all subdomains pointing to your server's public IP

**DNS records needed (7 subdomains + apex if you want):**

| Host | Type | Value |
|---|---|---|
| `auth.example.com` | A / CNAME | your server IP |
| `sync.example.com` | A / CNAME | your server IP |
| `sse.example.com` | A / CNAME | your server IP |
| `notes.example.com` | A / CNAME | your server IP |
| `attach.example.com` | A / CNAME | your server IP |
| `garage.example.com` | A / CNAME | your server IP |
| `cors.example.com` | A / CNAME | your server IP |

**Apex domain:** If `example.com` already hosts a website on a different
server, do NOT create a proxy host for it. Leave it alone. The 7 subdomains
above are all that this stack needs.

**NPM proxy hosts (create 7, one per subdomain):**

For each subdomain (`auth.`, `sync.`, `sse.`, `notes.`, `attach.`, `garage.`, `cors.`):

1. **Proxy Host** → **Add Proxy Host**
2. **Details tab:**
   - Domain Name: `auth.example.com` (etc.)
   - Scheme: `http`
   - Forward Host: `<your-server-ip>`
   - Forward Port: `8080`
   - Cache: off
   - Block common exploits: on (optional)
3. **SSL tab:** Request a new certificate (Let's Encrypt) for each subdomain,
   enable force HTTPS.
4. **Advanced tab** (important — copy this into each proxy host):

```
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

The `proxy_set_header Host $host;` line is critical — it preserves the original
Host header so Caddy can route by subdomain. Without it, all requests reach Caddy
with the same Host (your server IP) and routing breaks.

**Alternative: wildcard certificate + single proxy host**

If you have a wildcard certificate (`*.example.com`), you can create a single
NPM proxy host with `*.example.com` → `http://<ip>:8080`. Then all 7
subdomains share one SSL cert. But you still need the 7 DNS A records.

**Caddy internal routing (for reference):**

| Host header | Routes to |
|---|---|
| `sync.example.com` | `notesnook-server:5264` |
| `auth.example.com` | `identity-server:8264` |
| `sse.example.com` | `sse-server:7264` |
| `notes.example.com` | `monograph-server:3000` |
| `attach.example.com` | `garage:3900` (S3 API) |
| `garage.example.com` | `garage:3902` (S3 console UI) |
| `cors.example.com` | `cors-proxy:3000` |

---

## Environment variables

### Required

| Variable | Required | Used by | Description |
|---|---|---|---|
| `SERVER_DOMAIN` | Yes — Caddy routing | caddy | Your domain (e.g. `example.com`). Used for Host header matching. |
| `INSTANCE_NAME` | Yes | validate, identity-server | Display name for your Notesnook server. |
| `NOTESNOOK_API_SECRET` | Yes | validate, identity-server, notesnook-server | API auth token secret. Generate with `openssl rand -base64 48`. |
| `DISABLE_SIGNUPS` | Yes | identity-server | `true` = no new accounts. Set to `false` temporarily to create your first account, then set back to `true`. |
| `AUTH_SERVER_PUBLIC_URL` | Yes | Android app, web client | Public URL for the auth server. Must be `https://auth.<SERVER_DOMAIN>`. |
| `NOTESNOOK_APP_PUBLIC_URL` | Yes | Android app | Public URL for the sync server. Must be `https://sync.<SERVER_DOMAIN>`. |
| `MONOGRAPH_PUBLIC_URL` | Yes | Web client | Public URL for the Monograph web client. Must be `https://notes.<SERVER_DOMAIN>`. |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Yes | Android app | Public URL for S3 attachments. Must be `https://attach.<SERVER_DOMAIN>`. |
| `GARAGE_RPC_SECRET` | Yes — Garage | garage | 32-byte hex for Garage RPC encryption. Generate with `openssl rand -hex 32`. |
| `GARAGE_ACCESS_KEY_ID` | Yes — setup-garage | setup-garage, notesnook-server | S3 access key ID. Generate with `openssl rand -base64 12`. |
| `GARAGE_ACCESS_KEY_SECRET` | Yes — setup-garage | setup-garage, notesnook-server | S3 secret access key. Generate with `openssl rand -base64 24`. |

### Optional

| Variable | Required | Used by | Description |
|---|---|---|---|
| `SMTP_HOST` | No | validate (warn if missing) | SMTP server hostname. |
| `SMTP_PORT` | No | validate (warn if missing) | SMTP server port. |
| `SMTP_USERNAME` | No | validate (warn if missing) | SMTP username. |
| `SMTP_PASSWORD` | No | validate (warn if missing) | SMTP password. |
| `SMTP_FROM_NAME` | No | identity-server | Name shown in SMTP-sent emails. Default: `Notesnook`. |
| `NOTESNOOK_CORS_ORIGINS` | No | cors-proxy | Comma-separated list of allowed CORS origins. Default: `*`. |
| `TWILIO_ACCOUNT_SID` | No | identity-server | Twilio account SID for SMS 2FA. |
| `TWILIO_AUTH_TOKEN` | No | identity-server | Twilio auth token for SMS 2FA. |
| `TWILIO_SERVICE_SID` | No | identity-server | Twilio service SID for SMS 2FA. |

---

## Adding Garage to an existing MinIO base stack

If you already have the MinIO version of this stack running and want to
switch to Garage, use the overlay compose file:

```bash
docker compose -f docker-compose.yml -f docker-compose.garage/docker-compose.garage.yml up -d
```

The overlay:
- Replaces the `notesnook-s3` MinIO service with `garage`
- Overrides `setup-s3` with `setup-garage` (python3 SigV4)
- Overrides Caddy environment variables to point `S3_BACKEND` and `S3_CONSOLE_BACKEND` at `garage:3900`
- Adds `garage` to the `notesnook` network

See `docker-compose.garage/README.md` in this repo for details.

---

## Usage

### First account

1. Set `DISABLE_SIGNUPS=false` in `.env`
2. Restart: `docker compose restart identity-server`
3. Open `https://sync.example.com` in a browser (or use the Notesnook Android app)
4. Create your account
5. Set `DISABLE_SIGNUPS=true` in `.env`
6. Restart: `docker compose restart identity-server`

### Android app configuration

In the Notesnook Android app, go to Settings → Sync → Custom server and enter:

| Field | Value |
|---|---|
| Server URL | `https://auth.example.com` |
| Sync URL | `https://sync.example.com` |
| Attachments URL | `https://attach.example.com` |

The app uses `AUTH_SERVER_PUBLIC_URL` for OIDC discovery (login/OAuth) and
`NOTESNOOK_APP_PUBLIC_URL` for note sync. `ATTACHMENTS_SERVER_PUBLIC_URL` is
used for uploading/downloading attachments.

### Web client

Open `https://notes.example.com` in a browser. Log in with your account.

### Garage S3 console

Open `https://garage.example.com` in a browser. Log in with the
`GARAGE_ACCESS_KEY_ID` / `GARAGE_ACCESS_KEY_SECRET` from your `.env` to
browse buckets and manage objects.

### S3 attachments API

The Notesnook app uses `https://attach.example.com` for S3 operations.
It authenticates with the `GARAGE_ACCESS_KEY_ID` / `GARAGE_ACCESS_KEY_SECRET`
credentials. You don't need to do anything special — the app handles this
automatically once the URLs are configured.

---

## Testing

### From the host

```bash
# Auth — OIDC discovery
curl -fsS -H "Host: auth.example.com" http://localhost:8080/.well-known/openid-configuration

# Sync — health
curl -fsS -H "Host: sync.example.com" http://localhost:8080/health

# SSE — health
curl -fsS -H "Host: sse.example.com" http://localhost:8080/health

# Monograph — web client HTML
curl -fsS -H "Host: notes.example.com" http://localhost:8080/

# Attach — S3 API (403 without auth = correct)
curl -fsS -H "Host: attach.example.com" http://localhost:8080/

# Garage — S3 console (403 without auth = correct)
curl -fsS -H "Host: garage.example.com" http://localhost:8080/

# Cors — CORS proxy JSON
curl -fsS -H "Host: cors.example.com" http://localhost:8080/
```

### From another machine (through NPM)

Replace `localhost:8080` with `https://auth.example.com` (etc.) and test
the HTTPS endpoints. Make sure DNS resolves and the NPM proxy hosts are
configured with `proxy_set_header Host $host;`.

---

## Garage management

### Create a bucket manually

```bash
docker run --rm \
  -e GARAGE_ACCESS_KEY_ID="your-key" \
  -e GARAGE_ACCESS_KEY_SECRET="your-secret" \
  -e GARAGE_HOST=garage \
  -e GARAGE_S3_PORT=3900 \
  --network notesnook-sync-server-garage_notesnook \
  python:3.12-slim python3 -c "
import os, sys
sys.path.insert(0, '/scripts')
from setup_garage import create_bucket
create_bucket(os.environ.get('GARAGE_HOST', 'garage'),
              int(os.environ.get('GARAGE_S3_PORT', '3900')),
              os.environ['GARAGE_ACCESS_KEY_ID'],
              os.environ['GARAGE_ACCESS_KEY_SECRET'],
              'my-new-bucket')
"
```

Or use the Garage web console at `https://garage.example.com`.

### Access the Garage admin API

Garage exposes an admin API on port 3903:

```bash
curl -s http://localhost:3903/cluster
```

### Backup Garage data

```bash
# Garage data (from host)
docker run --rm -v notesnook-sync-server-garage_s3data:/data -v /backup/s3:/backup \
  alpine tar czf /backup/s3/garage-$(date +%Y%m%d).tar.gz -C /data .

# Garage metadata (from host)
docker run --rm -v notesnook-sync-server-garage_garage-meta:/data -v /backup/meta:/backup \
  alpine tar czf /backup/meta/garage-meta-$(date +%Y%m%d).tar.gz -C /data .
```

### Restore Garage data

```bash
# Stop the stack
docker compose down

# Remove existing data volumes
docker volume rm notesnook-sync-server-garage_s3data
docker volume rm notesnook-sync-server-garage_garage-meta

# Create fresh volumes and restore
docker volume create notesnook-sync-server-garage_s3data
docker volume create notesnook-sync-server-garage_garage-meta

docker run --rm -v notesnook-sync-server-garage_s3data:/data -v /backup/s3:/backup \
  alpine tar xzf /backup/s3/garage-20260815.tar.gz -C /data

docker run --rm -v notesnook-sync-server-garage_garage-meta:/data -v /backup/meta:/backup \
  alpine tar xzf /backup/meta/garage-meta-20260815.tar.gz -C /data

# Restart
docker compose up -d
```

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
2. **Validation service** — checks required env vars before the stack starts
3. **DataProtection volume persistence** — `init-dpdata` service sets ownership
4. **Healthchecks on all services** — `nc -z` for .NET services, `node` for cors-proxy, `bun` for monograph
5. **Autoheal** — `willfarrell/autoheal` restarts unhealthy containers
6. **Single-port model** — only Caddy exposes port 8080; all other services are internal
7. **Garage S3 backend** — Garage provides S3-compatible storage with a built-in web console

---

## License

Same as upstream — see the upstream repository for license details.
