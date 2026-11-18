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
echo " 🏴‍☠️ Injecting Chained Boundary Troubleshooting Scenario "
echo "=========================================================="

echo "==> [1/2] Injecting Issue B: Target Port Drift (Setting default-port to 22)..."
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 22 \
  -session-connection-limit -1 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

echo "==> [2/2] Injecting Issue A: Setting Concurrency Cap to 1 & Creating Ghost Session..."
# Set limit to 1
boundary targets update ssh \
  -id "$TARGET_ID" \
  -session-connection-limit 1 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

# Spawn a session and abruptly kill the client process to leave it in 'active' state
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none >/dev/null 2>&1 &
BG_PID=$!
sleep 2
kill -9 "$BG_PID" 2>/dev/null || true

echo ""
echo "=========================================================="
echo " 🏴‍☠️ SCENARIO READY! Hand over ticket to the team."
echo ""
echo " Ticket Description:"
echo "   'Developers cannot connect to production SSH target ($TARGET_ID).'"
echo "   'Command to test: boundary connect ssh -target-id $TARGET_ID'"
echo "   'Please investigate, identify all root causes, and restore access!'"
echo "=========================================================="
