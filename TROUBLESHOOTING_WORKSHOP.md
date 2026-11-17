# Boundary Enterprise Troubleshooting Workshop: Team Dry-Run Scenario

A hands-on, multi-stage troubleshooting workshop designed for platform, SRE, and support engineering teams. This scenario simulates real-world production outages and misconfigurations across **Targets**, **Connect/Connection Routing (Worker Mesh)**, and **Session Management**.

---

## 🎯 Workshop Overview & Architecture Baseline

### Topology Baseline
```
+----------------------------------------------------------------------------------------------------+
|                                      BOUNDARY ENTERPRISE FABRIC                                    |
|                                                                                                    |
|   +--------------------+       gRPC Authz       +----------------------------------------------+   |
|   |   Boundary CLI     | ---------------------> |              Boundary Controller             |   |
|   |   (Local Machine)  |                        |                 (Port :9200)                 |   |
|   +--------------------+                        +----------------------------------------------+   |
|             |                                                              |                       |
|             | Proxy Listener                                               | Multi-Hop DAG         |
|             v                                                              v Evaluation            |
|   +--------------------+     Mutual TLS Encrypted     +--------------------+                       |
|   |   Ingress Worker   | ===========================> |   Egress Worker    |                       |
|   |    (Port :9202)    |       (Upstream Peering)     |    (Port :9204)    |                       |
|   |    tags: ingress   |                              |    tags: egress    |                       |
|   +--------------------+                              +--------------------+                       |
|                                                                 |                                  |
|                                                                 | Injected Dynamic Credentials     |
|                                                                 v                                  |
|                                                       +--------------------+                       |
|                                                       | Target: OpenSSH/DB |                       |
|                                                       |    (Port :2222)    |                       |
|                                                       +--------------------+                       |
+----------------------------------------------------------------------------------------------------+
```

---

## 🛠️ Team Dry-Run Execution Matrix

| Stage | Domain | Failure Mode | Team Investigation Goal |
|---|---|---|---|
| **Issue 1A** | **Target Configuration** | L7 Credential Source Mismatch | Differentiate Brokered vs Injected Credential Sources |
| **Issue 1B** | **Target Port & Data Path** | Default Port Drift & Egress Connection Refusal | Triage Egress Worker TCP dial failure vs Authz success |
| **Issue 2** | **Connect / Routing** | Multi-Hop Worker Mesh DAG Route Breakage | Trace Ingress/Egress worker peering & tag filters |
| **Issue 3** | **Session Management** | Concurrency Lockout & Stale Session State | Identify stuck sessions, enforce cancellation & adjust limits |

---

## 🔴 Issue 1A: Target Level — "Credential Source Incompatibility"

### 1. Simulated Problem
A developer attempts to connect to the dedicated production OpenSSH server via Boundary L7 SSH target. The connection is immediately rejected by the Controller during the authorization phase.

### 2. Error Output (CLI)
```bash
$ boundary connect ssh -target-id t_ssh1234567890

Error authorizing connection: Error from controller: target credential source or host set binding invalid:
* credential library 'cl_stat123456' cannot be used for target type 'ssh' as a brokered credential source
* injected application credential source is required for L7 SSH targets
```

### 3. Root Cause
The team attached a static credential library as a `-brokered-credential-source` instead of an `-injected-application-credential-source`. L7 SSH targets terminate the protocol on the worker to inject credentials directly on the wire.

### 4. Step-by-Step Triage & Investigation
1. **Inspect Target Attributes:**
   ```bash
   boundary targets read -id t_ssh1234567890
   ```
   *Observe that `brokered_credential_source_ids` is populated while `injected_application_credential_source_ids` is empty.*

### 5. Resolution & Verification
```bash
# A. Remove incorrect brokered credential source
boundary targets remove-credential-sources \
  -id t_ssh1234567890 \
  -brokered-credential-source cl_stat123456

# B. Attach as an Injected Application Credential Source
boundary targets set-credential-sources \
  -id t_ssh1234567890 \
  -injected-application-credential-source cl_stat123456
```

---

## 🔴 Issue 1B: Target Level — "Target Default Port Drift & Egress TCP Dial Failure"

### 1. Simulated Problem (How to Break It)
To simulate this failure for your team, update the target default port from `2222` to the standard Linux SSH port `22`:

```bash
# INJECT BUG:
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 22 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

When engineers run `boundary connect ssh`, the session **authorizes successfully** at the Controller, but when the local SSH client attempts to negotiate the key exchange over the proxy tunnel, the connection instantly terminates!

### 2. Error Output (Client CLI)
```bash
$ boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

kex_exchange_identification: Connection closed by remote host
Connection closed by 127.0.0.1 port 52148
```

### 3. Root Cause
1. **Controller vs Data Path Disconnect:** Boundary Controller's authorization phase only verifies RBAC and worker DAG routing—it does not probe the target's physical port.
2. **Egress Worker Dial Failure:** When the client proxy listener opens, the Egress Worker dials `127.0.0.1:22`. Because the target container runs on port `2222`, the operating system issues a TCP `RST` (`ECONNREFUSED`), abruptly closing the data stream.

### 4. Step-by-Step Triage & Investigation

1. **Check Target Configuration:**
   ```bash
   boundary targets read -id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
   ```
   *Notice `Default Port: 22`.*

2. **Check Upstream Target Listening Ports (Container Inspection):**
   ```bash
   podman ps --filter "name=ssh-target-box" --format "{{.Names}}: {{.Ports}}"
   ```
   *Output shows `0.0.0.0:2222->2222/tcp`. Port 22 is NOT exposed on the host.*

3. **Inspect Egress Worker Logs:**
   ```bash
   tail -n 30 worker-egress.log
   ```
   *Look for dial failure:*
   ```text
   {"@level":"error","@message":"error dialing target host","address":"127.0.0.1:22","error":"dial tcp 127.0.0.1:22: connect: connection refused"}
   ```

### 5. Resolution & Verification
```bash
# A. Correct Target default port to 2222
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 2222 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

# B. Reconnect and verify smooth interactive shell
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```

---

## 🔴 Issue 2: Connect Level — "Multi-Hop Worker Mesh DAG Route Failure"

### 1. Simulated Problem (How to Break It)
Change the Egress Worker's `initial_upstreams` in `worker-egress.hcl` to point to the Controller cluster port (`127.0.0.1:9201`) instead of the Ingress Worker proxy port (`127.0.0.1:9202`), then restart the egress worker.

### 2. Error Output (CLI)
```bash
$ boundary connect -target-id "$TARGET_ID"

Error authorizing connection: Error from controller: no path found through worker graph to satisfy ingress/egress filter:
no workers found matching egress filter '"egress" in "/tags/type"' connected to ingress filter '"ingress" in "/tags/type"'
```

### 3. Root Cause
Because no direct or multi-hop worker-to-worker stream exists between the ingress tag pool and egress tag pool, the Controller's routing DAG engine (`filterWorkersEnt`) detects a disconnected graph and rejects session authorization.

### 4. Step-by-Step Triage & Investigation
1. **Inspect Registered Workers and Tags:**
   ```bash
   boundary workers list -token env://BOUNDARY_TOKEN -keyring-type=none
   ```
2. **Review Target Worker Filters:**
   ```bash
   boundary targets read -id "$TARGET_ID" -format=json -token env://BOUNDARY_TOKEN -keyring-type=none | jq '{
     ingress_filter: .item.attributes.ingress_worker_filter,
     egress_filter: .item.attributes.egress_worker_filter
   }'
   ```
3. **Inspect Egress Worker Configuration:**
   Check `worker-egress.hcl` for `initial_upstreams`.

### 5. Resolution & Verification
```bash
# A. Edit worker-egress.hcl to peer with Ingress Worker proxy listener:
# initial_upstreams = ["127.0.0.1:9202"]

# B. Restart Egress Worker
pkill -f "worker-egress"
boundary server -config ./worker-egress.hcl > worker-egress.log 2>&1 &

# C. Verify Worker graph connectivity and retry
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```

---

## 🔴 Issue 3: Session Management Level — "Concurrency Lockout & Orphaned Session Freeze"

### 1. Simulated Problem (How to Break It)
Set the target connection limit to `1`:
```bash
boundary targets update ssh \
  -id "$TARGET_ID" \
  -session-connection-limit 1 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```
Open a connection in one terminal, kill the client process abruptly (`pkill -9 ssh`), and immediately try to connect from another terminal.

### 2. Error Output (CLI)
```bash
$ boundary connect ssh -target-id "$TARGET_ID"

Error authorizing connection: Error from controller: target connection limit reached:
target 't_ssh1234567890' has reached its maximum connection limit of 1 active session(s)
```

### 3. Root Cause
An abrupt client disconnect leaves the session in `active` state in the Controller database until worker heartbeat garbage collection runs. Since `session_connection_limit = 1`, all new sessions are blocked.

### 4. Step-by-Step Triage & Investigation
1. **List Active Sessions for Scope:**
   ```bash
   boundary sessions list -scope-id "$PROJECT_ID" -recursive -token env://BOUNDARY_TOKEN -keyring-type=none
   ```
2. **Inspect Problematic Session:**
   ```bash
   boundary sessions read -id "$SESSION_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
   ```

### 5. Resolution & Verification
```bash
# A. Administratively terminate the orphaned session immediately
boundary sessions cancel -id "$SESSION_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

# B. Update target for concurrent team access
boundary targets update ssh \
  -id "$TARGET_ID" \
  -session-connection-limit -1 \
  -session-max-seconds 28800 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

# C. Verify smooth reconnect
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```

---

## 📋 Team Debrief & Facilitator Cheat Sheet

| Question for Team | Expected Answer / Insight |
|---|---|
| **Why does a target port mismatch pass authorization but fail during connect?** | Authorization only checks RBAC, tokens, and worker routing DAGs. Physical TCP connection to the upstream target port happens on the Egress Worker during the data transfer phase. |
| **Why can't Layer 7 SSH targets use `-brokered-credential-source`?** | L7 SSH targets terminate the protocol on the worker to inject dynamic certs/passwords on the wire. Brokered credentials return secrets directly to the client endpoint (used for L4 TCP/databases). |
| **How does Boundary construct multi-hop worker routes?** | The Controller's DAG engine builds a directed path from Ingress workers matching `ingress_worker_filter` to Egress workers matching `egress_worker_filter` based on active worker upstream peering connections. |
| **What happens to sessions when client crashes?** | If the client socket drops without clean termination, the session remains active until worker heartbeats time out or an admin issues `boundary sessions cancel`. |
