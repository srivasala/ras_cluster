# OMC Remote Attestation Service (RAS) REST API — Feature Study (Phase 1)

## 1. Study Document Title

OMC-69581: OMC Remote Attestation Service REST API - Study (Phase 1)

## 2. Description

### Background — Why Not Expose Keylime APIs Directly

Keylime provides a Verifier API and a Registrar API, each serving a distinct role in the attestation lifecycle. Directly exposing these APIs to OMC customers is not viable for the following reasons:

1. **Split data model** — Agent identity lives in the Registrar; attestation state lives in the Verifier. A customer would need to call two separate APIs and correlate the results to get a complete view of an agent. The OMC API must present a unified agent resource.
2. **Sensitive field exposure** — Keylime APIs return TPM cryptographic keys (`ek_tpm`, `aik_tpm`, `revocation_key`), policy internals, and internal state fields. Exposing these to customers creates security risks (see Section 5.4).
3. **Internal state representation** — Keylime represents agent state as an integer `operational_state` (0–10) with no customer-friendly semantics. The OMC layer must derive a meaningful state model (`pass`, `fail`, `paused`, etc.).
4. **No pagination** — Keylime's list endpoints return all agents in a single response with no pagination support. This does not scale for customer-facing APIs.
5. **No bulk write operations** — All Keylime write operations (attest, stop, resume, delete) are per-agent. The OMC layer must orchestrate multi-step workflows (e.g., fetching registrar data before enrolling in verifier). Bulk write operations are covered in Phase 2 of this study.
6. **API documentation lags behind code** — Keylime's REST API docs (reStructuredText) do not reflect recent code changes (e.g., `attestation_status` field added in v7.14.0 is not documented). Relying on Keylime docs for a customer-facing contract is unreliable.

### What This Feature Delivers

This feature introduces a set of REST APIs for the OMC Remote Attestation Service (RAS) that wraps the Keylime attestation framework. The OMC RAS API provides a customer-facing abstraction layer over Keylime's Verifier and Registrar APIs, offering:

- Unified agent lifecycle management (registration, attestation, pause/resume, removal)
- Derived `state` model that abstracts Keylime's internal `operational_state` integers (named `state` to avoid confusion with Keylime's native `attestation_status` field added in v7.14.0)
- Sensitive field filtering to prevent exposure of TPM keys, policy internals, and crypto material
- Pagination, filtering, and phased caching/persistence strategy

**Scope:**
- 7 REST API endpoints covering agent listing, detail, attestation, stop, resume, remove attestation, and full deletion
- 3-phase backend evolution: Phase 1 (direct aggregation), Phase 2 (cache), Phase 3 (OMC DB)
- Consistent hashing for verifier assignment in multi-verifier deployments
- StatefulSet-based deployment for stable verifier identity

**Keylime Version Baseline:** This study is based on Keylime v7.13.0 (current deployment) and v7.14.1 (upgraded deployment), covering API versions v2.4 and v2.5. API v3.0 is excluded from this study because it introduces an entirely different verifier API surface for push-mode attestation (new endpoints, new state model, new authentication mechanism) that is not backward compatible with the v2.x pull-mode endpoints used in this study. Note that v2.x and v3.0 coexist on the same verifier — excluding v3.0 from this study does not affect pull-mode functionality.

### 2.1. RAS Use-Case Scope Map

This section establishes the full universe of RAS use-cases derived from the Keylime attestation architecture, and classifies each by coverage status. This enables reviewers to assess the completeness of this study increment.

| # | Use-Case | Category | Coverage | Study/Phase | Rationale |
|---|---|---|---|---|---|
| 1 | Agent Registration (TPM handshake) | Agent Lifecycle | Out of scope | N/A | Agent-initiated: the Keylime agent registers itself with the registrar at startup via a two-phase TPM challenge-response (EK/AIK). This is not a customer-triggered operation and cannot be exposed as an OMC API. See note [1] below. |
| 2 | Agent Re-registration (on restart) | Agent Lifecycle | Out of scope | N/A | Automatic: agent re-registers unconditionally on every restart. Registrar accepts re-registration transparently. No OMC intervention needed. |
| 3 | List Agents | Agent Lifecycle | ✅ Covered | Phase 1 — UC-1 | |
| 4 | Get Agent Detail | Agent Lifecycle | ✅ Covered | Phase 1 — UC-2 | |
| 5 | Delete Agent (full removal) | Agent Lifecycle | ✅ Covered | Phase 1 — UC-7 | |
| 6 | Initiate Attestation | Attestation Lifecycle | ✅ Covered | Phase 1 — UC-3 | Enrolls agent in verifier using registrar data |
| 7 | Stop Attestation | Attestation Lifecycle | ✅ Covered | Phase 1 — UC-4 | |
| 8 | Resume Attestation | Attestation Lifecycle | ✅ Covered | Phase 1 — UC-5 | |
| 9 | Remove Attestation (verifier only) | Attestation Lifecycle | ✅ Covered | Phase 1 — UC-6 | |
| 10 | Bulk Attest | Bulk Operations | ✅ Covered | Phase 2 — UC-B1 | |
| 11 | Bulk Stop/Resume | Bulk Operations | ✅ Covered | Phase 2 — UC-B2 | |
| 12 | Bulk Remove Attestation | Bulk Operations | ✅ Covered | Phase 2 — UC-B3 | |
| 13 | Bulk Delete | Bulk Operations | ✅ Covered | Phase 2 — UC-B4 | |
| 14 | Set/Update IMA Runtime Policy | Policy Management | Deferred | Future study | Keylime supports runtime policy via `tpm_policy` and `runtime_policy_name` fields on verifier POST. OMC currently uses defaults. CRUD for customer-managed policies requires a separate policy management API. |
| 15 | Set/Update Measured Boot Policy | Policy Management | Deferred | Future study | Same as above for measured boot reference state (`mb_refstate`). |
| 16 | Get Policy Status | Policy Management | Partial | Phase 1 — UC-2 | Exposed as `hasRuntimePolicy` and `hasMbPolicy` booleans in agent detail. Full policy content is not exposed (classified as sensitive). |
| 17 | Revocation Notification Handling | Revocation | Out of scope | N/A | Keylime-internal mechanism. Revocation actions (webhook, script execution) are configured at the Keylime level, not exposed to OMC customers. Agent failure resulting from revocation is visible via `state=fail`. |
| 18 | Push-mode Attestation | Attestation Lifecycle | Excluded | Separate study | Keylime API v3.0 introduces an entirely different API surface for push-mode. Excluded from this study (pull-mode only). See Keylime Version Baseline above. |
| 19 | State History / Audit Trail | Observability | Planned | Phase 3 | Requires OMC-managed DB to persist state transitions. |
| 20 | Agent Health Dashboard Data | Observability | Partial | Phase 1 — UC-1, UC-2 | Agent state, last quote timestamp, and attestation count are available. Aggregated dashboard metrics (counts by state) require Phase 2 cache. |

**Coverage summary:** 13 of 20 use-cases are fully covered across Phase 1 and Phase 2. 2 are partially covered. 3 are architecturally out of scope. 2 are deferred to future studies.

**Notes:**

[1] **Why registration is not an OMC API:** Keylime agent registration is a TPM-bound handshake initiated by the agent process at startup. The agent sends its TPM Endorsement Key (EK) and Attestation Identity Key (AIK) to the registrar, which encrypts a challenge using the EK. The agent decrypts via TPM `activate_credential` and returns proof. This is a machine-to-machine trust establishment protocol — there is no customer action to trigger or parameter to configure. The OMC state model reflects registration as the `registered` state (agent exists in registrar but not yet enrolled in verifier). The customer-triggered transition from `registered` to `pending` is via UC-3 (Attest Agent).

## 3. Requirement SOC

| Requirement Section | SOC | SOC Info | Comments |
|---|---|---|---|
| List all agents with pagination | Yes | UC-1 | Keylime has no native pagination; OMC implements cursor-based pagination |
| Get agent detail with state | Yes | UC-2 | Merges Verifier + Registrar data; derives `state` from `operational_state` |
| Initiate attestation for agent | Yes | UC-3 | OMC orchestrates registrar data fetch + verifier POST |
| Stop attestation | Yes | UC-4 | Maps to Keylime `PUT /agents/{id}/stop` |
| Resume attestation | Yes | UC-5 | Maps to Keylime `PUT /agents/{id}/reactivate` |
| Remove attestation (verifier only) | Yes | UC-6 | Maps to Keylime `DELETE /agents/{id}` on verifier |
| Delete agent (full removal) | Yes | UC-7 | Ordered deletion: verifier first, then registrar |
| Sensitive field filtering | Yes | All UCs | Crypto keys, policy internals, internal state omitted |

## 4. Anatomy

### 4.1. Use-Cases

| UC | Endpoint | Method | Description |
|---|---|---|---|
| UC-1 | `/ras/v1.0/agents` | GET | List all agents with pagination and filtering |
| UC-2 | `/ras/v1.0/agents/{id}` | GET | Get agent detail including current `state` |
| UC-3 | `/ras/v1.0/agents/{id}/attestation` | POST | Initiate attestation for an agent |
| UC-4 | `/ras/v1.0/agents/{id}/attestation` | PATCH | Stop attestation (set state to paused) |
| UC-5 | `/ras/v1.0/agents/{id}/attestation` | PATCH | Resume attestation (reactivate) |
| UC-6 | `/ras/v1.0/agents/{id}/attestation` | DELETE | Remove from verifier, keep registration |
| UC-7 | `/ras/v1.0/agents/{id}` | DELETE | Full removal from verifier + registrar |

#### 4.1.1. Use-Case Effort Estimates and Impacted Areas

| Use-Case | Effort Estimate (PW) | Impacted Area |
|---|---|---|
| UC-1: List Agents | 3 | OMC RAS service, Registrar client, Verifier client |
| UC-2: Agent Detail | 2 | OMC RAS service, Registrar client, Verifier client |
| UC-3: Attest Agent | 3 | OMC RAS service, Verifier client, Registrar client, Hash ring |
| UC-4: Stop Attestation | 1 | OMC RAS service, Verifier client |
| UC-5: Resume Attestation | 1 | OMC RAS service, Verifier client |
| UC-6: Remove Attestation | 1 | OMC RAS service, Verifier client |
| UC-7: Delete Agent | 2 | OMC RAS service, Verifier client, Registrar client |

### 4.2. Implementation Stories

| Phase | Scope | UCs Delivered | Backend | Filtering | Pagination |
|---|---|---|---|---|---|
| Phase 1 | Direct aggregation | All 7 UCs | Live Keylime calls on every request | `verifierId` only | OMC-side cursor over full result set; limit capped at 50 |
| Phase 2 | Redis cache | All 7 UCs | Read-through cache + background poller (TTL 60–300s) | `state`, `verifierId` | Cache-backed; limit up to 200 |
| Phase 3 | OMC-managed DB | All 7 UCs + state history | Persistent DB synced via background poller | Full: `state`, `verifierId`, multi-state | DB-native pagination; state history queries |

**Phase transition criteria:**
- Phase 1 → 2: When agent count exceeds 100 or list API latency exceeds 2s at p95
- Phase 2 → 3: When state filtering, multi-state queries, or state history are required by customers

## 5. Details

---

### 5.1. Keylime API Mapping

This section establishes how each OMC endpoint maps to the underlying Keylime APIs. Understanding these mappings is a prerequisite for the state model, transformation logic, and field classification that follow.

| OMC Endpoint | Keylime API(s) | Notes |
|---|---|---|
| `GET /ras/v1.0/agents` | Registrar: `GET /v2.x/agents/` + Verifier: `GET /v2.x/agents/?bulk=True` | Registrar returns UUID list only; Verifier bulk returns full status per agent |
| `GET /ras/v1.0/agents/{id}` | Verifier: `GET /v2.x/agents/{id}` + Registrar: `GET /v2.x/agents/{id}` | Merge both responses |
| `POST /ras/v1.0/agents/{id}/attestation` | Registrar: `GET /v2.x/agents/{id}` (fetch keys) → Verifier: `POST /v2.x/agents/{id}` | OMC assembles full POST body from registrar data |
| `PATCH /ras/v1.0/agents/{id}/attestation` (stop) | Verifier: `PUT /v2.x/agents/{id}/stop` | Sets `operational_state = 10 (TENANT_FAILED)` |
| `PATCH /ras/v1.0/agents/{id}/attestation` (resume) | Verifier: `PUT /v2.x/agents/{id}/reactivate` | Keylime does NOT validate current state — returns 200 and restarts polling from any state. OMC must validate state before calling. |
| `DELETE /ras/v1.0/agents/{id}/attestation` | Verifier: `DELETE /v2.x/agents/{id}` | Verifier only; agent stays in registrar |
| `DELETE /ras/v1.0/agents/{id}` | Verifier: `DELETE /v2.x/agents/{id}` → Registrar: `DELETE /v2.x/agents/{id}` | Ordered: verifier first, then registrar |

**Important Keylime behaviors validated from source code:**

1. **Verifier DELETE** returns `202 Accepted` (not 200) when agent is in active polling states (GET_QUOTE, PROVIDE_V, etc.) — it sets state to TERMINATED and the polling loop handles cleanup. Returns `200` only for already-inactive states (SAVED, FAILED, TERMINATED, TENANT_FAILED, INVALID_QUOTE).
2. **Verifier POST** (add agent) automatically stamps `verifier_id` from the pod's config — there is no field in the request body to specify it.
3. **Reactivate** does NOT validate current state before accepting — it returns 200 even for agents in FAILED state. The `APPROVED_REACTIVATE_STATES` check only applies during startup agent recovery, not the PUT endpoint.
4. **Stop** sets `operational_state = TENANT_FAILED (10)` — same state as a tenant-initiated failure. There is no distinct "paused" state in Keylime.
5. **Bulk read** (`?bulk=True`) is the ONLY bulk API. All write operations (POST, PUT, DELETE) are strictly per-agent.

---

### 5.2. OMC Agent State Model

The OMC layer derives a unified `state` field from Keylime's `operational_state` integer. This is the **primary trust signal** exposed to customers.

**Naming rationale:** The OMC field is named `state` (not `attestation_status`) to avoid confusion with Keylime's native `attestation_status` field added in v7.14.0, which collapses 11 states into 3 values (`PASS`/`FAIL`/`PENDING`) and loses critical distinctions such as paused vs failed.

**Source of truth:** `operational_state` (available in all Keylime versions).

| OMC `state` | Keylime `operational_state` | Meaning | GUI Action |
|---|---|---|---|
| `registered` | Agent in registrar only, NOT in verifier | Agent registered, trust not yet initiated | "Enroll" button |
| `pending` | 0 (REGISTERED), 1 (START), 2 (SAVED) | Enrolled in verifier, awaiting first attestation | Spinner/waiting |
| `pass` | 3 (GET_QUOTE), 4 (GET_QUOTE_RETRY), 5 (PROVIDE_V), 6 (PROVIDE_V_RETRY) | Actively attested and trusted | Green checkmark |
| `fail` | 7 (FAILED), 9 (INVALID_QUOTE) | Attestation failed (integrity issue) | "Investigate" alert |
| `paused` | 10 (TENANT_FAILED) | User stopped attestation via stop API | "Resume" button |
| `terminated` | 8 (TERMINATED) | Agent terminated | "Re-enroll" or hide |
| `unknown` | Verifier unreachable or `last_received_quote` stale | OMC cannot determine current state | Warning icon, "Retry" |

**Staleness detection:** If `time.now() - last_received_quote > STALENESS_THRESHOLD` (configurable, default 300s), status is `unknown` even if `operational_state` indicates `pass`.

**Note:** This study covers pull-mode attestation only. Push-mode attestation is out of scope.

**Derivation logic:**

```python
def derive_state(agent: dict, verifier_reachable: bool) -> str:
    if agent.get("_source") == "registrar_only":
        return "registered"
    if not verifier_reachable:
        return "unknown"

    op_state = agent.get("operational_state")

    if op_state in (3, 4, 5, 6):
        return _check_staleness(agent)
    if op_state == 10:
        return "paused"
    if op_state in (7, 9):
        return "fail"
    if op_state == 8:
        return "terminated"
    return "pending"

def _check_staleness(agent: dict) -> str:
    last_quote = agent.get("last_received_quote")
    if not last_quote or last_quote == 0:
        return "unknown"
    if time.time() - last_quote > STALENESS_THRESHOLD:
        return "unknown"
    return "pass"
```

---

### 5.3. OMC Transformation Layer

The OMC layer performs the following transformations on Keylime responses:

1. **Merge** Verifier + Registrar API responses into a single agent view
2. **Convert** unix timestamps → ISO 8601 (`last_received_quote`, `last_successful_attestation`)
3. **Convert** `operational_state` int → human-readable string
4. **Convert** `0/1` → `true/false` for policy flags (`has_runtime_policy`, `has_mb_refstate`)
5. **Derive** `state` from `operational_state` (see Section 5.2)
6. **Filter** sensitive fields (see Section 5.4)
7. **Rename** fields for customer-friendly naming (`has_mb_refstate` → `hasMbPolicy`)

No heavy business logic — primarily a transformation/projection layer.

---

### 5.4. Field Classification

The OMC API merges data from two Keylime backends (Verifier and Registrar) into a single agent resource. Since an agent may exist in the Registrar but not yet in the Verifier (state: `registered`), not all fields are available for every agent. This section classifies each response field by its availability to ensure consistent API behavior across all agent states and to guide frontend developers on which fields can be relied upon as always present versus conditionally null.

**Mandatory fields** (always present, never null):

| Field | Source | Rationale |
|---|---|---|
| `id` | Registrar | Primary identifier |
| `state` | OMC-derived | Always computable for any agent |

**Nullable fields** (from registrar, not guaranteed):

| Field | Source | Why nullable |
|---|---|---|
| `ip` | Registrar | Optional during agent registration |
| `port` | Registrar | Optional during agent registration |

**Optional fields** (present only when agent is enrolled in verifier, null otherwise):

| Field | Source | OMC Transformation |
|---|---|---|
| `operationalState` | Verifier | Convert int → human-readable string |
| `verifierId` | Verifier | None |
| `verifierIp` | Verifier | None |
| `verifierPort` | Verifier | None |
| `attestationCount` | Verifier | None |
| `lastReceivedQuoteAt` | Verifier (`last_received_quote`) | Convert unix timestamp → ISO 8601 |
| `lastSuccessfulAttestationAt` | Verifier (`last_successful_attestation`) | Convert unix timestamp → ISO 8601 |
| `severityLevel` | Verifier | Non-null only when `state` is `fail` |
| `lastEventId` | Verifier | Non-null only when `state` is `fail` |
| `hashAlg` | Verifier | None |
| `encAlg` | Verifier | None |
| `signAlg` | Verifier | None |
| `hasRuntimePolicy` | Verifier | Convert 0/1 → boolean |
| `hasMbPolicy` | Verifier (`has_mb_refstate`) | Convert 0/1 → boolean |

**Cache/DB freshness field** (always present, supports phased backend evolution):

| Field | Source | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|---|
| `lastRefreshed` | OMC-generated | `null` (live fetch, no cache) | ISO 8601 timestamp of last cache sync | ISO 8601 timestamp of last DB sync |

Including `lastRefreshed` as `null` in Phase 1 avoids a schema change and API version bump when Phase 2/3 populates it with actual timestamps.

**Omitted fields** (sensitive/internal — never exposed):

| Category | Fields | Risk |
|---|---|---|
| Crypto keys & certs (HIGH) | `ek_tpm`, `aik_tpm`, `ekcert`, `ak_tpm`, `public_key`, `v`, `revocation_key` | Direct security compromise |
| Policy internals (MEDIUM) | `tpm_policy`, `ima_sign_verification_keys`, `accept_tpm_*_algs`, `learned_ima_keyrings` | Aids attestation bypass |
| Internal state (LOW) | `meta_data`, `tpm_clockinfo`, `pcr10`, `next_ima_ml_entry` | API bloat, minor info leakage |

---

### 5.5. Response Schemas

This section defines the static JSON Schemas that serve as the contract for all RAS REST API responses. All UCs reference these schemas by name rather than repeating response structures. Schemas ensure internal consistency and predictable integration behavior across OMC components, frontend clients, and test automation.

**Design principle:** The Agent Resource schema contains stable, core identity + state fields. Frequently changing metrics (e.g., `attestationCount`) and operational counters are included as optional fields, not in the core resource, to keep the schema lean and cacheable.

#### 5.5.1. Agent Summary Schema

Used in: `GET /ras/v1.0/agents` (list response items)

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/agent.summary.schema.json",
  "type": "object",
  "required": ["id", "state"],
  "properties": {
    "id": {
      "type": "string",
      "format": "uuid"
    },
    "state": {
      "type": "string",
      "enum": ["registered", "pending", "pass", "fail", "paused", "terminated", "unknown"]
    },
    "ip": {
      "type": ["string", "null"]
    },
    "port": {
      "type": ["integer", "null"]
    },
    "verifierId": {
      "type": ["string", "null"]
    },
    "attestationCount": {
      "type": ["integer", "null"],
      "description": "Number of successful attestations. Null when agent is not in verifier."
    },
    "lastReceivedQuoteAt": {
      "type": ["string", "null"],
      "format": "date-time",
      "description": "ISO 8601 timestamp of last received quote (converted from Keylime unix timestamp)."
    },
    "lastSuccessfulAttestationAt": {
      "type": ["string", "null"],
      "format": "date-time",
      "description": "ISO 8601 timestamp of last passing attestation (converted from Keylime unix timestamp)."
    },
    "lastRefreshed": {
      "type": ["string", "null"],
      "format": "date-time",
      "description": "ISO 8601 timestamp of last cache/DB sync. Null in Phase 1 (live fetch)."
    }
  }
}
```

#### 5.5.2. Agent Detail Schema

Used in: `GET /ras/v1.0/agents/{id}` (detail response)

Extends Agent Summary with verifier-sourced fields. All extended fields are null when the agent is in `registered` state (not yet enrolled in verifier).

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/agent.detail.schema.json",
  "type": "object",
  "required": ["id", "state"],
  "allOf": [
    { "$ref": "agent.summary.schema.json" }
  ],
  "properties": {
    "operationalState": {
      "type": ["string", "null"],
      "description": "Human-readable Keylime operational state (e.g., 'Get Quote'). Null when not in verifier."
    },
    "severityLevel": {
      "type": ["integer", "null"],
      "description": "Severity of last failure. Non-null only when state is 'fail'."
    },
    "lastEventId": {
      "type": ["string", "null"],
      "description": "ID of last failure event. Non-null only when state is 'fail'."
    },
    "verifierIp": {
      "type": ["string", "null"]
    },
    "verifierPort": {
      "type": ["integer", "null"]
    },
    "hashAlg": {
      "type": ["string", "null"],
      "description": "Hashing algorithm used by TPM (e.g., 'sha256')."
    },
    "encAlg": {
      "type": ["string", "null"],
      "description": "Encryption algorithm (e.g., 'rsa'). In v2.5+, includes bit-length (e.g., 'rsa2048')."
    },
    "signAlg": {
      "type": ["string", "null"],
      "description": "Signing algorithm (e.g., 'rsassa')."
    },
    "hasRuntimePolicy": {
      "type": ["boolean", "null"],
      "description": "Whether an IMA runtime policy is configured. Converted from Keylime 0/1."
    },
    "hasMbPolicy": {
      "type": ["boolean", "null"],
      "description": "Whether a measured boot policy is configured. Converted from Keylime has_mb_refstate 0/1."
    }
  }
}
```

**Schema design notes:**
- `agent_version`: Not available from Keylime APIs. Keylime stores `supported_version` (the API version the agent supports, e.g., "2.0"), not the agent software version. Excluded until a source is available.
- `registered_at`: Not available. Keylime's `registrarmain` table has no `created_at` column. Excluded. Noted in Limitations (Section 10).
- `pcr_values`: Classified as sensitive/internal (Section 5.4). Excluded from all customer-facing schemas.
- `trust_state` (trusted/untrusted/unknown): Replaced by `state` with the 7-value OMC enum. `trust_state` conflates pass/fail into trusted/untrusted, losing the paused/pending/terminated distinctions.
- `attestationCount`: Retained as optional field. While it is a derived metric that changes frequently, it is useful for customer dashboards and does not pose a security risk.

#### 5.5.3. Attestation Result Schema

Used in: `POST /ras/v1.0/agents/{id}/attestation`, `PATCH /ras/v1.0/agents/{id}/attestation` (write operation responses)

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/attestation.result.schema.json",
  "type": "object",
  "required": ["id", "state", "status"],
  "properties": {
    "id": {
      "type": "string",
      "format": "uuid"
    },
    "state": {
      "type": "string",
      "enum": ["registered", "pending", "pass", "fail", "paused", "terminated", "unknown"],
      "description": "Current OMC agent state after the operation."
    },
    "status": {
      "type": "string",
      "enum": ["in_progress", "completed", "failed"],
      "description": "OMC operation processing status."
    },
    "verifierId": {
      "type": ["string", "null"],
      "description": "Assigned verifier. Informational; not guaranteed on failure."
    },
    "verificationInitiatedAt": {
      "type": ["string", "null"],
      "format": "date-time",
      "description": "OMC-generated timestamp of when attestation was triggered. Present in attest responses only."
    },
    "operationId": {
      "type": ["string", "null"],
      "description": "Unique operation identifier for traceability. Present in attest responses only."
    }
  }
}
```

#### 5.5.4. Error Response Schema

Used in: All UCs for error cases (400, 404, 409, 502, 503).

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/error.schema.json",
  "type": "object",
  "required": ["error"],
  "properties": {
    "error": {
      "type": "object",
      "required": ["code", "message"],
      "properties": {
        "code": {
          "type": "string",
          "description": "Machine-readable error code (e.g., 'INVALID_ARGUMENT', 'DEPENDENCY_FAILURE', 'NOT_FOUND')."
        },
        "message": {
          "type": "string",
          "description": "Human-readable error description."
        }
      }
    }
  }
}
```

#### 5.5.5. Paginated List Schema

Used in: `GET /ras/v1.0/agents` (list response wrapper)

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/agent.list.schema.json",
  "type": "object",
  "required": ["agents", "totalCount"],
  "properties": {
    "agents": {
      "type": "array",
      "items": { "$ref": "agent.summary.schema.json" }
    },
    "nextCursor": {
      "type": ["string", "null"],
      "description": "Opaque cursor for next page. Null when no more results."
    },
    "totalCount": {
      "type": "integer",
      "description": "Total number of agents matching the current filter (not total in system)."
    }
  }
}
```

---

### 5.6. UC-1: List All Agents

**Endpoint:** `GET /ras/v1.0/agents`

**Characteristics:** Synchronous, no request body, pagination mandatory.

**Query Parameters:**

| Parameter | Type | Phase | Required | Description |
|---|---|---|---|---|
| `limit` | integer (default 50, max 200) | 1 | No | Page size |
| `cursor` | string | 1 | No | Opaque cursor from previous response |
| `state` | string (enum) | 1 | No | Filter: `registered`, `pending`, `pass`, `fail`, `paused`, `terminated`, `unknown` |
| `verifierId` | string | 1 | No | Filter by verifier |

**Design decisions:**
- `totalCount` in response reflects filtered count, not total agents in system

**Response (200 OK):**

```json
{
  "agents": [
    {
      "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
      "ip": "10.0.0.5",
      "port": 9002,
      "state": "pass",
      "verifierId": "verifier-0",
      "attestationCount": 142,
      "lastReceivedQuoteAt": "2026-03-18T10:00:00Z",
      "lastSuccessfulAttestationAt": "2026-03-18T10:00:00Z",
      "lastRefreshed": null
    },
    {
      "id": "e1ef9f28-be55-47b0-a6c1-8bef90294b93",
      "ip": "10.0.0.6",
      "port": 9002,
      "state": "registered",
      "verifierId": null,
      "attestationCount": null,
      "lastReceivedQuoteAt": null,
      "lastSuccessfulAttestationAt": null,
      "lastRefreshed": null
    }
  ],
  "nextCursor": "e1ef9f28-be55-47b0-a6c1-8bef90294b93",
  "totalCount": 2
}
```

**Error Responses:**

| Code | Condition |
|---|---|
| 400 | `limit` exceeds maximum (200) |
| 502 | Registrar or Verifier unreachable |

**Pagination Design:**

Keylime has no native pagination. OMC implements cursor-based pagination:

1. Fetch full UUID list from Registrar (`GET /v2.x/agents/`)
2. Fetch full status from Verifier bulk endpoint (`GET /v2.x/agents/?bulk=True`)
3. Merge: agents in registrar only → `registered`; agents in verifier → derive `state`
4. Sort deterministically by `id` (only stable ordering available)
5. Apply `state` filter if provided
6. Find cursor position, slice `[cursor+1 : cursor+1+limit]`
7. Encode `nextCursor = base64(last_uuid_in_page)`

**Known Limitation:** No `created_at`/`updated_at` in Keylime's `registrarmain` table. Sorting by `id` (UUID) gives stable but non-chronological order. To support "show most recently registered agents", an Alembic migration adding `created_at` and `updated_at` columns to `registrarmain` would be required.

**Backend call strategy:**

| Scenario | Calls |
|---|---|
| No filters | 1 registrar list + 1 verifier bulk = 2 calls |
| `state=registered` | 1 registrar list + 1 verifier bulk (to exclude verifier agents) = 2 calls |
| `state=pass/fail/pending/paused` | 1 verifier bulk only = 1 call |
| `verifierId=X` | 1 registrar list + 1 verifier bulk with `?verifier=X` = 2 calls |

**Phase Evolution:**

- **Phase 1:** Direct aggregation. Fetch live from Registrar + Verifier on every request. Limit capped at 50 to protect Verifier. No state filtering support.
- **Phase 2:** Redis cache. Background poller syncs Registrar + Verifier at configurable TTL (60–300s). Enables state filtering. Cache key: `agent:{uuid}`.
- **Phase 3:** OMC DB. Persistent queryable view. Full filtering, efficient pagination, state history.

**Audit Logging:**
- Audit level: Access log only
- Log: caller identity, query parameters (`limit`, `cursor`, `state`, `verifierId`), result count, data source (live/cache/DB), total request latency

---

### 5.7. UC-2: Get Agent Specific Detail

**Endpoint:** `GET /ras/v1.0/agents/{id}`

**Characteristics:** Synchronous, no request body.

**Design decisions:**
- `operationalState` is returned as a human-readable string (e.g., `"Get Quote"`), not the raw Keylime integer
- Null verifier fields use `null` (not empty strings) for consistent schema across all agent states
- When verifier is unreachable, `state` is `"unknown"` (not `"registered"`) since the agent may exist in the verifier but OMC cannot confirm

**Response — Case 1: Agent in Verifier (200 OK):**

```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "ip": "10.0.0.5",
  "port": 9002,
  "state": "pass",
  "operationalState": "Get Quote",
  "severityLevel": null,
  "lastEventId": null,
  "verifierId": "verifier-0",
  "verifierIp": "10.0.0.1",
  "verifierPort": 8881,
  "attestationCount": 142,
  "lastReceivedQuoteAt": "2026-03-18T10:00:00Z",
  "lastSuccessfulAttestationAt": "2026-03-18T10:00:00Z",
  "hashAlg": "sha256",
  "encAlg": "rsa",
  "signAlg": "rsassa",
  "hasRuntimePolicy": true,
  "hasMbPolicy": false,
  "lastRefreshed": null
}
```

**Response — Case 2: Agent in Registrar only (200 OK):**

```json
{
  "id": "e1ef9f28-be55-47b0-a6c1-8bef90294b93",
  "ip": "10.0.0.6",
  "port": 9002,
  "state": "registered",
  "operationalState": null,
  "severityLevel": null,
  "lastEventId": null,
  "verifierId": null,
  "verifierIp": null,
  "verifierPort": null,
  "attestationCount": null,
  "lastReceivedQuoteAt": null,
  "lastSuccessfulAttestationAt": null,
  "hashAlg": null,
  "encAlg": null,
  "signAlg": null,
  "hasRuntimePolicy": null,
  "hasMbPolicy": null,
  "lastRefreshed": null
}
```

**Response — Case 3: Verifier Unreachable (200 OK with degraded data):**

```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "ip": "10.0.0.5",
  "port": 9002,
  "state": "unknown",
  "operationalState": null,
  "severityLevel": null,
  "lastEventId": null,
  "verifierId": null,
  "verifierIp": null,
  "verifierPort": null,
  "attestationCount": null,
  "lastReceivedQuoteAt": null,
  "lastSuccessfulAttestationAt": null,
  "hashAlg": null,
  "encAlg": null,
  "signAlg": null,
  "hasRuntimePolicy": null,
  "hasMbPolicy": null,
  "lastRefreshed": null
}
```

**Response — Case 4: Not found in either (404 Not Found)**

**Phase Evolution:**
- **Phase 1:** Fetch live from Registrar + Verifier on every request. Merge responses.
- **Phase 2:** Cache-first. Return from Redis if available; fallback to live fetch on cache miss. `lastRefreshed` populated with cache sync timestamp.
- **Phase 3:** DB-first. Return from OMC DB. `lastRefreshed` populated with DB sync timestamp.

**Audit Logging:**
- Audit level: Access log only
- Log: `id`, caller identity, response code, latency, data source (live/cache/DB)

---

### 5.8. UC-3: Attest An Agent

**Endpoint:** `POST /ras/v1.0/agents/{id}/attestation`

**Characteristics:** Synchronous, no request body required.

**Design decisions:**
- `operationId` is OMC-generated for traceability (correlates with audit log)
- `verificationInitiatedAt` is OMC-generated timestamp of when attestation was triggered
- Idempotency: if agent is already in `pending` or `pass` state, return 200 (not 202) with current `state` — do NOT re-enroll

**OMC Backend Orchestration:**

```
1. GET Registrar /v2.x/agents/{uuid}  → fetch ak_tpm, mtls_cert, ip, port
2. Assemble verifier POST body:
   - ak_tpm, mtls_cert          ← from registrar
   - ip, port                   ← from registrar
   - tpm_policy                 ← OMC default or request param
   - runtime_policy_name        ← OMC default or request param
   - accept_tpm_*_algs          ← OMC config defaults
   - revocation_key             ← OMC-managed
   - metadata                   ← OMC-generated
3. Determine target verifier via consistent hash ring: hash(id) → verifier pod
4. POST Verifier /v2.x/agents/{uuid}
5. Return 202 Accepted
```

**Response fields:**

| Field | Description |
|---|---|
| `id` | Agent identifier |
| `state` | Current OMC agent state (e.g., `pending`, `pass`) |
| `status` | OMC operation processing status: `in_progress` \| `completed` \| `failed` |
| `verifierId` | Assigned verifier (informational; not guaranteed on failure) |
| `verificationInitiatedAt` | OMC-generated timestamp of when attestation was triggered |
| `operationId` | Unique operation identifier for traceability |

**Response — Case 1: 202 Accepted (attestation initiated):**

```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "pending",
  "status": "in_progress",
  "verifierId": "verifier-0",
  "verificationInitiatedAt": "2026-03-20T05:10:00Z",
  "operationId": "attn-12345"
}
```

**Response — Case 2: 200 OK (idempotent — already attesting):**

```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "pass",
  "status": "completed",
  "verifierId": "verifier-0",
  "verificationInitiatedAt": null,
  "operationId": null
}
```

Note: In Phase 1, `verificationInitiatedAt` and `operationId` are `null` for idempotent responses since there is no persistence to retrieve the original operation details. In Phase 2/3, these fields will be populated from cache/DB.

**Error Responses:**

| Code | Condition |
|---|---|
| 404 | Agent not found in registrar |
| 409 | Agent already enrolled in verifier (non-idempotent re-enroll attempt) |
| 503 | Verifier unavailable |

**Note:** Clients should poll `GET /ras/v1.0/agents/{id}` to track attestation progress. The POST response only confirms enrollment initiation.

**Phase Evolution:**
- **Phase 1:** Directly invoke Keylime Registrar (fetch keys) and Verifier (POST agent). Return response immediately. No state persistence.
- **Phase 2:** Invoke Registrar + Verifier. Update Redis cache: mark agent `state` as `pending`, set `attestation_in_progress = true`. Return response immediately. Cache updated asynchronously via background poller as attestation progresses.
- **Phase 3:** Invoke Registrar + Verifier. Update OMC DB: mark agent `state` as `pending`, set `attestation_in_progress = true`, record attestation trigger timestamp. Persist state transitions in `agent_state_history` table.

**Audit Logging:**
- Audit level: Full audit with state transition
- Log: `id`, `operationId`, caller identity, previous `state` → new `state` (`registered` → `pending`), assigned `verifierId`, Keylime registrar response code + latency, Keylime verifier response code + latency, total request latency

---

### 5.9. UC-4 & UC-5: Stop / Resume Attestation

**Design rationale:** Both Stop and Resume use the same endpoint `PATCH /ras/v1.0/agents/{id}/attestation`. The request body contains `state` (the desired agent state), and the response body contains both `state` (resulting agent state) and `status` (OMC operation processing status).

| Field | Where | Purpose | Values |
|---|---|---|---|
| `state` | Request body | Desired agent attestation state | `paused` (stop), `pending` (resume) |
| `state` | Response body | Resulting agent attestation state | `paused`, `pending`, `pass`, etc. |
| `status` | Response body | OMC operation processing status | `in_progress`, `completed`, `failed` |

**Stop Attestation:**

`PATCH /ras/v1.0/agents/{id}/attestation`

Request:
```json
{ "state": "paused" }
```

Maps to: `PUT /v2.x/agents/{id}/stop` → sets Keylime `operational_state = 10 (TENANT_FAILED)`

Response (200 OK):
```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "paused",
  "status": "completed",
  "verifierId": "verifier-0"
}
```

**Resume Attestation:**

`PATCH /ras/v1.0/agents/{id}/attestation`

Request:
```json
{ "state": "pending" }
```

Maps to: `PUT /v2.x/agents/{id}/reactivate`

Response (200 OK):
```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "pending",
  "status": "in_progress",
  "verifierId": "verifier-0"
}
```

**Important:** Keylime's reactivate endpoint does NOT validate current state. It will return 200 even for agents in FAILED state. OMC must validate that the agent is in `paused` state before calling reactivate, to prevent unintended reactivation of genuinely failed agents.

**Idempotency:**
- Stop: If agent is already `paused`, return 200 with `"status": "completed"`. Do NOT call Verifier again.
- Resume: If agent is already in `pass`/`pending`, return 200 with `"status": "completed"`. Do NOT call Verifier again.

**Error Responses:**

| Code | Condition |
|---|---|
| 404 | Agent not found |
| 409 | Invalid state transition (e.g., resume on a `fail` agent) |
| 503 | Verifier unavailable |

**Phase Evolution:**
- **Phase 1:** Directly call Keylime Verifier API. Return response immediately.
- **Phase 2:** Invoke Verifier. Update Redis cache (`state`, `attestation_in_progress`). Sync via background polling.
- **Phase 3:** Invoke Verifier. Update OMC DB. Record state transition in `agent_state_history` table.

**Audit Logging:**
- Audit level: Full audit with state transition
- Log: `id`, caller identity, previous `state` → new `state` (e.g., `pass` → `paused`), Keylime verifier response code + latency, total request latency, idempotent action flag (true if no Keylime call was made)

---

### 5.10. UC-6: Remove Attestation

**Endpoint:** `DELETE /ras/v1.0/agents/{id}/attestation`

Maps to: `DELETE /v2.x/agents/{id}` on Verifier only. Agent remains in Registrar.

**Important Keylime behavior:** Verifier DELETE returns `202 Accepted` (not 200) when agent is in active polling states (GET_QUOTE, PROVIDE_V, etc.). It sets `operational_state = TERMINATED` and the polling loop handles cleanup asynchronously. OMC should treat both 200 and 202 from Keylime as success.

**Response:** `204 No Content`

**Idempotency:** If agent is not in verifier, return `204` — no action needed.

**Phase Evolution:**
- **Phase 1:** Call Keylime Verifier DELETE API. Return immediately.
- **Phase 2:** Call Verifier. Update Redis cache: remove attestation state, set `state = "registered"`.
- **Phase 3:** Call Verifier. Update OMC DB: set `state = "registered"`, record transition in `agent_state_history` table.

**Audit Logging:**
- Audit level: Full audit with state transition
- Log: `id`, caller identity, previous `state` → `registered`, Keylime verifier response code (200 vs 202) + latency, idempotent action flag

---

### 5.11. UC-7: Delete Agent (Full Removal)

**Endpoint:** `DELETE /ras/v1.0/agents/{id}`

**Ordered deletion:** Verifier first, then Registrar. Never delete from Registrar if Verifier deletion fails.

**Failure Handling:**

| Scenario | Behavior |
|---|---|
| Verifier delete fails | Return 503. Do NOT proceed to Registrar. System unchanged. |
| Verifier delete succeeds, Registrar fails | Return 207 Partial Success. Queue Registrar retry via background worker. |
| Agent not in verifier, Registrar delete succeeds | Return 204. |

**Response — Case 1: Full success:** `204 No Content`

**Response — Case 2: Partial failure (207):**

```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "status": "partial_failure",
  "details": {
    "verifier": "deleted",
    "registrar": "failed"
  }
}
```

**Phase Evolution:**
- **Phase 1:** Call Keylime Verifier DELETE, then Registrar DELETE. Return immediately.
- **Phase 2:** Call Verifier + Registrar. Remove agent from Redis cache entirely.
- **Phase 3:** Call Verifier + Registrar. Remove agent from OMC DB. Record deletion in `agent_state_history` table with final state.

**Audit Logging:**
- Audit level: Full audit with state transition
- Log: `id`, caller identity, previous `state` → `removed`, Keylime verifier response code + latency, Keylime registrar response code + latency, partial failure details (if applicable), background retry queued flag

---

### 5.12. Audit Logging Requirements

All OMC RAS API operations must produce structured audit log entries for security compliance, troubleshooting, and operational visibility.

#### 5.12.1. Audit Log Entry Structure

Every API call must log the following fields:

| Field | Type | Description |
|---|---|---|
| `timestamp` | ISO 8601 | When the request was received |
| `operation` | string | API operation: `list_agents`, `get_agent`, `attest_agent`, `stop_attestation`, `resume_attestation`, `remove_attestation`, `delete_agent` |
| `id` | string | Target agent (null for list operations) |
| `callerIdentity` | string | Authenticated caller (from mTLS cert subject or bearer token) |
| `requestMethod` | string | HTTP method |
| `requestPath` | string | Full request URI |
| `responseCode` | integer | HTTP response code returned to client |
| `status` | string | OMC operation outcome: `success`, `failed`, `partial_failure` |
| `latencyMs` | integer | Total request processing time in milliseconds |
| `verifierId` | string | Target verifier (null if not applicable) |
| `errorDetail` | string | Error message if `status` is `failed` (null otherwise) |

#### 5.12.2. State Transition Audit

For write operations (UC-3 through UC-7), the audit log must additionally capture:

| Field | Type | Description |
|---|---|---|
| `operationId` | string | Unique identifier for the operation (correlates with API response) |
| `previousState` | string | Agent `state` before the operation |
| `newState` | string | Agent `state` after the operation |
| `keylimeResponseCode` | integer | HTTP response code from Keylime backend |
| `keylimeLatencyMs` | integer | Latency of the Keylime backend call |

**Example — Attest Agent audit entry:**

```json
{
  "timestamp": "2026-03-20T05:10:00.123Z",
  "operation": "attest_agent",
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "callerIdentity": "CN=omc-admin",
  "requestMethod": "POST",
  "requestPath": "/ras/v1.0/agents/d432fbb3-d2f1-4a97-9ef7-75bd81c00000/attestation",
  "responseCode": 202,
  "status": "success",
  "latencyMs": 245,
  "verifierId": "verifier-0",
  "errorDetail": null,
  "operationId": "attn-12345",
  "previousState": "registered",
  "newState": "pending",
  "keylimeResponseCode": 200,
  "keylimeLatencyMs": 180
}
```

**Example — Stop Attestation audit entry:**

```json
{
  "timestamp": "2026-03-20T06:30:00.456Z",
  "operation": "stop_attestation",
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "callerIdentity": "CN=omc-admin",
  "requestMethod": "PATCH",
  "requestPath": "/ras/v1.0/agents/d432fbb3-d2f1-4a97-9ef7-75bd81c00000/attestation",
  "responseCode": 200,
  "status": "success",
  "latencyMs": 112,
  "verifierId": "verifier-0",
  "errorDetail": null,
  "operationId": "stop-67890",
  "previousState": "pass",
  "newState": "paused",
  "keylimeResponseCode": 200,
  "keylimeLatencyMs": 85
}
```

#### 5.12.3. Audit Requirements Per UC

| UC | Audit Level | State Transition Logged | Notes |
|---|---|---|---|
| UC-1: List Agents | Access log only | No | Log caller, query params, result count |
| UC-2: Agent Detail | Access log only | No | Log caller, id, response code |
| UC-3: Attest Agent | Full audit | Yes: `registered` → `pending` | Log verifier assignment, operationId |
| UC-4: Stop Attestation | Full audit | Yes: `pass`/`pending` → `paused` | Log previous state for rollback traceability |
| UC-5: Resume Attestation | Full audit | Yes: `paused` → `pending` | Log previous state; alert if resuming from `fail` |
| UC-6: Remove Attestation | Full audit | Yes: any → `registered` | Log verifier response (200 vs 202) |
| UC-7: Delete Agent | Full audit | Yes: any → removed | Log both verifier and registrar outcomes; flag partial failures |

#### 5.12.4. Retention and Compliance

- Audit logs must be written to a persistent, tamper-evident store (not just stdout)
- Minimum retention: 90 days (configurable)
- State transition audit entries must not be overwritten or deleted during retention period
- Failed operations must be logged with the same completeness as successful ones

---

### 5.13. Multi-Verifier Deployment

**Consistent Hashing for Verifier Assignment:**

OMC uses a consistent hash ring to assign agents to verifiers without customer involvement. The customer never specifies a `verifierId` in write requests.

```python
class VerifierHashRing:
    def __init__(self, verifiers: dict[str, str], virtual_nodes: int = 150):
        # verifiers: {"verifier-0": "https://pod-0:8881", ...}
        # Build ring with virtual nodes for even distribution

    def get_verifier(self, agent_uuid: str) -> tuple[str, str]:
        # Returns (verifier_id, endpoint_url)
        # hash(agent_uuid) → ring position → verifier pod
```

**Kubernetes Deployment:** StatefulSet (not Deployment) is required for stable verifier identity.

- Each pod gets a stable name: `keylime-verifier-0`, `keylime-verifier-1`, etc.
- `KEYLIME_VERIFIER_UUID` env var set to pod name via Kubernetes Downward API
- Headless service provides per-pod DNS: `keylime-verifier-{n}.keylime-verifier.{namespace}.svc.cluster.local`

**Scale events:**
- Scale up: New pods added to ring. ~1/N agents rebalance (migrate from old to new verifier).
- Scale down: Agents on removed pods must migrate before pod termination.
- Pod restart: Same pod name → same `verifierId` → no migration needed.

---

## 6. Serviceability Impacts

### 6.1. Planning

| Consideration | Answer | Comment |
|---|---|---|
| Are use cases clear and understandable? | Yes | Covered in Section 5 with request/response examples |
| Additional effort for installation/upgrade? | Yes | Keylime version >= 7.12.x required; StatefulSet deployment required for multi-verifier |
| Characteristics and dimensioning impacts? | Yes | Phase 1: max 50 agents per list request, expected p95 latency ~500ms for 50 agents (2 Keylime calls). Phase 2/3: up to 200 per request, p95 < 200ms from cache/DB. Target: support up to 10,000 agents across up to 10 verifier pods. |
| Additional licenses required? | No | Open source Keylime; no additional licensing |

### 6.2. Solution Design

| Consideration | Answer | Comment |
|---|---|---|
| Changes to solution design artifacts? | Yes | New OMC RAS microservice; Keylime Verifier and Registrar as backend dependencies |
| Dependencies to site/connectivity infrastructure? | Yes | mTLS required between OMC and Keylime components; cert management required |
| New configuration parameters exposed to customer? | No | `verifierId` returned in responses for operational visibility but not required in requests |
| Dependencies between parameters analyzed? | Yes | `state` derivation depends on `operational_state` |

### 6.3. Deployment

| Consideration | Answer | Comment |
|---|---|---|
| Impact on existing deployment procedures? | Yes | Keylime Verifier must be deployed as StatefulSet |
| Special preparation of site/cluster/network? | Yes | Headless service for per-pod DNS; mTLS cert provisioning |
| Manual steps needed to roll-out? | No | Automated via Helm/EVNFM |
| Non-backward compatible schema changes? | No | Phase 1 has no OMC DB; Phase 3 introduces new schema |
| New dependencies introduced? | Yes | Keylime >= 7.12.x; Redis (Phase 2); PostgreSQL/SQLite (Phase 3) |

### 6.4. Operations

| Consideration | Answer | Comment |
|---|---|---|
| Problem prevention procedures needed? | Yes | Staleness detection for `unknown` status; verifier health checks |
| How will issues be diagnosed? | Yes | Structured audit log per UC (see Section 5.12); `operationId` correlates API response to audit entry |
| Impact on Scale-in/Scale-out? | Yes | Scale-out requires hash ring rebalancing and agent migration |
| Monitored by existing capabilities? | Partial | New metrics required: (1) `ras_agents_by_state` gauge per verifier (pass/fail/pending/paused/unknown counts), (2) `ras_api_latency_seconds` histogram per endpoint, (3) `ras_keylime_errors_total` counter per backend (verifier/registrar). Alert thresholds: `fail` count > 0, `unknown` count > 5% of total agents, API p99 latency > 5s. |
| Sufficient fault localization? | Yes | `operationId` in every write response correlates to audit log entry; Keylime backend latency logged separately per call |
| Anomaly detection? | Partial | Staleness threshold (configurable, default 300s) triggers `unknown` state. Alert when: (1) `unknown` agent count exceeds threshold, (2) verifier bulk endpoint returns errors for > 3 consecutive polls, (3) agent stuck in `pending` state for > 10 minutes. Requires integration with existing alerting system (e.g., Prometheus AlertManager). |
| Impact on recovery procedures? | Yes | Verifier pod restart is safe (StatefulSet); agent migration needed on scale-down |
| Verifier memory pressure from slow agents? | Yes | Keylime verifier holds one coroutine + HTTP connection per agent during polling (default 60s timeout). No concurrency limit in Keylime. OMC must: (a) configure `request_timeout = 10` in verifier config, (b) enforce max agents per verifier via hash ring sizing, (c) monitor `last_received_quote` staleness to detect slow agents indirectly since Keylime does not expose per-agent quote latency. |

### 6.5. SW Maintenance

| Consideration | Answer | Comment |
|---|---|---|
| Manual steps to deploy/roll-out? | No | Helm chart handles OMC RAS deployment; Keylime StatefulSet managed separately |
| Continuity break (re-deployment needed)? | No | Phase 1→2→3 evolution is additive; no API contract changes between phases |
| Traffic disturbance during upgrade? | No | StatefulSet rolling update; agents continue attesting during OMC RAS pod restart |
| Special preparation needed? | No | Standard Helm upgrade; no data migration between phases (Phase 2 cache is ephemeral; Phase 3 DB is new) |
| Non-backward compatible schema changes? | No | Phase 3 introduces new OMC DB schema but does not modify Keylime's database |
| New dependencies between CNF versions? | Yes | OMC RAS requires Keylime Verifier and Registrar API v2.4+. Version negotiation handled at startup via Keylime's `/version` endpoint. |

## 7. Security Impacts

| Functionality | Impact | Comments |
|---|---|---|
| New user (human or machine) added | Yes | OMC RAS service account for mTLS client auth to Keylime |
| Existing user used for new functionality | No | |
| Function exposed to human user (API) | Yes | All 7 REST endpoints exposed on OMC NBI; mTLS or bearer token auth required |
| Sensitive data handled | Yes | TPM keys (`ek_tpm`, `aik_tpm`, `ekcert`, `v`, `revocation_key`) fetched from Keylime but NEVER forwarded to customers. Filtered at OMC layer. |
| Elevated user access needed | No | |
| File permissions changed | No | |
| Privileged container introduced | No | |
| Logging/audit rules changed | Yes | Structured audit logging for all API operations (see Section 5.12). State transitions logged with caller identity, previous/new state, and Keylime backend response. Minimum 90-day retention. |
| Encryption functionality impacted | Yes | mTLS between OMC and Keylime; TLS for customer-facing API |
| User management impacted | No | |
| Firewall functionality impacted | Yes | Port 8881 (Verifier) and Registrar port must be accessible from OMC RAS pod |
| Security risks introduced | Yes | OMC RAS has access to Keylime mTLS certs and can read TPM keys from Registrar. Strict network policy required to limit OMC RAS pod egress to Keylime services only. |

## 8. Test Scope and Consideration

**Test types required:** Unit tests (OMC transformation logic), Integration tests (OMC ↔ Keylime), E2E tests (full agent lifecycle).

**Environment:** Keylime Verifier + Registrar deployed with software TPM emulator (not for production use). Multi-verifier setup (minimum 2 pods) required for hash ring tests.

| UC | Test Type | Key Scenarios |
|---|---|---|
| UC-1: List Agents | Integration, E2E | Pagination correctness (cursor encode/decode), `state` filter, verifier unreachable → graceful degradation, `limit` > max → 400, registrar unreachable → 502 |
| UC-2: Agent Detail | Integration, E2E | All 4 response cases (in verifier, registrar only, verifier unreachable, not found); timestamp ISO 8601 conversion; boolean conversion for policy flags; `operational_state` int → string |
| UC-3: Attest Agent | Integration, E2E | Idempotency (already `pending`/`pass` → 200, no re-enroll); registrar fetch failure → 502; verifier POST failure → 503; consistent hash assigns same verifier for same UUID |
| UC-4: Stop Attestation | Integration | Stop from `pass` → `paused`; idempotency (already `paused` → 200, no Keylime call); stop from `fail` → 409 |
| UC-5: Resume Attestation | Integration | Resume from `paused` → `pending`; idempotency (already `pass`/`pending` → 200); resume from `fail` → 409 (OMC blocks invalid transition) |
| UC-6: Remove Attestation | Integration | Verifier returns 200 → 204; verifier returns 202 → 204 (both treated as success); agent not in verifier → 204 (idempotent) |
| UC-7: Delete Agent | Integration, E2E | Full success → 204; verifier fails → 503, registrar not called; verifier succeeds + registrar fails → 207 partial failure; background retry for registrar |
| Multi-verifier | Integration | Same UUID always maps to same verifier pod; scale-up adds new pod to ring; pod restart preserves verifierId |
| Audit Logging | Unit, Integration | All 11 audit fields present on every request; state transition fields present on write operations; failed operations logged with same completeness as successful |
| Security | Integration | No `ek_tpm`, `aik_tpm`, `ekcert`, `v`, `revocation_key`, `tpm_policy`, `ima_sign_verification_keys` in any response; mTLS required for all Keylime backend calls |

## 9. CPI Impacts

| Document Name | Impact |
|---|---|
| OMC Technical Product Description | New RAS REST API section required |
| OMC Deployment Guide | StatefulSet deployment instructions for Keylime Verifier |
| OMC API Reference | Full OpenAPI spec for 7 endpoints |
| OMC Security Guide | mTLS configuration, sensitive field policy |

## 10. Limitations

1. **No native Keylime pagination** — OMC must fetch full agent list on every request (Phase 1). Mitigated by limit cap and Phase 2/3 caching.
2. **No chronological ordering** — `registrarmain` table has no `created_at`/`updated_at`. Only UUID-based ordering available. Requires Keylime upstream contribution to add timestamps.
3. **No bulk write APIs in Keylime** — All write operations (attest, stop, resume, delete) are per-agent. Bulk OMC endpoints with parallel fan-out are deferred to Phase 2 study.
4. **Keylime's native `attestation_status` field unreliable on < 7.14.0** — OMC derives `state` from `operational_state` for compatibility with all deployments.
5. **Verifier DELETE is asynchronous for active agents** — Returns 202; actual cleanup happens in polling loop. OMC cannot guarantee immediate state change.
6. **Consistent hash ring rebalancing is disruptive** — Adding/removing verifier pods requires agent migration with brief attestation gap.
7. **Pull-mode only** — This study covers pull-mode attestation exclusively. Push-mode attestation support is out of scope and will be addressed in a separate study if required.
8. **Verifier memory pressure from slow agents** — In pull mode, the Keylime verifier holds one async coroutine + HTTP connection per agent during quote polling (default timeout: 60s). Slow or unresponsive agents hold these resources until timeout. With large agent counts, this can cause memory bloat. Keylime does not record per-agent quote latency, making it impossible to identify slow agents from the API. Mitigations: (a) reduce `request_timeout` in verifier config to 10s, (b) cap agents per verifier via OMC hash ring, (c) contribute upstream: add `asyncio.Semaphore` to bound concurrent polls and expose `last_quote_latency` per agent.

## 11. Study Log

### 11.1. Study Team

| Name | Role | Sign-off |
|---|---|---|
| | Study Author | |
| | Architect | |
| | Product Owner | |
| | Tech Lead | |

### 11.2. Updates

| Date | Type | Details |
|---|---|---|
| 2026-04-01 | 1/3 | Initial draft — API design, Keylime source validation, status model |
| 2026-04-12 | 2/3 | Added response schemas, phase evolution per UC, audit logging per UC, Phase 2 bulk operations separated |
| | Final | |
| | Approval | |
