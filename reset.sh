#!/usr/bin/env bash
set -e

echo "==> [1/3] Stopping Boundary processes..."
pkill -f "boundary server" || true

echo "==> [2/3] Resetting PostgreSQL container..."
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

echo "==> [3/3] Cleaning logs and cached tokens..."
rm -f init.log controller.log worker-ingress.log worker-egress.log
rm -rf ~/.boundary
unset BOUNDARY_TOKEN

echo "==> Environment is clean. Run ./setup.sh to spin up fresh."
