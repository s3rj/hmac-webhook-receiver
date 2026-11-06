#!/usr/bin/env bash
# Send a signed "contact.unsubscribed" delivery to the Demo source of an org, using the CLI's session.
# Usage: scripts/send-demo.sh <org alias> <shared secret> [email]
# The secret must match the Webhook Secret custom setting record named "Demo" in the org.
set -euo pipefail
ORG="${1:?usage: scripts/send-demo.sh <org alias> <shared secret> [email]}"
SECRET="${2:?shared secret}"
EMAIL="${3:-someone@example.com}"

# Newer CLIs hide the token in `sf org display`; `sf org auth show-access-token` is the supported way to read it.
read -r TOKEN INSTANCE < <(python3 - "$ORG" <<'EOF'
import json, subprocess, sys
org = sys.argv[1]

def sf(*args):
    completed = subprocess.run(['sf', *args, '--target-org', org, '--json'], capture_output=True, text=True)
    return json.loads(completed.stdout)

display = sf('org', 'display')['result']
token = display.get('accessToken') or ''
if not token or ' ' in token:
    token = sf('org', 'auth', 'show-access-token')['result']['accessToken']
print(token, display['instanceUrl'].rstrip('/'))
EOF
)
TS="$(date +%s)"
BODY="{\"id\":\"evt_$TS\",\"type\":\"contact.unsubscribed\",\"email\":\"$EMAIL\"}"
SIG="$(printf '%s.%s' "$TS" "$BODY" | SECRET="$SECRET" python3 -c 'import hmac,hashlib,os,sys; print(hmac.new(os.environ["SECRET"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())')"

curl -sS -X POST "$INSTANCE/services/apexrest/webhooks/v1/demo" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Timestamp: $TS" \
  -H "X-Signature: $SIG" \
  --data "$BODY"
echo
