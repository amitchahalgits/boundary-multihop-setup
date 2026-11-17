# Boundary Target Breaking Scenarios & Hands-On Triage Guide

A practical, hands-on workshop guide for simulating, diagnosing, and resolving real-world **Boundary Target** and **Target Alias** failures.

---

## 🎯 Scenario Matrix

| Scenario | Domain | Injected Failure | Observable Symptom | Key Learning Point |
|---|---|---|---|---|
| **Scenario 1** | **Target Alias** | Unbound Alias (`destination_id: null`) & Scope Suffix Missing | `target not found for alias` / `Project alias suffix is not configured` | Aliases can exist without destinations; project-scoped aliases require hierarchical DNS namespacing. |
| **Scenario 2** | **Target Port Drift** | Port Mismatch (`22` vs `2222`) | Authz succeeds, but data proxy drops: `kex_exchange_identification: Connection closed` | Controller authorizes session via policy/DAG, but Egress Worker fails physical TCP dial (`ECONNREFUSED`). |

---

## 🧪 Scenario 1: Unbound Target Alias & Scope Suffix Enforcement

### Overview
This scenario demonstrates what happens when developers attempt to use human-friendly DNS aliases that have either been pre-provisioned without a destination target, or created without complying with Boundary's project-level scope suffix hierarchy.

```
+----------------------------------------------------------------------------------------------------+
|                                    SCENARIO 1: ALIAS RESOLUTION FLOW                               |
|                                                                                                    |
|   +--------------------------+                                                                     |
|   |   Developer / CLI        |                                                                     |
|   |   "app.infra.devops"     |                                                                     |
|   +--------------------------+                                                                     |
|                |                                                                                   |
|                | 1. gRPC Lookup: Resolve Alias                                                     |
|                v                                                                                   |
|   +--------------------------+                                                                     |
|   |   Boundary Controller    |                                                                     |
|   |   (Database Lookup)      |                                                                     |
|   +--------------------------+                                                                     |
|                |                                                                                   |
|                +---> [ Case A: Missing Scope Suffix ] ===> ERROR 400: Project alias suffix missing |
|                |                                                                                   |
|                +---> [ Case B: destination_id == null ] => ERROR: Target not found for alias       |
|                |                                                                                   |
|                +---> [ Case C: destination_id == tssh_.. ] => 2. Authorized -> Proxy to Worker     |
+----------------------------------------------------------------------------------------------------+
```

---

### Step 1: Inject Bug 1A — Missing Project Scope Suffix
When attempting to create a project-scoped alias without an org/project suffix:

```bash
# Attempt to create an alias inside a Project without configuring suffixes
boundary aliases create target \
  -scope-id "$PROJECT_ID" \
  -name "pre-provisioned-service" \
  -value "app.devops.internal" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

#### Observed Error
```json
{
  "context": "Error from controller when performing create on target-type alias",
  "status_code": 400,
  "api_error": {
    "kind": "InvalidArgument",
    "message": "Project alias suffix is not configured.",
    "details": {
      "request_fields": [
        {
          "name": "scope_id",
          "description": "Project scope \"p_...\" must have an alias suffix configured before project-scoped aliases can be created."
        }
      ]
    }
  }
}
```

#### Fix for Bug 1A
Configure the suffix on the Org and Project to establish the DNS namespace hierarchy:
```bash
# 1. Set Org suffix
boundary scopes set-alias-suffix \
  -id "$ORG_ID" \
  -alias-suffix "devops" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

# 2. Set Project suffix
boundary scopes set-alias-suffix \
  -id "$PROJECT_ID" \
  -alias-suffix "infra" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

### Step 2: Inject Bug 1B — Unbound Alias (`destination_id: null`)
Create an alias matching the suffix pattern (`<name>.<project_suffix>.<org_suffix>`) without a destination target:

```bash
ALIAS_ID=$(boundary aliases create target \
  -scope-id "$PROJECT_ID" \
  -name "pre-provisioned-service" \
  -description "Alias prepared before target deployment" \
  -value "app.infra.devops" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none \
  -format=json | jq -r '.item.id')

echo "Created Unbound Alias ID: $ALIAS_ID"
```

#### Trigger the Failure
Attempt to connect using the alias before it points to an active target:

```bash
boundary connect ssh app.infra.devops \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

#### Observed Error
```text
Error authorizing connection: Error from controller: target not found for alias: "app.infra.devops"
```

---

### Step 3: Triage & Investigation
1. **Inspect Alias Metadata:**
   ```bash
   boundary aliases read -id "$ALIAS_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
   ```
   *Notice `Destination ID: (null / blank)`.*

2. **Verify Target Availability:**
   ```bash
   boundary targets list -scope-id "$PROJECT_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
   ```

---

### Step 4: Resolution & Verification
Bind the alias to the active target `$TARGET_ID`:

```bash
# 1. Update alias with destination target
boundary aliases update target \
  -id "$ALIAS_ID" \
  -destination-id "$TARGET_ID" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none

# 2. Verify connection succeeds seamlessly using the alias
boundary connect ssh app.infra.devops \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

## 🧪 Scenario 2: Target Port Drift & Upstream Egress Connection Refusal

### Overview
In this scenario, a target is created with default port `22` (the default Linux SSH port), but the containerized target service is actually listening on port `2222`.

```
+----------------------------------------------------------------------------------------------------+
|                                SCENARIO 2: TARGET PORT DRIFT FAILURE                               |
|                                                                                                    |
|   1. boundary connect ssh -target-id $TARGET_ID                                                    |
|           │                                                                                        |
|           ▼                                                                                        |
|   [ Boundary Controller ]  ──► Validates RBAC & DAG ──► ✅ Session Authorized (Authz Token Issued)  |
|           │                                                                                        |
|           ▼ (Data Plane Proxy Channel)                                                             |
|   [ Ingress Worker ] (:9202)                                                                       |
|           │                                                                                        |
|           ▼ (Mutual TLS Mesh)                                                                      |
|   [ Egress Worker ] (:9204)                                                                        |
|           │                                                                                        |
|           ▼ Dials Host: 127.0.0.1:22                                                               |
|   [ Target Container ]                                                                             |
|      (Listening on :2222, NOT :22) ──► ❌ Kernel issues TCP RST (ECONNREFUSED)                      |
|                                                                                                    |
|   RESULT: Local proxy drops immediately -> "kex_exchange_identification: Connection closed"        |
+----------------------------------------------------------------------------------------------------+
```

---

### Step 1: Inject Bug (Break It)
Update the target default port from `2222` to `22`:

```bash
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 22 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

### Step 2: Trigger the Failure
Run the connect command:

```bash
boundary connect ssh -target-id "$TARGET_ID" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

#### Observed Error (Client Output)
```text
kex_exchange_identification: Connection closed by remote host
Connection closed by 127.0.0.1 port 52148
```

*(Notice that the command did NOT fail with an authorization error—the session authorized, but the proxy connection dropped immediately upon TCP key exchange).*

---

### Step 3: Triage & Investigation

#### 1. Inspect Boundary Target Configuration
```bash
boundary targets read -id "$TARGET_ID" -token env://BOUNDARY_TOKEN -keyring-type=none
```
*Look at `Default Port`. Observe `22`.*

#### 2. Inspect Target Service Listening Ports (Container Inspection)
```bash
podman ps --filter "name=ssh-target-box" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```
*Output reveals port mapping: `0.0.0.0:2222->2222/tcp`. The container is listening on port 2222, not 22.*

#### 3. Inspect Egress Worker Logs
```bash
tail -n 25 worker-egress.log
```
*Observe Egress Worker connection refusal:*
```json
{
  "@level": "error",
  "@message": "error dialing target host",
  "address": "127.0.0.1:22",
  "error": "dial tcp 127.0.0.1:22: connect: connection refused"
}
```

---

### Step 4: Resolution & Verification

#### 1. Update Target Default Port to 2222
```bash
boundary targets update ssh \
  -id "$TARGET_ID" \
  -default-port 2222 \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

#### 2. Verify Successful Connection
```bash
boundary connect ssh -target-id "$TARGET_ID" \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

Or connect via the configured alias:
```bash
boundary connect ssh app.infra.devops \
  -token env://BOUNDARY_TOKEN \
  -keyring-type=none
```

---

## 💡 Key Architectural Takeaways for SRE & Platform Teams

1. **Controller vs Data Plane Separation**:
   * Controller authorization only checks **identity, RBAC policy, and worker DAG routing paths**.
   * Controller does **not** probe whether the physical upstream target port is open or healthy.
   * If a session authorizes but immediately disconnects, check **Egress Worker logs** (`error dialing target host`) and **target host reachability/ports**.

2. **Alias Decoupling & Lifecycle**:
   * Target aliases can be safely created as placeholders before backend targets or host sets exist.
   * Project-scoped aliases require both `Org` and `Project` scope suffixes configured to enforce unique DNS namespacing.
   * Deleting an underlying target does not destroy the alias; it gracefully resets the alias's `destination_id` to `null`.
