#!/usr/bin/env bash
# Removes everything setup.sh creates. Safe to re-run.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> [1/5] Stopping Boundary processes (controller, ingress and egress workers)..."
pkill -f "boundary server" 2>/dev/null || true

echo "==> [2/5] Removing containers (boundary-postgres, ssh-target-box)..."
podman rm -f boundary-postgres 2>/dev/null || true
podman rm -f ssh-target-box 2>/dev/null || true

echo "==> [3/5] Cleaning logs and cached tokens..."
rm -f init.log controller.log worker-ingress.log worker-egress.log
rm -rf ~/.boundary

echo "==> [4/5] Removing persisted environment file..."
rm -f "$SCRIPT_DIR/.env"
unset BOUNDARY_ADDR BOUNDARY_KEYRING_TYPE BOUNDARY_TOKEN ADMIN_PASSWORD AUTH_METHOD_ID \
  ORG_ID PROJECT_ID CATALOG_ID SET_ID HOST_ID STORE_ID CRED_ID TARGET_ID SSH_PASS

echo "==> [5/5] Removing auto-source hook added by setup.sh to shell rc files..."
HOOK_COMMENT="# Boundary Multi-Hop Environment Persistence"
for RC in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  [ -f "$RC" ] || continue
  grep -qF "$HOOK_COMMENT" "$RC" || continue
  TMP="$(mktemp)"
  # Drop the comment, the source line, and the blank line setup.sh put before the comment.
  awk -v c="$HOOK_COMMENT" '
    /^$/ { if (held) print ""; held = 1; next }
    {
      if (held && $0 != c) print ""
      held = 0
      if ($0 == c) next
      if ($0 ~ /^\[ -f / && index($0, "boundary-multihop-setup/.env")) next
      print
    }
    END { if (held) print "" }
  ' "$RC" > "$TMP"
  cat "$TMP" > "$RC"   # write through, so symlinked rc files and permissions are preserved
  rm -f "$TMP"
  echo "    cleaned $RC"
done

echo "==> Environment is clean. Run ./setup.sh to spin up fresh."
echo "    (Images pulled by podman are kept. Remove with: podman rmi docker.io/library/postgres:15-alpine lscr.io/linuxserver/openssh-server:latest)"
