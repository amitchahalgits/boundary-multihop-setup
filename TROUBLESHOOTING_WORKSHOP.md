# Boundary Enterprise Multi-Hop: Deep Dive & Team Troubleshooting Workshop

This guide provides an in-depth parameter-by-parameter breakdown of the multi-hop Boundary setup, followed by a **team dry-run troubleshooting workshop** containing 3 realistic failure scenarios across the Ingress, Egress, and Target layers.

---

## Part 1: Deep Dive Parameter & Step Breakdown

### 1. Controller Configuration (`controller.hcl`)

```hcl
disable_mlock = true

controller {
  name                = "enterprise-controller"
  database {
    url = "postgresql://boundary:boundary@127.0.0.1:5432/boundary?sslmode=disable"
  }
  public_cluster_addr = "127.0.0.1:9201"
}

listener "tcp" {
  address     = "0.0.0.0:9200"
  purpose     = "api"
  tls_disable = true
}

listener "tcp" {
  address     = "0.0.0.0:9201"
  purpose     = "cluster"
  tls_disable = true
}

kms "aead" {
  purpose   = "root"
  aead_type = "aes-gcm"
  key       = "sP1fnF5Xz85RrXyELHFeZg9Ad2qt4Z4bgNHVGtD6ung="
  key_id    = "global_root"
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "OLFhJNbEb3umRjdhY15QKNEmNXokY1Iq8fZBjCUfN0T="
  key_id    = "global_worker-auth"
}

kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
  key_id    = "global_recovery"
}
```

#### Parameter Functions:
* `database.url`: PostgreSQL connection string. Stores the encrypted state of scopes, users, targets, and session telemetry.
* `public_cluster_addr`: The network address (`127.0.0.1:9201`) that workers use to find and authenticate with the controller cluster.
* `listener[purpose="api"]` (Port `9200`): Serves the REST/gRPC API and the Admin Web UI for administrators and clients.
* `listener[purpose="cluster"]` (Port `9201`): Internal gRPC listener for worker-to-controller synchronization and heartbeat registration.
* `kms[purpose="root"]`: Encrypts internal database keys and security parameters at rest.
* `kms[purpose="worker-auth"]`: Shared AEAD key enabling **Worker-Led Authentication**. Workers encrypt their registration payload with this key so the controller automatically trusts and activates them.
* `kms[purpose="recovery"]`: Break-glass key used to authenticate and recover admin access if password credentials are lost.

---

### 2. Ingress Worker Configuration (`worker-ingress.hcl`)

```hcl
worker {
  name              = "worker-ingress-dmz"
  description       = "Edge Ingress Worker"
  public_addr       = "127.0.0.1:9202"
  initial_upstreams = ["127.0.0.1:9201"]

  tags {
    type = ["ingress"]
    env  = ["dmz"]
  }
}

listener "tcp" {
  address     = "0.0.0.0:9202"
  purpose     = "proxy"
  tls_disable = true
}
```

#### Parameter Functions:
* `public_addr`: The advertised IP and port (`127.0.0.1:9202`) that downstream clients and other workers dial to reach this proxy.
* `initial_upstreams`: Addresses of upstream nodes to dial on startup. Set to `127.0.0.1:9201` (Controller Cluster Listener) so the Ingress worker registers into the global topology.
* `tags`: Key-value metadata (`type = ["ingress"]`, `env = ["dmz"]`) used by the controller's Boolean expression filters (`-ingress-worker-filter`) to route incoming client traffic to this worker.
* `listener[purpose="proxy"]` (Port `9202`): The client-facing data plane port that establishes encrypted session proxy tunnels.

---

### 3. Egress Worker Configuration (`worker-egress.hcl`)

```hcl
worker {
  name              = "worker-egress-private"
  description       = "Internal Egress Worker in Private VPC"
  public_addr       = "127.0.0.1:9204"
  initial_upstreams = ["127.0.0.1:9202"]

  tags {
    type = ["egress"]
    env  = ["private-vpc"]
  }
}

listener "tcp" {
  address     = "0.0.0.0:9204"
  purpose     = "proxy"
  tls_disable = true
}
```

#### Parameter Functions:
* `initial_upstreams`: **Set to `127.0.0.1:9202` (Ingress Worker Proxy Port)**. This is the critical multi-hop binding: by dialing the Ingress worker, Boundary's routing engine constructs a Directed Acyclic Graph (DAG) indicating that `worker-egress-private` is downstream of `worker-ingress-dmz`.
* `tags`: Key-value metadata (`type = ["egress"]`) matched by `-egress-worker-filter`.
* `listener[purpose="proxy"]` (Port `9204`): Internal data plane listener used to relay streams between workers and into the target host.

---

### 4. CLI Provisioning Commands Explained

```bash
# 1. Create Static Credential
CRED_ID=$(boundary credentials create username-password \
  -credential-store-id "$STORE_ID" \
  -name "SSH-User-Pass" \
  -username "testuser" \
  -password "env://SSH_PASS" \
  -format=json | jq -r '.item.id')
```
* `-credential-store-id`: Points to the container static store.
* `-password "env://SSH_PASS"`: Uses `env://` syntax so plaintext passwords are not leaked into shell history or `ps` tables.

```bash
# 2. Create SSH Target
TARGET_ID=$(boundary targets create ssh \
  -scope-id "$PROJECT_ID" \
  -name "multihop-ssh-target" \
  -default-port 2222 \
  -session-max-seconds 28800 \
  -ingress-worker-filter '"ingress" in "/tags/type"' \
  -egress-worker-filter '"egress" in "/tags/type"' \
  -format=json | jq -r '.item.id')
```
* `-default-port 2222`: Default port on destination container.
* `-session-max-seconds 28800`: Automatic session termination cap (8 hours).
* `-ingress-worker-filter`: Directs initial client handshake to `worker-ingress-dmz`.
* `-egress-worker-filter`: Directs outbound target connection to `worker-egress-private`.

```bash
# 3. Bind Host & Injected Credentials
boundary targets add-host-sources -id "$TARGET_ID" -host-source "$SET_ID"
boundary targets set-credential-sources -id "$TARGET_ID" -injected-application-credential-source "$CRED_ID"
```
* `add-host-sources`: Links destination host IP (`127.0.0.1`).
* `set-credential-sources`: Injects `testuser:testpassword` directly into SSH handshake with zero client exposure.

---

## Part 2: Team Dry-Run Troubleshooting Workshop (3 Scenarios)

```mermaid
flowchart TD
    subgraph Scenario1["Scenario 1: Ingress Layer Failure"]
        I1["Worker Filter Tag Mismatch / Ingress Down"]
        S1["Symptom: SelectSessionWorkers Error #133"]
    end

    subgraph Scenario2["Scenario 2: Egress Mesh DAG Failure"]
        I2["Egress Worker dials Controller instead of Ingress (:9201 vs :9202)"]
        S2["Symptom: No ingress workers with valid next-hop paths"]
    end

    subgraph Scenario3["Scenario 3: Target & Credential Layer Failure"]
        I3["Port Mismatch (:22 vs :2222) or Missing Injected Creds"]
        S3["Symptom: Immediate Connection Closed / Error #409"]
    end
```

---

### Scenario 1: Ingress Layer Failure (Filter Tag Mismatch)

#### How to Inject the Bug:
Update the target's ingress filter to look for a tag that does not exist on any worker:
```bash
boundary targets update ssh -id "$TARGET_ID" -ingress-worker-filter '"public-dmz" in "/tags/env"'
```

#### What the User Sees:
```bash
boundary connect ssh -target-id "$TARGET_ID"
```
```text
Error from controller when performing authorize-session action against given target:
  Kind:     Internal
  Message:  server.(Repository).SelectSessionWorkers: No workers are available to handle this session.: state violation: error #133
```

#### Team Diagnostic Steps:
1. **List all registered workers and inspect their tags**:
   ```bash
   boundary workers list -scope-id global
   boundary workers read -id <WORKER_INGRESS_ID>
   ```
   *Notice that the Ingress Worker has `env = ["dmz"]`, NOT `env = ["public-dmz"]`.*
2. **Inspect target configuration**:
   ```bash
   boundary targets read -id "$TARGET_ID"
   ```

#### Resolution:
Fix the ingress filter on the target:
```bash
boundary targets update ssh -id "$TARGET_ID" -ingress-worker-filter '"dmz" in "/tags/env"'
```

---

### Scenario 2: Egress Layer Failure (Broken Multi-Hop Mesh DAG)

#### How to Inject the Bug:
In `worker-egress.hcl`, change `initial_upstreams` to `["127.0.0.1:9201"]` (pointing to the Controller instead of the Ingress Worker), then restart the egress worker:
```bash
# Edit worker-egress.hcl -> initial_upstreams = ["127.0.0.1:9201"]
pkill -f "worker-egress.hcl" || true
boundary server -config worker-egress.hcl > worker-egress.log 2>&1 &
```

#### What the User Sees:
```bash
boundary connect ssh -target-id "$TARGET_ID"
```
```text
Error from controller when performing authorize-session action against given target:
  Kind:     Internal
  Message:  server.(Repository).SelectSessionWorkers: server.filterWorkersEnt: No ingress workers with valid next-hop paths could be found for this multi-hop session.: state violation: error #133
```

#### Team Diagnostic Steps:
1. **Understand the Error**: Both workers are `active`, but the Controller cannot find a network path from Ingress to Egress.
2. **Check Egress Worker Upstream**: Check `worker-egress.hcl` to see where it connects.
   *Notice it is connected to `:9201` (Controller) instead of `:9202` (Ingress Worker).*

#### Resolution:
1. Set `initial_upstreams = ["127.0.0.1:9202"]` in `worker-egress.hcl`.
2. Restart the egress worker:
   ```bash
   pkill -f "worker-egress.hcl" || true
   boundary server -config worker-egress.hcl > worker-egress.log 2>&1 &
   ```

---

### Scenario 3: Target Layer Failure (Port Mapping Mismatch)

#### How to Inject the Bug:
Recreate the target container with wrong internal port mapping `-p 2222:22` (where `sshd` inside the container listens on `2222`):
```bash
podman rm -f ssh-target-box
podman run -d --name ssh-target-box -p 2222:22 -e USER_NAME=testuser -e USER_PASSWORD=testpassword lscr.io/linuxserver/openssh-server:latest
```

#### What the User Sees:
```bash
boundary connect ssh -target-id "$TARGET_ID"
```
```text
Connection closed by 127.0.0.1 port 46139
```
*Controller logs show authorization succeeded and worker path generated `[w_ingress w_egress]`, but connection immediately terminates upon reaching the target.*

#### Team Diagnostic Steps:
1. **Check Controller Logs**: Confirm authorization and worker mesh routing succeeded.
2. **Check Egress Worker Logs**: Look for `connection refused` or `EOF` when dialing upstream host `127.0.0.1:2222`.
3. **Check Container Logs**:
   ```bash
   podman logs ssh-target-box
   ```
   *Notice: `sshd is listening on port 2222` inside the container, but Podman mapped host `2222` to container `22`.*

#### Resolution:
Re-run container with matching host-to-container port `-p 2222:2222`:
```bash
podman rm -f ssh-target-box
podman run -d --name ssh-target-box -p 2222:2222 -e USER_NAME=testuser -e USER_PASSWORD=testpassword -e PASSWORD_ACCESS=true lscr.io/linuxserver/openssh-server:latest
```
Test connection:
```bash
boundary connect ssh -target-id "$TARGET_ID"
```
*(Session connects cleanly with injected credentials).*
