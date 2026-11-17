#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> [1/5] Stopping Boundary processes..."
pkill -f "boundary server" || true

echo "==> [2/5] Resetting PostgreSQL container..."
podman rm -f boundary-postgres 2>/dev/null || true
podman run -d \
  --name boundary-postgres \
  --restart always \
  -e POSTGRES_USER=boundary \
  -e POSTGRES_PASSWORD=boundary \
  -e POSTGRES_DB=boundary \
  -p 5432:5432 \
  docker.io/library/postgres:15-alpine
sleep 2

echo "==> [3/5] Cleaning logs and cached tokens..."
rm -f init.log controller.log worker-ingress.log worker-egress.log
rm -rf ~/.boundary

echo "==> [4/5] Removing persisted environment file..."
rm -f "$SCRIPT_DIR/.env"
unset BOUNDARY_TOKEN ADMIN_PASSWORD TARGET_ID PROJECT_ID ORG_ID CATALOG_ID SET_ID HOST_ID STORE_ID CRED_ID

echo "==> [5/5] Cleaning up containers and stopping Podman machine..."
podman rm -f boundary-postgres ssh-target-box 2>/dev/null || true
podman machine stop boundary-podman-machine 2>/dev/null || true

echo "==> Environment is clean. Run ./setup.sh to spin up fresh."
