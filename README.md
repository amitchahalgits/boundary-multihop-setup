# Local Multi-Hop Boundary Enterprise Environment (Lima macOS)

This repository provides configuration files and automation scripts to deploy a complete **HashiCorp Boundary Enterprise** local testing environment on macOS using **Lima (Linux Virtual Machines)** and **Podman**.

---

## 🏗️ Architecture Overview

```text
Client (macOS Host)
   │
   ├─► API Auth (:9200) ─────────► Boundary Controller (:9201)
   │                                  │
   │                                  ▼
   │                              PostgreSQL 15 (:5432)
   │
   └─► Data Tunnel (:9202) ──────► Ingress Worker (Edge / DMZ)
                                      │
                                      ▼ (Mesh Relay :9204)
                                   Egress Worker (Private VPC)
                                      │
                                      ▼ (Credential Injection :2222)
                                   OpenSSH Target Container
```

---

## 🔐 Persistent Environment Variables (Across Shell Sessions)

To prevent losing credentials, tokens, and target IDs when opening new terminal tabs or new Lima VM shell sessions (`limactl shell boundary`), this repository automatically persists all environment variables:

1. **Auto-Generated `.env` File**: `setup.sh` exports and writes all runtime variables to `$(pwd)/.env` with restricted permissions (`chmod 600`).
2. **Auto-Sourcing Hook**: `setup.sh` automatically adds a source hook to `~/.bashrc`, `~/.zshrc`, and `~/.profile`:
   ```bash
   [ -f "/path/to/boundary-multihop-setup/.env" ] && source "/path/to/boundary-multihop-setup/.env"
   ```
3. **Instant Access in Any New Session**: Opening any new shell tab or running `limactl shell boundary` automatically has all variables ready:
   - `$BOUNDARY_ADDR`
   - `$BOUNDARY_TOKEN`
   - `$BOUNDARY_KEYRING_TYPE`
   - `$TARGET_ID`
   - `$PROJECT_ID`
   - `$ORG_ID`
   - `$ADMIN_PASSWORD`

You can also manually reload the environment at any time:
```bash
source .env
```

---

## 🏴‍☠️ Team Dry-Run & Troubleshooting Workshops

This repository includes hands-on troubleshooting and dry-run workshop scenarios designed for engineering and SRE teams:

| Guide / Script | Description |
|---|---|
| **[`TREASURE_HUNT_WORKSHOP.md`](TREASURE_HUNT_WORKSHOP.md)** | **3-Stage Chained Escape Room**: All 3 issues (Unbound Alias ➔ Concurrency Cap ➔ Target Port Drift) exist simultaneously and must be solved in sequence. |
| **[`treasure_hunt_break.sh`](treasure_hunt_break.sh)** | **One-Touch Facilitator Script**: Automatically injects all 3 chained treasure hunt issues into the environment. |
| **[`TARGET_BREAKING_SCENARIOS.md`](TARGET_BREAKING_SCENARIOS.md)** | **Target & Alias Deep Dive**: Covers unbound aliases, scope suffix namespacing rules, and port 22 vs 2222 drift. |
| **[`TROUBLESHOOTING_WORKSHOP.md`](TROUBLESHOOTING_WORKSHOP.md)** | **3-Layer Team Matrix**: Simulates outages across Target Credentials, Multi-Hop Worker Mesh DAGs, and Session Concurrency. |

---

## 🐧 Lima Prerequisites & Setup (macOS)

Lima provides automatic file sharing, port forwarding, and containerd/Podman support for running Linux on macOS (both Apple Silicon M-series and Intel).

### 1. Install Lima on macOS via Homebrew

```bash
brew install lima
```

### 2. Basic Lima Commands Cheat Sheet

| Command | Description |
|---|---|
| `limactl start template://docker --name=boundary` | Create and launch an Ubuntu VM with docker/podman pre-configured |
| `limactl shell boundary` | Open an interactive bash shell inside the VM |
| `limactl list` | View status and IP of all running VMs |
| `limactl stop boundary` | Gracefully shut down the VM |
| `limactl start boundary` | Resume a stopped VM |
| `limactl delete boundary` | Delete the VM and wipe its virtual disks |
| `limactl info` | View Lima subsystem and daemon information |

### 3. Launch Lima VM for Boundary

```bash
# Launch an Ubuntu instance named 'boundary'
limactl start --name=boundary --memory 8 template://docker

# Enter the VM shell
limactl shell boundary

# Set your Boundary Enterprise license env variable:
export BOUNDARY_LICENSE="..."
```

### 4. Install Required Packages & Boundary Enterprise (Inside Lima VM)

Once inside the Lima VM shell, install the required system tools, Podman, and HashiCorp Boundary Enterprise:

```bash
# 1. Update APT and install essential utilities
sudo apt-get update && sudo apt-get install -y curl git jq unzip wget gpg lsb-release postgresql-client openssh-server podman

# 2. Add HashiCorp Official APT Repository
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# 3. Install Boundary Enterprise
sudo apt-get update && sudo apt-get install -y boundary-enterprise

# 4. Verify installation
boundary version
podman --version

# 5. Clone the repo inside the Lima VM:
git clone https://github.com/amitchahalgits/boundary-multihop-setup.git
cd boundary-multihop-setup
```

---

## 📋 Component Matrix

| Component | Port | Purpose | Configuration File |
|---|---|---|---|
| **Controller** | `9200` (API), `9201` (Cluster) | Control Plane & Worker Interconnect | `controller.hcl` |
| **Ingress Worker** | `9202` (Proxy) | Client-Facing Edge Worker (`tags: type=ingress`) | `worker-ingress.hcl` |
| **Egress Worker** | `9204` (Proxy) | Internal Subnet Worker (`tags: type=egress`) | `worker-egress.hcl` |
| **PostgreSQL** | `5432` | Boundary State Database | Podman (`docker.io/library/postgres:15-alpine`) |
| **SSH Target** | `2222` | Upstream OpenSSH Server Container | Podman (`linuxserver/openssh-server`) |

---

## 🚀 Quick Start (Automated)

Inside your Lima VM shell:

```bash
chmod +x setup.sh reset.sh
./setup.sh
```

Once complete, the script provisions all components, writes `.env`, and registers auto-sourcing hooks.

### Connecting in the Current or Any New Shell Session
```bash
# In the current shell or any newly opened terminal/Lima shell:
boundary connect ssh -target-id "$TARGET_ID"
```

---

## 🔧 Step-by-Step Manual Instructions

### 1. Start PostgreSQL
```bash
podman run -d --name boundary-postgres --restart always \
  -e POSTGRES_USER=boundary -e POSTGRES_PASSWORD=boundary -e POSTGRES_DB=boundary \
  -p 5432:5432 docker.io/library/postgres:15-alpine
```

### 2. Initialize DB & Start Controller
```bash
boundary database init -config controller.hcl | tee init.log
boundary server -config controller.hcl > controller.log 2>&1 &
```

### 3. Start Ingress Worker (Edge)
```bash
boundary server -config worker-ingress.hcl > worker-ingress.log 2>&1 &
```

### 4. Start Egress Worker (Private VPC)
```bash
boundary server -config worker-egress.hcl > worker-egress.log 2>&1 &
```
*(Note: `worker-egress.hcl` sets `initial_upstreams = ["127.0.0.1:9202"]` to form the multi-hop routing DAG).*

### 5. Start SSH Target Container
```bash
podman run -d --name ssh-target-box --restart always \
  -p 2222:2222 \
  -e USER_NAME=testuser -e USER_PASSWORD=testpassword -e PASSWORD_ACCESS=true \
  lscr.io/linuxserver/openssh-server:latest
```

### 6. Authenticate Admin CLI
```bash
export BOUNDARY_ADDR="http://127.0.0.1:9200"
export BOUNDARY_KEYRING_TYPE="none"
export ADMIN_PASSWORD=$(grep "Password:" init.log | awk '{print $2}' | tr -d '\r\n')
AUTH_METHOD_ID=$(boundary auth-methods list -scope-id global -format=json | jq -r '.items[0].id')

export BOUNDARY_TOKEN=$(boundary authenticate password \
  -auth-method-id "$AUTH_METHOD_ID" \
  -login-name admin \
  -password env://ADMIN_PASSWORD \
  -format=json | jq -r '.item.attributes.token')

echo "token length: ${#BOUNDARY_TOKEN}"
```

### 7. Provision Scopes, Host Sets & Credentials
```bash
ORG_ID=$(boundary scopes create -scope-id global -name "DevOps Org" -token env://BOUNDARY_TOKEN -format=json | jq -r '.item.id')
PROJECT_ID=$(boundary scopes create -scope-id "$ORG_ID" -name "Core Infrastructure" -token env://BOUNDARY_TOKEN -format=json | jq -r '.item.id')

CATALOG_ID=$(boundary host-catalogs create static -scope-id "$PROJECT_ID" -name "VPC-Catalog" -token env://BOUNDARY_TOKEN -format=json | jq -r '.item.id')
SET_ID=$(boundary host-sets create static -host-catalog-id "$CATALOG_ID" -name "SSH-HostSet" -token env://BOUNDARY_TOKEN -format=json | jq -r '.item.id')
HOST_ID=$(boundary hosts create static -host-catalog-id "$CATALOG_ID" -name "internal-ssh-box" -address "127.0.0.1" -token env://BOUNDARY_TOKEN -format=json | jq -r '.item.id')
boundary host-sets add-hosts -id "$SET_ID" -host "$HOST_ID" -token env://BOUNDARY_TOKEN

STORE_ID=$(boundary credential-stores create static -scope-id "$PROJECT_ID" -name "SSH-CredStore" -token env://BOUNDARY_TOKEN -format=json | jq -r '.item.id')
CRED_ID=$(boundary credentials create username-password \
  -credential-store-id "$STORE_ID" \
  -name "SSH-User-Pass" \
  -username "testuser" \
  -password "env://SSH_PASS" \
  -token env://BOUNDARY_TOKEN \
  -format=json | jq -r '.item.id')
```

### 8. Create Target with Ingress & Egress Filters & Injected Credential
```bash
TARGET_ID=$(boundary targets create ssh \
  -scope-id "$PROJECT_ID" \
  -name "multihop-ssh-target" \
  -default-port 2222 \
  -session-max-seconds 28800 \
  -ingress-worker-filter '"ingress" in "/tags/type"' \
  -egress-worker-filter '"egress" in "/tags/type"' \
  -token env://BOUNDARY_TOKEN \
  -format=json | jq -r '.item.id')

boundary targets add-host-sources -id "$TARGET_ID" -host-source "$SET_ID" -token env://BOUNDARY_TOKEN
boundary targets set-credential-sources -id "$TARGET_ID" -injected-application-credential-source "$CRED_ID" -token env://BOUNDARY_TOKEN
```

### 9. Connect
```bash
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN
```

---

## 🧹 Resetting the Environment
```bash
./reset.sh
```
This stops all Boundary services, recreates the PostgreSQL container, removes logs, and clears `.env` and cached tokens.
