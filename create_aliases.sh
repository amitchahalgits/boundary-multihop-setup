#!/bin/bash
# Automates sections 2.1 (global-scope alias) and 2.2 (project-scope alias)
# of TARGET_ALIAS_TRANSPARENT_SESSIONS_WORKSHOP.md. Safe to re-run: existing
# aliases (matched by value) are skipped.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: $SCRIPT_DIR/.env not found. Run ./setup.sh first." >&2
  exit 1
fi
source "$SCRIPT_DIR/.env"

for v in BOUNDARY_ADDR BOUNDARY_TOKEN ORG_ID PROJECT_ID TARGET_ID HOST_ID; do
  if [ -z "${!v}" ]; then
    echo "ERROR: $v is not set in .env" >&2
    exit 1
  fi
done

# Overridable values
GLOBAL_ALIAS_VALUE="${GLOBAL_ALIAS_VALUE:-ssh-box.boundary.dev}"
ORG_SUFFIX="${ORG_SUFFIX:-devops}"
PROJECT_SUFFIX="${PROJECT_SUFFIX:-core}"
PROJECT_ALIAS_VALUE="${PROJECT_ALIAS_VALUE:-ssh-box.${PROJECT_SUFFIX}.${ORG_SUFFIX}}"

AUTH=(-token env://BOUNDARY_TOKEN -keyring-type=none)

alias_exists() { # <scope-id> <value>
  boundary aliases list -scope-id "$1" "${AUTH[@]}" -format=json 2>/dev/null \
    | jq -e --arg v "$2" '.items // [] | any(.value == $v)' >/dev/null
}

echo "=== 2.1 Global-scope alias: $GLOBAL_ALIAS_VALUE ==="
if alias_exists global "$GLOBAL_ALIAS_VALUE"; then
  echo "Alias already exists, skipping."
else
  boundary aliases create target \
    -scope-id global \
    -name "ssh-box-global" \
    -description "Global alias for the multi-hop SSH target" \
    -value "$GLOBAL_ALIAS_VALUE" \
    -destination-id "$TARGET_ID" \
    -authorize-session-host-id "$HOST_ID" \
    "${AUTH[@]}"
fi

echo
echo "=== 2.2 Project-scope alias: $PROJECT_ALIAS_VALUE ==="
echo "Setting alias suffixes (org=$ORG_SUFFIX, project=$PROJECT_SUFFIX)..."
boundary scopes set-alias-suffix -id "$ORG_ID" -alias-suffix "$ORG_SUFFIX" "${AUTH[@]}"
boundary scopes set-alias-suffix -id "$PROJECT_ID" -alias-suffix "$PROJECT_SUFFIX" "${AUTH[@]}"

if alias_exists "$PROJECT_ID" "$PROJECT_ALIAS_VALUE"; then
  echo "Alias already exists, skipping."
else
  boundary aliases create target \
    -scope-id "$PROJECT_ID" \
    -name "ssh-box-project" \
    -value "$PROJECT_ALIAS_VALUE" \
    -destination-id "$TARGET_ID" \
    -authorize-session-host-id "$HOST_ID" \
    "${AUTH[@]}"
fi

echo
echo "=== Stored aliases ==="
echo "--- global ---"
boundary aliases list -scope-id global "${AUTH[@]}"
echo "--- project ($PROJECT_ID) ---"
boundary aliases list -scope-id "$PROJECT_ID" "${AUTH[@]}"

echo
echo "Test: boundary connect ssh $GLOBAL_ALIAS_VALUE -token env://BOUNDARY_TOKEN -keyring-type=none"
