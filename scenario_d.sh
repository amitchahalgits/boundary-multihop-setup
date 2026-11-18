#!/bin/bash
# Scenario D: "Alias resolves, but permission denied / authorize-session fails"
# (TARGET_ALIAS_TRANSPARENT_SESSIONS_WORKSHOP.md, section 3).
#
# Usage: ./scenario_d.sh <command>
#   inject  Run trainee_setup.sh, then remove the authorize-session grant from
#           the trainee role and show that connecting via the alias fails (403).
#   verify  Try `boundary connect ssh <alias>` as trainee.
#   fix     Add the missing authorize-session grant back, then verify.
#   revert  Delete the trainee user, account and role (back to a clean lab).
#
# Prerequisites: ./setup.sh and ./create_aliases.sh have been run.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/trainee_lib.sh"

do_verify() {
  echo
  echo "=== Verify: boundary connect ssh $ALIAS_VALUE as $TRAINEE_LOGIN ==="
  require_trainee_password
  TRAINEE_TOKEN=$(login "$TRAINEE_LOGIN" TRAINEE_PASSWORD)
  export TRAINEE_TOKEN
  set +e
  boundary connect ssh "$ALIAS_VALUE" -token env://TRAINEE_TOKEN "${AUTH[@]}" -- \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "echo connected as \$(whoami)"
  local rc=$?
  set -e
  echo "(exit code: $rc)"
}

do_inject() {
  require_trainee_password
  "$SCRIPT_DIR/trainee_setup.sh"
  admin_login
  local role_id
  role_id=$(find_role)
  echo
  echo "=== Inject: remove '$AUTHORIZE_SESSION_GRANT' from role $role_id ==="
  boundary roles remove-grants -id "$role_id" -grant "$AUTHORIZE_SESSION_GRANT" "${ADMIN[@]}" >/dev/null
  boundary roles read -id "$role_id" "${ADMIN[@]}"
  echo "Expected symptom: 403 Forbidden on authorize-session for $ALIAS_VALUE"
  do_verify
  echo
  echo "Diagnose:  boundary roles list -scope-id global; boundary roles read -id $role_id"
  echo "Fix:       ./scenario_d.sh fix"
}

do_fix() {
  admin_login
  local role_id
  role_id=$(find_role)
  if [ -z "$role_id" ]; then
    echo "ERROR: role '$ROLE_NAME' not found. Run './scenario_d.sh inject' first." >&2
    exit 1
  fi
  echo "=== Fix: add '$AUTHORIZE_SESSION_GRANT' to role $role_id ==="
  boundary roles add-grants -id "$role_id" -grant "$AUTHORIZE_SESSION_GRANT" "${ADMIN[@]}"
  do_verify
}

do_revert() {
  admin_login
  local role_id user_id account_id
  role_id=$(find_role)
  user_id=$(find_id users name "$TRAINEE_LOGIN" -scope-id global)
  account_id=$(find_account)
  [ -n "$role_id" ]    && boundary roles delete -id "$role_id" "${ADMIN[@]}" && echo "Deleted role $role_id"
  [ -n "$user_id" ]    && boundary users delete -id "$user_id" "${ADMIN[@]}" && echo "Deleted user $user_id"
  [ -n "$account_id" ] && boundary accounts delete -id "$account_id" "${ADMIN[@]}" && echo "Deleted account $account_id"
  echo "Scenario D reverted."
}

case "${1:-}" in
  inject) do_inject ;;
  verify) admin_login; do_verify ;;
  fix)    do_fix ;;
  revert) do_revert ;;
  *) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
