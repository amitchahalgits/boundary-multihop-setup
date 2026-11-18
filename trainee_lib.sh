#!/bin/bash
# Shared helpers for trainee_setup.sh and scenario_d.sh. Source this file; do not run it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: $SCRIPT_DIR/.env not found. Run ./setup.sh first." >&2
  exit 1
fi
source "$SCRIPT_DIR/.env"

for v in BOUNDARY_ADDR AUTH_METHOD_ID ADMIN_PASSWORD; do
  if [ -z "${!v}" ]; then
    echo "ERROR: $v is not set in .env" >&2
    exit 1
  fi
done

ALIAS_VALUE="${ALIAS_VALUE:-ssh-box.boundary.dev}"
TRAINEE_LOGIN="${TRAINEE_LOGIN:-trainee}"
ROLE_NAME="${ROLE_NAME:-trainee-role}"

# Grants for a non-admin user (workshop section 2.6).
AUTHORIZE_SESSION_GRANT="type=target;ids=*;actions=authorize-session"
TRAINEE_GRANTS=(
  "type=auth-method;ids=*;actions=authorize-session"
  "$AUTHORIZE_SESSION_GRANT"
  "type=auth-token;ids=*;actions=read:self"
  "type=user;ids=*;actions=list-resolvable-aliases"
)

AUTH=(-keyring-type=none)

# Prompts (no echo) for the trainee password unless TRAINEE_PASSWORD is already set.
# Exported so child scripts (trainee_setup.sh) don't prompt again.
require_trainee_password() {
  if [ -z "$TRAINEE_PASSWORD" ]; then
    if [ ! -t 0 ]; then
      echo "ERROR: TRAINEE_PASSWORD is not set and there is no terminal to prompt on." >&2
      exit 1
    fi
    read -r -s -p "Password for '$TRAINEE_LOGIN': " TRAINEE_PASSWORD
    echo
    if [ -z "$TRAINEE_PASSWORD" ]; then
      echo "ERROR: password must not be empty." >&2
      exit 1
    fi
  fi
  export TRAINEE_PASSWORD
}

login() { # <login-name> <password-env-var-name> -> prints token
  boundary authenticate password \
    -auth-method-id "$AUTH_METHOD_ID" \
    -login-name "$1" \
    -password "env://$2" \
    "${AUTH[@]}" -format=json | jq -r '.item.attributes.token'
}

admin_login() {
  ADMIN_TOKEN=$(login admin ADMIN_PASSWORD)
  export ADMIN_TOKEN
  ADMIN=(-token env://ADMIN_TOKEN "${AUTH[@]}")
}

find_id() { # <resource: roles|users> <field> <value> [extra list args...]
  local res="$1" field="$2" val="$3"; shift 3
  boundary "$res" list "$@" "${ADMIN[@]}" -format=json 2>/dev/null \
    | jq -r --arg f "$field" --arg v "$val" '.items // [] | map(select(.[$f] == $v)) | .[0].id // empty'
}

find_account() { # trainee account, by login_name
  boundary accounts list -auth-method-id "$AUTH_METHOD_ID" "${ADMIN[@]}" -format=json 2>/dev/null \
    | jq -r --arg v "$TRAINEE_LOGIN" '.items // [] | map(select(.attributes.login_name == $v)) | .[0].id // empty'
}

find_role() { find_id roles name "$ROLE_NAME" -scope-id global; }
