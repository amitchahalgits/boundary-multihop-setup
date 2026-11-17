#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

if [ -z "$BOUNDARY_TOKEN" ] || [ -z "$TARGET_ID" ] || [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Environment variables not found. Make sure setup.sh has been run and .env exists." >&2
  exit 1
fi

echo "=========================================================="
echo " 🏴‍☠️ Injecting Boundary 3-Stage Treasure Hunt Scenarios "
echo "=========================================================="

echo "==> [1/3] Injecting Bug A: Creating Unbound Alias (destination_id: null)..."
boundary scopes set-alias-suffix -id "$ORG_ID" -alias-suffix "devops" -token env://BOUNDARY_TOKEN -keyring-type=none 2>/dev/null || true
boundary scopes set-alias-suffix -id "$PROJECT_ID" -alias-suffix "infra" -token env://BOUNDARY_TOKEN -keyring-type=none 2>/dev/null || true

# Delete existing alias if present
EXISTING_ALIAS=$(boundary aliases list -scope-id "$PROJECT_ID" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.items[]? | select(.value=="app.infra.devops") | .id' 2>/dev/null || true)
if [ -n "$EXISTING_ALIAS" ]; then
  boundary aliases delete -id "$EXISTING_ALIAS" -token env://BOUNDARY_TOKEN -keyring-type=none
fi

ALIAS_ID=$(boundary aliases create target \
  -scope-id "$PROJECT_ID" \
  -name "prod-ssh-alias" \
  -description "Production OpenSSH Target Alias" \
  -value "app.infra.devops" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none \
  -format=json | jq -r '.item.id')

echo "==> [2/3] Injecting Bug B: Setting Target Port to 22 (Drift) & Concurrency Cap to 1..."
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 22 \
  -session-connection-limit 1 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

echo "==> [3/3] Injecting Bug C: Generating Orphaned Ghost Session in DB..."
# Temporarily bind to trigger an active session
boundary aliases update target -id "$ALIAS_ID" -destination-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
boundary connect ssh app.infra.devops -token env://BOUNDARY_TOKEN -keyring-type=none >/dev/null 2>&1 &
BG_PID=$!
sleep 2
kill -9 "$BG_PID" 2>/dev/null || true

# Re-create the alias as completely unbound
boundary aliases delete -id "$ALIAS_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
ALIAS_ID=$(boundary aliases create target \
  -scope-id "$PROJECT_ID" \
  -name "prod-ssh-alias" \
  -description "Production OpenSSH Target Alias" \
  -value "app.infra.devops" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none \
  -format=json | jq -r '.item.id')

echo ""
echo "=========================================================="
echo " 🏴‍☠️ TREASURE HUNT READY! Hand over ticket to the team."
echo " Ticket Description:"
echo "   'I cannot connect to production SSH using our alias:'"
echo "   'boundary connect ssh app.infra.devops'"
echo "   'Please investigate and fix ASAP!'"
echo "=========================================================="
