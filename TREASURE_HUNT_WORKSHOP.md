# 🏴‍☠️ Boundary Chained Troubleshooting Workshop (Target Port & Session Concurrency)

A 2-stage, chained "Escape Room / Treasure Hunt" style dry-run scenario for SRE, platform, and support teams.

Both issues exist **simultaneously in the environment upfront**. As the team solves the first layer (Session Concurrency Lockout), they immediately hit the second layer (Target Port Drift) until the interactive SSH shell is restored!

---

## 🗺️ The Troubleshooting Cascade

```
                                      [ THE USER TICKET ]
                 "Developers cannot connect to the production SSH target ($TARGET_ID):
                       boundary connect ssh -target-id $TARGET_ID
                 Please investigate, identify all root causes, and restore access!"
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🚨 STAGE 1: CONCURRENCY / POLICY LOCKOUT                                                 │
  │ Symptom: Error from controller: target connection limit reached (max: 1 active session)   │
  │ Discovery: Target has session_connection_limit = 1 and an orphaned ghost session is active.│
  │ 🔑 Key 1: Cancel stuck session & lift limit:                                             │
  │           boundary sessions cancel -id $GHOST_SESSION_ID                                  │
  │           boundary targets update ssh -id $TARGET_ID -session-connection-limit -1         │
  └──────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🚨 STAGE 2: DATA PLANE / TARGET PORT DRIFT                                               │
  │ Symptom: Session authorizes, but drops: kex_exchange_identification: Connection closed   │
  │ Discovery: Target default_port is 22, but OpenSSH container is listening on 2222         │
  │            (worker-egress.log: dial tcp 127.0.0.1:22: connect: connection refused).      │
  │ 🔑 Key 2: Update target port:                                                            │
  │           boundary targets update ssh -id $TARGET_ID -default-port 2222                  │
  └──────────────────────────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
  │ 🎉 VICTORY: INTERACTIVE ZERO-TRUST SSH TERMINAL RESTORED                                 │
  │ Client successfully authenticates and enters OpenSSH container via multi-hop worker mesh!│
  └──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Facilitator Guide: Injecting Both Bugs

Run the automated one-touch break script inside your Lima VM (`limactl shell boundary`):

```bash
cd ~/boundary-multihop-setup
source .env

./treasure_hunt_break.sh
```

---

## 🏃 Participant Playbook (Step-by-Step Triage & Solution)

### **STAGE 1: The Concurrency Lockout**

The engineer runs the user's connection command:
```bash
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```

#### 🚨 Error Encountered:
```text
Error authorizing connection: Error from controller: target connection limit reached:
target 'tssh_...' has reached its maximum connection limit of 1 active session(s)
```

#### 🔍 Investigation:
```bash
# 1. Check target limits in Boundary
boundary targets read -id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
# Notice: session_connection_limit: 1

# 2. Check active sessions in the project
boundary sessions list -scope-id "$PROJECT_ID" -recursive -token env://BOUNDARY_TOKEN -keyring-type=none

# 3. Read the stuck ghost session
GHOST_SESSION_ID=$(boundary sessions list -scope-id "$PROJECT_ID" -recursive -token env://BOUNDARY_TOKEN -keyring-type=none -format=json | jq -r '.items[0].id')
boundary sessions read -id "$GHOST_SESSION_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```
*Observation: An orphaned session is holding the single connection slot in `active` state.*

#### 🔑 Key 1 (Resolution):
Cancel the orphaned session and lift the target connection cap:
```bash
# A. Cancel ghost session
boundary sessions cancel -id "$GHOST_SESSION_ID" -token env://BOUNDARY_TOKEN -keyring-type=none

# B. Remove connection limit (-1 = unlimited) and set realistic timeout
boundary targets update ssh \
  -id "$TARGET_ID" \
  -session-connection-limit -1 \
  -session-max-seconds 28800 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

### **STAGE 2: The Port Drift / Egress TCP Refusal**

The engineer re-runs the connect command:
```bash
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```

#### 🚨 Error Encountered:
```text
kex_exchange_identification: Connection closed by remote host
Connection closed by 127.0.0.1 port 52148
```
*(Notice: Controller authorization succeeded and the local proxy started, but the SSH key exchange dropped immediately).*

#### 🔍 Investigation:
```bash
# 1. Check Boundary Target default port
boundary targets read -id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
# Notice: Default Port: 22

# 2. Inspect target container's actual listening port
podman ps --filter "name=ssh-target-box" --format "{{.Names}}: {{.Ports}}"
# Notice: 0.0.0.0:2222->2222/tcp (Target container is listening on port 2222, NOT 22!)

# 3. Check Egress Worker logs
tail -n 20 worker-egress.log | grep -i "error dialing"
# Notice: dial tcp 127.0.0.1:22: connect: connection refused
```
*Observation: Egress worker attempted to dial `127.0.0.1:22` on the target host, but port 22 is closed, returning TCP `ECONNREFUSED`.*

#### 🔑 Key 2 (Resolution):
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
boundary connect ssh -target-id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
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

1. **Controller vs Data Plane Separation**:
   * **Stage 1 (Session Cap)** is enforced by the **Controller** during the gRPC authorization check before any worker proxy channel is opened.
   * **Stage 2 (Port Drift)** passes Controller authorization, but fails on the **Egress Worker** when establishing the physical TCP socket to the upstream service.
2. **Orphaned Sessions in Production**:
   * Abrupt client socket drops leave sessions in `active` state until worker heartbeats time out. Strict target connection caps (`session_connection_limit`) can cause unexpected denial of service unless ungracefully terminated sessions are administratively cancelled.
