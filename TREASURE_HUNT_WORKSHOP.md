# 🏴‍☠️ Boundary Enterprise "Treasure Hunt" Troubleshooting Workshop

A 3-stage, chained "Escape Room / Treasure Hunt" style dry-run scenario for SRE, platform, and support teams. 

All 3 issues exist **simultaneously in the environment upfront**. As the team solves each layer, they hit the next clue until the interactive zero-trust SSH connection is successfully restored!

---

## 🗺️ The Treasure Hunt Cascade

```
                                      [ THE USER TICKET ]
                "I'm trying to connect to production SSH using our team's alias:
                          boundary connect ssh app.infra.devops
                         ...but it fails! Please fix access ASAP."
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🚨 DOOR 1: ALIAS RESOLUTION LAYER                                                        │
  │ Symptom: Error from controller: target not found for alias: "app.infra.devops"           │
  │ Discovery: The alias exists but destination_id is null (unbound).                        │
  │ 🔑 Key 1: Link alias to target: boundary aliases update target -destination-id $TARGET_ID │
  └──────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🚨 DOOR 2: CONCURRENCY / POLICY LAYER                                                    │
  │ Symptom: Error: target connection limit reached (max: 1 active session)                  │
  │ Discovery: Target has session_connection_limit = 1 and an orphaned ghost session is active.│
  │ 🔑 Key 2: Cancel stuck session & remove limit: boundary sessions cancel -id $S_ID        │
  │           boundary targets update ssh -session-connection-limit -1                       │
  └──────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🚨 DOOR 3: DATA PLANE / NETWORK DIAL LAYER                                               │
  │ Symptom: Session authorizes, but drops: kex_exchange_identification: Connection closed   │
  │ Discovery: Target default_port is 22, but OpenSSH container is listening on 2222         │
  │            (worker-egress.log: dial tcp 127.0.0.1:22: connect: connection refused).      │
  │ 🔑 Key 3: Update target port: boundary targets update ssh -default-port 2222             │
  └──────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🎉 VICTORY: INTERACTIVE SSH TERMINAL RESTORED                                            │
  │ Client successfully authenticates and enters OpenSSH container via multi-hop worker mesh!│
  └──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Step 1: Facilitator Script — Inject All 3 Bugs Simultaneously

Run this single injection block inside your Lima VM (`limactl shell boundary`):

```bash
cd ~/boundary-multihop-setup
source .env

echo "==> [1/3] Injecting Bug A: Creating Unbound Alias (destination_id: null)..."
# Ensure scope suffixes exist
boundary scopes set-alias-suffix -id "$ORG_ID" -alias-suffix "devops" -token env://BOUNDARY_TOKEN -keyring-type=none 2>/dev/null || true
boundary scopes set-alias-suffix -id "$PROJECT_ID" -alias-suffix "infra" -token env://BOUNDARY_TOKEN -keyring-type=none 2>/dev/null || true

# Remove existing alias if present and recreate as unbound
EXISTING_ALIAS=$(boundary aliases list -scope-id "$PROJECT_ID" -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.items[]? | select(.value=="app.infra.devops") | .id')
[ -n "$EXISTING_ALIAS" ] && boundary aliases delete -id "$EXISTING_ALIAS" -token env://BOUNDARY_TOKEN -keyring-type=none

ALIAS_ID=$(boundary aliases create target \
  -scope-id "$PROJECT_ID" \
  -name "prod-ssh-alias" \
  -description "Production OpenSSH Target Alias" \
  -value "app.infra.devops" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none \
  -format=json | jq -r '.item.id')

echo "==> [2/3] Injecting Bug B: Setting Target Port to 22 (Drift) & Concurrency Cap to 1..."
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 22 \
  -session-connection-limit 1 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

echo "==> [3/3] Injecting Bug C: Generating Orphaned Ghost Session in DB..."
# Temporarily attach alias to target to authorize a background session that we abruptly kill
boundary aliases update target -id "$ALIAS_ID" -destination-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
boundary connect ssh app.infra.devops -token env://BOUNDARY_TOKEN -keyring-type=none >/dev/null 2>&1 &
BG_PID=$!
sleep 2
kill -9 "$BG_PID" 2>/dev/null || true

# Now unbind the alias again so Door 1 is active!
boundary aliases update target -id "$ALIAS_ID" -destination-id "" -token env://BOUNDARY_TOKEN -keyring-type=none 2>/dev/null || \
boundary aliases update target -id "$ALIAS_ID" -destination-id null -token env://BOUNDARY_TOKEN -keyring-type=none 2>/dev/null || true

echo "=========================================================="
echo " 🏴‍☠️ TREASURE HUNT READY! Hand over ticket to the team."
echo " Initial Command: boundary connect ssh app.infra.devops"
echo "=========================================================="
```

---

## 🏃 Participant Playbook (Step-by-Step Triage & Solution)

### **CLUE 1: The Initial Attempt**

The engineer runs the user's command:
```bash
boundary connect ssh app.infra.devops -token env://BOUNDARY_TOKEN -keyring-type=none
```

#### 🚨 Error Encountered (Door 1):
```text
Error authorizing connection: Error from controller: target not found for alias: "app.infra.devops"
```

#### 🔍 Investigation:
```bash
# 1. Look up the alias in the project scope
boundary aliases list -scope-id "$PROJECT_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

# 2. Read the alias details
boundary aliases read -id "$ALIAS_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```
*Observation: `Destination ID` is blank (`null`). The alias is not attached to any target!*

#### 🔑 Key 1 (Resolution):
Link the alias to the target `$TARGET_ID`:
```bash
boundary aliases update target \
  -id "$ALIAS_ID" \
  -destination-id "$TARGET_ID" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

### **CLUE 2: The Concurrency Lockout**

The engineer re-runs the connect command:
```bash
boundary connect ssh app.infra.devops -token env://BOUNDARY_TOKEN -keyring-type=none
```

#### 🚨 Error Encountered (Door 2):
```text
Error authorizing connection: Error from controller: target connection limit reached:
target 't_ssh1234567890' has reached its maximum connection limit of 1 active session(s)
```

#### 🔍 Investigation:
```bash
# 1. Check target limits
boundary targets read -id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
# Notice: session_connection_limit: 1

# 2. Check active sessions in the project
boundary sessions list -scope-id "$PROJECT_ID" -recursive -token env://BOUNDARY_TOKEN -keyring-type=none

# 3. Read the stuck session
GHOST_SESSION_ID=$(boundary sessions list -scope-id "$PROJECT_ID" -recursive -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.items[0].id')
boundary sessions read -id "$GHOST_SESSION_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```
*Observation: An orphaned session is holding the single connection slot in `active` state.*

#### 🔑 Key 2 (Resolution):
Cancel the orphaned session and lift the target connection cap:
```bash
# A. Cancel ghost session
boundary sessions cancel -id "$GHOST_SESSION_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

# B. Remove connection limit (-1 = unlimited)
boundary targets update ssh \
  -id "$TARGET_ID" \
  -session-connection-limit -1 \
  -session-max-seconds 28800 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

### **CLUE 3: The Protocol Drop / Port Drift**

The engineer re-runs the connect command:
```bash
boundary connect ssh app.infra.devops -token env://BOUNDARY_TOKEN -keyring-type=none
```

#### 🚨 Error Encountered (Door 3):
```text
kex_exchange_identification: Connection closed by remote host
Connection closed by 127.0.0.1 port 52148
```
*(Controller authorization succeeded, but the local SSH proxy tunnel closed immediately).*

#### 🔍 Investigation:
```bash
# 1. Check Boundary Target default port
boundary targets read -id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
# Notice: Default Port: 22

# 2. Inspect target container's actual listening port
podman ps --filter "name=ssh-target-box" --format "{{.Names}}: {{.Ports}}"
# Notice: 0.0.0.0:2222->2222/tcp (Target is listening on 2222, NOT 22!)

# 3. Check Egress Worker logs
tail -n 20 worker-egress.log | grep -i "error dialing"
# Notice: dial tcp 127.0.0.1:22: connect: connection refused
```
*Observation: The Egress worker received a TCP `RST` because port 22 is closed on the target host.*

#### 🔑 Key 3 (Resolution):
Update the target default port to `2222`:
```bash
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 2222 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

### **🎉 VICTORY: Interactive Shell Restored**

The engineer runs the final connect command:

```bash
boundary connect ssh app.infra.devops -token env://BOUNDARY_TOKEN -keyring-type=none
```

#### Output:
```text
Linux ssh-target-box 6.6.0 #1 SMP PREEMPT_DYNAMIC Linux
testuser@ssh-target-box:~$ whoami
testuser
testuser@ssh-target-box:~$ hostname
ssh-target-box
```

---

## 📋 Facilitator Debrief Key Takeaways

1. **Layered Failure Isolation**:
   * **Door 1 (Alias)** failed at the **Catalog Lookup Phase** (No target mapped).
   * **Door 2 (Session Limit)** failed at the **Controller Authorization Phase** (RBAC & Policy check).
   * **Door 3 (Port Drift)** passed authorization and failed at the **Worker Data Plane Phase** (Egress TCP dial).
2. **Why this ordering works seamlessly**:
   * Boundary evaluates authorization prerequisites strictly sequentially:
     `Alias Resolution ➔ Scope/Target RBAC & Concurrency Checks ➔ Worker Mesh DAG Route ➔ Worker TCP Socket Dial ➔ L7 Protocol Injected Credential Handshake`.
