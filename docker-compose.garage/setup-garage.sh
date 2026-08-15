#!/usr/bin/env python3
"""Setup Garage S3 bucket for Notesnook attachments.

AWS SigV4 signing implemented in pure Python — no xxd, no curl needed.
Run once after the garage container starts.

Required env vars:
  GARAGE_ACCESS_KEY_ID     - S3 access key (set in .env)
  GARAGE_ACCESS_KEY_SECRET - S3 secret key (set in .env)

Optional env vars:
  GARAGE_HOST             - default: garage (Docker service name)
  GARAGE_S3_PORT          - default: 3900
  BUCKET_NAME             - default: attachments
"""

import os, sys, hmac, hashlib, datetime, urllib.request, urllib.error, time

garage_host = os.environ.get("GARAGE_HOST", "garage")
garage_port = int(os.environ.get("GARAGE_S3_PORT", "3900"))
bucket_name = os.environ.get("BUCKET_NAME", "attachments")
access_key = os.environ.get("GARAGE_ACCESS_KEY_ID", "")
secret_key = os.environ.get("GARAGE_ACCESS_KEY_SECRET", "")

if not access_key or not secret_key:
    print("ERROR: GARAGE_ACCESS_KEY_ID and GARAGE_ACCESS_KEY_SECRET must be set.", file=sys.stderr)
    sys.exit(1)

print(f"===> Setting up Garage S3 for Notesnook")
print(f"    Host: {garage_host}:{garage_port}")
print(f"    Bucket: {bucket_name}")

# Wait for Garage to be ready
print("===> Waiting for Garage to be ready...")
for i in range(30):
    try:
        req = urllib.request.Request(f"http://{garage_host}:{garage_port}/")
        urllib.request.urlopen(req, timeout=5)
        print("    Garage is ready.")
        break
    except urllib.error.HTTPError:
        print("    Garage is ready.")
        break
    except Exception:
        if i == 29:
            print("    ERROR: Garage did not become ready in 60 seconds.", file=sys.stderr)
            sys.exit(1)
        time.sleep(2)

region = "us-east-1"
service = "s3"
now = datetime.datetime.now(datetime.UTC)
timestamp = now.strftime("%Y%m%dT%H%M%SZ")
date_prefix = now.strftime("%Y%m%d")

canonical_uri = f"/{bucket_name}"
canonical_query = ""
canonical_headers = f"host:{garage_host}:{garage_port}\n"
signed_headers = "host"
canonical_request = (
    f"PUT\n{canonical_uri}\n{canonical_query}\n"
    f"{canonical_headers}{signed_headers}\nUNSIGNED-PAYLOAD"
)

credential_scope = f"{date_prefix}/{region}/{service}/aws4_request"
body_hash = hashlib.sha256(b"").hexdigest().upper()
string_to_sign = (
    f"AWS4-HMAC-SHA256\n{timestamp}\n{credential_scope}\n"
    f"{hashlib.sha256(canonical_request.encode()).hexdigest().upper()}"
)

def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

k_date = sign(f"AWS4{secret_key}".encode(), date_prefix)
k_region = sign(k_date, region)
k_service = sign(k_region, service)
k_signing = sign(k_service, "aws4_request")

signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

auth = (
    f"AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, "
    f"SignedHeaders={signed_headers}, Signature={signature}"
)

url = f"http://{garage_host}:{garage_port}/{bucket_name}"
req = urllib.request.Request(url, method="PUT")
req.add_header("Host", f"{garage_host}:{garage_port}")
req.add_header("x-amz-content-sha256", body_hash)
req.add_header("x-amz-date", timestamp)
req.add_header("Authorization", auth)

try:
    resp = urllib.request.urlopen(req, timeout=10)
    code = resp.getcode()
except urllib.error.HTTPError as e:
    code = e.code
except Exception as e:
    print(f"    ERROR: {e}", file=sys.stderr)
    sys.exit(1)

if code in (200, 409):
    print(f"    Bucket '{bucket_name}' ready (HTTP {code}).")
elif code == 400:
    print(f"    Bucket '{bucket_name}' already exists (HTTP 400 — OK).")
else:
    print(f"    WARNING: Bucket creation returned HTTP {code}.", file=sys.stderr)
    print(f"    The bucket may already exist or there may be a configuration issue.", file=sys.stderr)

print()
print(f"===> Garage setup complete.")
print(f"    Bucket: {bucket_name}")
print(f"    S3 endpoint: http://{garage_host}:{garage_port}")
print()
print(f"Configure your .env with:")
print(f"    ATTACHMENTS_SERVER_PUBLIC_URL=https://attach.<your-domain>")
print(f"    GARAGE_ACCESS_KEY_ID={access_key}")
print(f"    GARAGE_ACCESS_KEY_SECRET=<your-secret>")
