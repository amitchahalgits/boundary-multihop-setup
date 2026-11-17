#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================================="
echo " Starting Local Multi-Hop Boundary Enterprise Environment "
echo "=========================================================="

export BOUNDARY_ADDR="http://127.0.0.1:9200"
export BOUNDARY_KEYRING_TYPE="none"
export SSH_PASS="testpassword"

if [ -z "$BOUNDARY_LICENSE" ]; then
  # Check if BOUNDARY_LICENSE is already saved in .env
  if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
  fi
fi

if [ -z "$BOUNDARY_LICENSE" ]; then
  echo "ERROR: BOUNDARY_LICENSE is not set. Export your Boundary Enterprise license first (VAULT_LICENSE will not work)." >&2
  exit 1
fi

# 0. Stop any stale Boundary processes from earlier runs (they would hold ports 9200/9201/9202)
pkill -f "boundary server" 2>/dev/null || true
sleep 1



# 0b. Create and start the Podman machine
PODMAN_MACHINE="boundary-podman-machine"
echo "==> Ensuring Podman machine '$PODMAN_MACHINE' exists and is running..."
if ! podman machine inspect "$PODMAN_MACHINE" >/dev/null 2>&1; then
  podman machine init "$PODMAN_MACHINE"
fi
if [ "$(podman machine inspect "$PODMAN_MACHINE" --format '{{.State}}')" != "running" ]; then
  podman machine start "$PODMAN_MACHINE"
fi
podman system connection default "$PODMAN_MACHINE"

# 1. Start PostgreSQL DB Container
echo "==> [1/8] Starting PostgreSQL Container..."
podman rm -f boundary-postgres 2>/dev/null || true
podman run -d \
  --name boundary-postgres \
  --restart always \
  -e POSTGRES_USER=boundary \
  -e POSTGRES_PASSWORD=boundary \
  -e POSTGRES_DB=boundary \
  -p 5432:5432 \
  docker.io/library/postgres:15-alpine

until pg_isready -h 127.0.0.1 -p 5432 -U boundary >/dev/null 2>&1; do
  sleep 1
done

# 2. Initialize Database Schema
echo "==> [2/8] Initializing Boundary Database Schema..."
rm -f init.log controller.log worker-ingress.log worker-egress.log
boundary database init -config controller.hcl | tee init.log

export ADMIN_PASSWORD=$(grep "Password:" init.log | awk '{print $2}' | tr -d '\r\n')
echo "==> Captured Admin Password: $ADMIN_PASSWORD"

# 3. Start Controller
echo "==> [3/8] Starting Boundary Controller..."
boundary server -config controller.hcl > controller.log 2>&1 &
CONTROLLER_PID=$!
echo "Waiting for controller API on :9200..."
for i in $(seq 1 60); do
  if ! kill -0 "$CONTROLLER_PID" 2>/dev/null; then
    echo "ERROR: controller exited. See controller.log" >&2; tail -20 controller.log >&2; exit 1
  fi
  curl -s -o /dev/null http://127.0.0.1:9200/v1/scopes && break
  sleep 1
done

# 4. Start Ingress and Egress Workers
echo "==> [4/8] Starting Ingress & Egress Workers..."
boundary server -config worker-ingress.hcl > worker-ingress.log 2>&1 &
sleep 2
boundary server -config worker-egress.hcl > worker-egress.log 2>&1 &
sleep 2

# 5. Start Target SSH Container
echo "==> [5/8] Starting Target OpenSSH Container (Port 2222:2222)..."
podman rm -f ssh-target-box 2>/dev/null || true
podman run -d \
  --name ssh-target-box \
  --restart always \
  -p 2222:2222 \
  -e USER_NAME=testuser \
  -e USER_PASSWORD=testpassword \
  -e PASSWORD_ACCESS=true \
  lscr.io/linuxserver/openssh-server:latest
sleep 2

# 6. Authenticate Admin CLI
echo "==> [6/8] Authenticating CLI..."
AUTH_METHOD_ID=$(boundary auth-methods list -scope-id global -format=json -keyring-type=none | jq -r '.items[0].id')
export BOUNDARY_TOKEN=$(boundary authenticate password \
  -auth-method-id "$AUTH_METHOD_ID" \
  -login-name admin \
  -password "env://ADMIN_PASSWORD" \
  -keyring-type=none \
  -format=json | jq -r '.item.attributes.token')

echo "==> Waiting for both workers to register..."
for i in $(seq 1 30); do
  COUNT=$(boundary workers list -scope-id global -token env://BOUNDARY_TOKEN -keyring-type=none -format=json 2>/dev/null | jq '.items // [] | length')
  [ "${COUNT:-0}" -ge 2 ] && break
  sleep 2
done

echo "==> Checking Registered Workers:"
boundary workers list -scope-id global -token env://BOUNDARY_TOKEN -keyring-type=none

# 7. Provision Scopes, Host Sources, Credentials & Target
echo "==> [7/8] Provisioning Multi-Hop Boundary Resources..."

ORG_ID=$(boundary scopes create -scope-id global -name "DevOps Org" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.item.id')
PROJECT_ID=$(boundary scopes create -scope-id "$ORG_ID" -name "Core Infrastructure" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.item.id')

CATALOG_ID=$(boundary host-catalogs create static -scope-id "$PROJECT_ID" -name "VPC-Catalog" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.item.id')
SET_ID=$(boundary host-sets create static -host-catalog-id "$CATALOG_ID" -name "SSH-HostSet" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.item.id')
HOST_ID=$(boundary hosts create static -host-catalog-id "$CATALOG_ID" -name "internal-ssh-box" -address "127.0.0.1" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.item.id')
boundary host-sets add-hosts -id "$SET_ID" -host "$HOST_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

STORE_ID=$(boundary credential-stores create static -scope-id "$PROJECT_ID" -name "SSH-CredStore" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.item.id')
CRED_ID=$(boundary credentials create username-password \
  -credential-store-id "$STORE_ID" \
  -name "SSH-User-Pass" \
  -username "testuser" \
  -password "env://SSH_PASS" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none \
  -format=json | jq -r '.item.id')

TARGET_ID=$(boundary targets create ssh \
  -scope-id "$PROJECT_ID" \
  -name "multihop-ssh-target" \
  -description "SSH Target routed via Ingress and Egress worker mesh" \
  -default-port 2222 \
  -session-max-seconds 28800 \
  -ingress-worker-filter '"ingress" in "/tags/type"' \
  -egress-worker-filter '"egress" in "/tags/type"' \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none \
  -format=json | jq -r '.item.id')

boundary targets add-host-sources -id "$TARGET_ID" -host-source "$SET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
boundary targets set-credential-sources -id "$TARGET_ID" -injected-application-credential-source "$CRED_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

# 8. Persist Environment Variables for Shell Sessions
echo "==> [8/8] Persisting Environment Variables across Shell Sessions..."

ENV_FILE="$SCRIPT_DIR/.env"
cat <<ENV_EOF > "$ENV_FILE"
# Boundary Multi-Hop Environment Variables (Auto-generated by setup.sh)
export BOUNDARY_ADDR="http://127.0.0.1:9200"
export BOUNDARY_KEYRING_TYPE="none"
export BOUNDARY_LICENSE="$BOUNDARY_LICENSE"
export ADMIN_PASSWORD="$ADMIN_PASSWORD"
export BOUNDARY_TOKEN="$BOUNDARY_TOKEN"
export AUTH_METHOD_ID="$AUTH_METHOD_ID"
export ORG_ID="$ORG_ID"
export PROJECT_ID="$PROJECT_ID"
export CATALOG_ID="$CATALOG_ID"
export SET_ID="$SET_ID"
export HOST_ID="$HOST_ID"
export STORE_ID="$STORE_ID"
export CRED_ID="$CRED_ID"
export TARGET_ID="$TARGET_ID"
export SSH_PASS="$SSH_PASS"
ENV_EOF
chmod 600 "$ENV_FILE"

# Add automatic sourcing hook to user's shell rc files if present
SOURCE_LINE="[ -f \"$ENV_FILE\" ] && source \"$ENV_FILE\""
for RC in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  if [ -f "$RC" ]; then
    if ! grep -q "boundary-multihop-setup/.env" "$RC" 2>/dev/null; then
      echo "" >> "$RC"
      echo "# Boundary Multi-Hop Environment Persistence" >> "$RC"
      echo "$SOURCE_LINE" >> "$RC"
      echo "==> Added persistent auto-source hook to $RC"
    fi
  fi
done

echo "=========================================================="
echo " Setup Complete & Environment Variables Persisted! "
echo " Environment File: $ENV_FILE"
echo " Target ID:        $TARGET_ID"
echo " Project ID:       $PROJECT_ID"
echo " Boundary Token:   ${BOUNDARY_TOKEN:0:12}..."
echo ""
echo " In this shell, variables are already exported."
echo " In new shells or Lima sessions, they are auto-sourced from $ENV_FILE"
echo " (or manually run: source $ENV_FILE)"
echo ""
echo " Connect with: boundary connect ssh -target-id \$TARGET_ID"
echo "=========================================================="
