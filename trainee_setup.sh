#!/bin/bash
# Creates the non-admin "trainee" user with a role holding ALL the grants needed
# for target alias / transparent session access (workshop section 2.6):
#   type=auth-method;ids=*;actions=authorize
#   type=target;ids=*;actions=authorize-session
#   type=auth-token;ids=*;actions=read:self
#   type=user;ids=*;actions=list-resolvable-aliases
# No fault is injected. Safe to re-run: existing resources are reused and the
# role's grants are topped up.
#
# Overridable: TRAINEE_LOGIN, ROLE_NAME. The trainee password is prompted for
# (no echo), or taken from TRAINEE_PASSWORD if set.
#
# Prerequisite: ./setup.sh has been run.
set -eo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trainee_lib.sh"

admin_login

echo "=== Account '$TRAINEE_LOGIN' ==="
account_id=$(find_account)
if [ -z "$account_id" ]; then
  require_trainee_password
  account_id=$(boundary accounts create password \
    -auth-method-id "$AUTH_METHOD_ID" \
    -login-name "$TRAINEE_LOGIN" \
    -password env://TRAINEE_PASSWORD \
    "${ADMIN[@]}" -format=json | jq -r '.item.id')
  echo "Created account $account_id"
else
  echo "Account exists: $account_id"
fi

echo "=== User '$TRAINEE_LOGIN' ==="
user_id=$(find_id users name "$TRAINEE_LOGIN" -scope-id global)
if [ -z "$user_id" ]; then
  user_id=$(boundary users create -scope-id global -name "$TRAINEE_LOGIN" \
    "${ADMIN[@]}" -format=json | jq -r '.item.id')
  echo "Created user $user_id"
  boundary users add-accounts -id "$user_id" -account "$account_id" "${ADMIN[@]}" >/dev/null
else
  echo "User exists: $user_id"
fi

echo "=== Role '$ROLE_NAME' ==="
role_id=$(find_role)
if [ -z "$role_id" ]; then
  role_id=$(boundary roles create -scope-id global -name "$ROLE_NAME" \
    -description "Non-admin role for transparent session / alias access" \
    "${ADMIN[@]}" -format=json | jq -r '.item.id')
  echo "Created role $role_id"
  boundary roles add-principals -id "$role_id" -principal "$user_id" "${ADMIN[@]}" >/dev/null
  # Role lives in global scope; extend its grants to the org and project below it
  boundary roles add-grant-scopes -id "$role_id" \
    -grant-scope-id this -grant-scope-id descendants "${ADMIN[@]}" >/dev/null
else
  echo "Role exists: $role_id"
fi

# add-grants is additive and de-duplicates, so this is idempotent
grant_args=()
for g in "${TRAINEE_GRANTS[@]}"; do grant_args+=(-grant "$g"); done
boundary roles add-grants -id "$role_id" "${grant_args[@]}" "${ADMIN[@]}" >/dev/null

echo
boundary roles read -id "$role_id" "${ADMIN[@]}"
echo
echo "Trainee login: $TRAINEE_LOGIN (auth method $AUTH_METHOD_ID)"
