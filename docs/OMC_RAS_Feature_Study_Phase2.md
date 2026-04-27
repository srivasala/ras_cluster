# OMC Remote Attestation Service (RAS) REST API — Feature Study (Phase 2: Bulk Operations)

## 1. Study Document Title

OMC-69581: OMC Remote Attestation Service REST API - Study (Phase 2: Bulk Operations)

## 2. Description

### Prerequisite

This study builds on the Phase 1 study (`OMC_RAS_Feature_Study.md`) which defines the single-agent REST API endpoints, the OMC state model, field classification, Keylime API mappings, and audit logging requirements. All Phase 1 definitions (state model, field classification, transformation layer, security impacts) apply to Phase 2 unchanged.

### Background

Phase 1 delivers 7 single-agent REST API endpoints. In production environments with hundreds or thousands of agents, customers need the ability to perform operations on groups of agents in a single API call — for example, attesting all newly registered agents, pausing attestation across a verifier during maintenance, or removing all failed agents.

Keylime provides no native bulk write APIs. All write operations (POST, PUT, DELETE) are strictly per-agent. The OMC layer must implement bulk operations by fanning out to Keylime's per-agent APIs with bounded concurrency.

### Scope

- 4 bulk REST API endpoints covering bulk attest, bulk stop/resume, bulk remove attestation, and bulk delete
- Partial success response pattern (individual agent results reported)
- Bounded concurrency to protect Keylime verifier and registrar from overload
- Filter-based targeting (by state, verifierId) as alternative to explicit UUID lists

## 3. Requirement SOC

| Requirement Section | SOC | SOC Info | Comments |
|---|---|---|---|
| Bulk attest agents | Yes | UC-B1 | Fan-out to per-agent Keylime POST with bounded concurrency |
| Bulk stop/resume attestation | Yes | UC-B2 | Fan-out to per-agent Keylime PUT stop/reactivate |
| Bulk remove attestation | Yes | UC-B3 | Fan-out to per-agent Keylime DELETE on verifier |
| Bulk delete agents | Yes | UC-B4 | Ordered fan-out: verifier DELETE then registrar DELETE per agent |

## 4. Anatomy

### 4.1. Use-Cases

| UC | Endpoint | Method | Description |
|---|---|---|---|
| UC-B1 | `/ras/v1.0/agents/bulk/attestation` | POST | Bulk attest multiple agents |
| UC-B2 | `/ras/v1.0/agents/bulk/attestation` | PATCH | Bulk stop or resume attestation |
| UC-B3 | `/ras/v1.0/agents/bulk/attestation` | DELETE | Bulk remove attestation (verifier only) |
| UC-B4 | `/ras/v1.0/agents/bulk` | DELETE | Bulk full removal (verifier + registrar) |

#### 4.1.1. Use-Case Effort Estimates

| Use-Case | Effort Estimate (PW) | Impacted Area |
|---|---|---|
| UC-B1: Bulk Attest | 2 | OMC RAS service, Verifier client, Registrar client, Hash ring |
| UC-B2: Bulk Stop/Resume | 1 | OMC RAS service, Verifier client |
| UC-B3: Bulk Remove Attestation | 1 | OMC RAS service, Verifier client |
| UC-B4: Bulk Delete | 2 | OMC RAS service, Verifier client, Registrar client |

## 5. Details

---

### 5.1. Common Design Patterns

#### 5.1.1. Agent Targeting

All bulk endpoints accept either an explicit list of UUIDs or a filter. Only one targeting method is allowed per request.

```json
// Option A: Explicit UUID list
{
  "agentIds": ["uuid1", "uuid2", "uuid3"]
}

// Option B: Filter-based
{
  "filter": {
    "state": "registered",
    "verifierId": "verifier-0"
  }
}
```

**Limits:**
- Explicit list: max 200 UUIDs per request
- Filter-based: OMC resolves the filter to a UUID list internally, capped at 200 agents. If the filter matches more than 200 agents, the request is rejected with 400 and a message indicating the filter is too broad.

#### 5.1.2. Partial Success Response Pattern

Bulk operations can succeed for some agents and fail for others. The response always reports individual outcomes:

```json
{
  "total": 3,
  "succeeded": [
    { "id": "uuid1", "state": "pending", "status": "completed" },
    { "id": "uuid3", "state": "pending", "status": "completed" }
  ],
  "failed": [
    { "id": "uuid2", "errorCode": 404, "error": "Agent not found in registrar" }
  ],
  "successCount": 2,
  "failureCount": 1
}
```

**HTTP status code logic:**
- All succeeded → `200 OK`
- All failed → `207 Multi-Status` (with individual errors)
- Mixed → `207 Multi-Status`
- Request-level error (bad input, limit exceeded) → `400 Bad Request`

#### 5.1.3. Bounded Concurrency

OMC fans out to Keylime per-agent APIs in parallel, bounded by a configurable concurrency limit to protect the verifier:

```python
MAX_CONCURRENT_BULK_OPS = 20  # configurable

async def bulk_operation(agent_uuids: list[str], operation_fn) -> dict:
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_BULK_OPS)

    async def bounded_op(uuid):
        async with semaphore:
            return await operation_fn(uuid)

    results = await asyncio.gather(
        *[bounded_op(uuid) for uuid in agent_uuids],
        return_exceptions=True
    )
    # ... partition into succeeded/failed ...
```

#### 5.1.4. Audit Logging

Each bulk request produces two levels of audit entries:

**Bulk-level audit entry** (one per request):

| Field | Type | Description |
|---|---|---|
| `timestamp` | ISO 8601 | When the request was received |
| `operation` | string | `bulk_attest`, `bulk_stop`, `bulk_resume`, `bulk_remove_attestation`, `bulk_delete` |
| `callerIdentity` | string | Authenticated caller (from mTLS cert subject or bearer token) |
| `requestMethod` | string | HTTP method |
| `requestPath` | string | Full request URI |
| `responseCode` | integer | HTTP response code (200 or 207) |
| `targetingMethod` | string | `uuid_list` or `filter` |
| `total` | integer | Total agents targeted |
| `successCount` | integer | Agents that succeeded |
| `failureCount` | integer | Agents that failed |
| `latencyMs` | integer | Total request processing time |

**Per-agent audit entry** (one per agent in the batch):

Same structure as Phase 1 state transition audit (Phase 1, Section 5.12.2), with the addition of:

| Field | Type | Description |
|---|---|---|
| `bulkOperationId` | string | Correlates per-agent entry to the bulk-level entry |
| `idempotent` | boolean | True if no Keylime call was made (agent already in target state) |
| `skipped` | boolean | True if agent was skipped due to invalid state transition |

**Audit requirements per UC:**

| UC | Bulk-Level | Per-Agent State Transition | Notes |
|---|---|---|---|
| UC-B1: Bulk Attest | Yes | Yes: `registered` → `pending` | Log assigned `verifierId` per agent |
| UC-B2: Bulk Stop | Yes | Yes: `pass`/`pending` → `paused` | Log skipped agents (invalid state) |
| UC-B2: Bulk Resume | Yes | Yes: `paused` → `pending` | Log skipped agents (e.g., `fail` state) |
| UC-B3: Bulk Remove | Yes | Yes: any → `registered` | Log Keylime response code (200 vs 202) |
| UC-B4: Bulk Delete | Yes | Yes: any → `removed` | Log both verifier + registrar outcomes; flag partial failures |

---

### 5.2. Batch Schemas

These schemas extend the Phase 1 schemas (see Phase 1, Section 5.5) with batch-specific structures.

#### 5.2.1. Batch Request Schema

Used in: All bulk endpoints. Supports either explicit UUID list or filter-based targeting.

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/batch.request.schema.json",
  "type": "object",
  "oneOf": [
    {
      "required": ["agentIds"],
      "properties": {
        "agentIds": {
          "type": "array",
          "items": { "type": "string", "format": "uuid" },
          "maxItems": 200
        }
      }
    },
    {
      "required": ["filter"],
      "properties": {
        "filter": {
          "type": "object",
          "properties": {
            "state": {
              "type": "string",
              "enum": ["registered", "pending", "pass", "fail", "paused", "terminated", "unknown"]
            },
            "verifierId": { "type": "string" }
          }
        }
      }
    }
  ]
}
```

#### 5.2.2. Batch State Update Request Schema

Used in: `PATCH /ras/v1.0/agents/bulk/attestation` (stop/resume). Extends Batch Request with target state.

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/batch_state_update.request.schema.json",
  "type": "object",
  "required": ["state"],
  "allOf": [
    { "$ref": "batch.request.schema.json" }
  ],
  "properties": {
    "state": {
      "type": "string",
      "enum": ["paused", "pending"],
      "description": "Target state: 'paused' to stop attestation, 'pending' to resume."
    }
  }
}
```

#### 5.2.3. Batch Result Schema

Used in: All bulk endpoint responses. Reports individual agent outcomes.

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/batch.result.schema.json",
  "type": "object",
  "required": ["total", "succeeded", "failed", "successCount", "failureCount"],
  "properties": {
    "total": {
      "type": "integer",
      "description": "Total number of agents targeted."
    },
    "succeeded": {
      "type": "array",
      "items": { "$ref": "attestation.result.schema.json" },
      "description": "Agents for which the operation succeeded."
    },
    "failed": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "errorCode", "error"],
        "properties": {
          "id": { "type": "string", "format": "uuid" },
          "errorCode": { "type": "integer" },
          "error": { "type": "string" },
          "details": {
            "type": "object",
            "description": "Additional context for partial failures (e.g., verifier/registrar status in bulk delete)."
          }
        }
      }
    },
    "successCount": { "type": "integer" },
    "failureCount": { "type": "integer" }
  }
}
```

**Schema design notes:**
- PDF's `Batch Operation Result` schema used `progress.total/completed/failed` for async tracking with `operationId`. This is an async polling pattern. Phase 2 study uses synchronous bulk with partial success instead — simpler, no operation tracking endpoint needed. If async is required for very large batches, the `operationId` + polling pattern can be added as a future extension.
- PDF's `Batch Attestation Request Schema` only supported `agentIds`. Extended to also support `filter`-based targeting.
- PDF's `Batch State Update Schema` used `state: "active"/"paused"` — changed `"active"` to `"pending"` to align with the OMC state model. Only values from the 7-value state enum are used in request bodies.

---

### 5.3. UC-B1: Bulk Attest Agents

**Endpoint:** `POST /ras/v1.0/agents/bulk/attestation`

**Request:**

```json
{
  "agentIds": ["uuid1", "uuid2", "uuid3"]
}
```

Or filter-based:

```json
{
  "filter": {
    "state": "registered"
  }
}
```

**Backend per agent:** Same as Phase 1 UC-3 (fetch registrar data → assemble POST body → POST to verifier via hash ring).

**Response (207 Multi-Status):**

```json
{
  "total": 3,
  "succeeded": [
    { "id": "uuid1", "state": "pending", "status": "in_progress", "verifierId": "verifier-0" },
    { "id": "uuid3", "state": "pending", "status": "in_progress", "verifierId": "verifier-1" }
  ],
  "failed": [
    { "id": "uuid2", "errorCode": 409, "error": "Agent already enrolled in verifier" }
  ],
  "successCount": 2,
  "failureCount": 1
}
```

**Idempotency:** Agents already in `pending`/`pass` state are reported in `succeeded` with their current state — no re-enrollment triggered.

**Error Responses:**

| Code | Condition |
|---|---|
| 400 | Missing `agentIds`/`filter`, limit exceeded (>200), filter too broad |
| 207 | Mixed or all-failed results (individual errors in `failed` array) |

**Phase Evolution:**
- **Phase 1:** Fan-out to Keylime Registrar (fetch keys) + Verifier (POST) per agent. No state persistence. Return aggregated result immediately.
- **Phase 2:** Same fan-out. Update Redis cache per agent: set `state = "pending"`, `attestation_in_progress = true`. Cache updated asynchronously via background poller.
- **Phase 3:** Same fan-out. Update OMC DB per agent. Record each state transition in `agent_state_history` table.

**Audit Logging:**
- Audit level: Full audit
- Bulk-level entry: caller identity, operation type (`bulk_attest`), total/success/failure counts, total latency
- Per-agent entries: `id`, previous `state` → `pending`, assigned `verifierId`, Keylime response code + latency, idempotent flag

---

### 5.4. UC-B2: Bulk Stop / Resume Attestation

**Endpoint:** `PATCH /ras/v1.0/agents/bulk/attestation`

**Request (stop):**

```json
{
  "agentIds": ["uuid1", "uuid2"],
  "state": "paused"
}
```

**Request (resume):**

```json
{
  "filter": {
    "state": "paused",
    "verifierId": "verifier-0"
  },
  "state": "pending"
}
```

**Backend per agent:** Same as Phase 1 UC-4/UC-5 (PUT stop or PUT reactivate). OMC validates current state before calling Keylime — agents in invalid states (e.g., resume on `fail`) are reported as failed without calling Keylime.

**Response (200 OK — all succeeded):**

```json
{
  "total": 2,
  "succeeded": [
    { "id": "uuid1", "state": "paused", "status": "completed" },
    { "id": "uuid2", "state": "paused", "status": "completed" }
  ],
  "failed": [],
  "successCount": 2,
  "failureCount": 0
}
```

**Idempotency:**
- Stop: Agents already `paused` → reported in `succeeded` with `"status": "completed"`. No Keylime call.
- Resume: Agents already in `pass`/`pending` → reported in `succeeded` with `"status": "completed"`. No Keylime call.

**Error Responses:**

| Code | Condition |
|---|---|
| 400 | Missing `state` field, invalid `state` value, limit exceeded |
| 207 | Mixed results (e.g., some agents in invalid state for transition) |

**Phase Evolution:**
- **Phase 1:** Fan-out to Keylime Verifier PUT stop/reactivate per agent. Return aggregated result immediately.
- **Phase 2:** Same fan-out. Update Redis cache per agent (`state`, `attestation_in_progress`). Sync via background polling.
- **Phase 3:** Same fan-out. Update OMC DB per agent. Record each state transition in `agent_state_history` table.

**Audit Logging:**
- Audit level: Full audit
- Bulk-level entry: caller identity, operation type (`bulk_stop` or `bulk_resume`), target state, total/success/failure counts, total latency
- Per-agent entries: `id`, previous `state` → new `state`, Keylime response code + latency, idempotent flag, skipped flag (if invalid state transition)

---

### 5.5. UC-B3: Bulk Remove Attestation

**Endpoint:** `DELETE /ras/v1.0/agents/bulk/attestation`

**Request:**

```json
{
  "filter": {
    "state": "fail"
  }
}
```

**Backend per agent:** Same as Phase 1 UC-6 (DELETE on verifier only). Agent remains in registrar.

**Response (200 OK):**

```json
{
  "total": 5,
  "succeeded": [
    { "id": "uuid1", "state": "registered", "status": "completed" },
    { "id": "uuid2", "state": "registered", "status": "completed" },
    { "id": "uuid3", "state": "registered", "status": "completed" },
    { "id": "uuid4", "state": "registered", "status": "completed" },
    { "id": "uuid5", "state": "registered", "status": "completed" }
  ],
  "failed": [],
  "successCount": 5,
  "failureCount": 0
}
```

**Idempotency:** Agents not in verifier are reported in `succeeded` with `state: "registered"`.

**Error Responses:**

| Code | Condition |
|---|---|
| 400 | Missing `agentIds`/`filter`, limit exceeded |
| 207 | Mixed results |

**Phase Evolution:**
- **Phase 1:** Fan-out to Keylime Verifier DELETE per agent. Return aggregated result immediately.
- **Phase 2:** Same fan-out. Update Redis cache per agent: remove attestation state, set `state = "registered"`.
- **Phase 3:** Same fan-out. Update OMC DB per agent: set `state = "registered"`, record transition in `agent_state_history`.

**Audit Logging:**
- Audit level: Full audit
- Bulk-level entry: caller identity, operation type (`bulk_remove_attestation`), total/success/failure counts, total latency
- Per-agent entries: `id`, previous `state` → `registered`, Keylime verifier response code (200 vs 202) + latency, idempotent flag

---

### 5.6. UC-B4: Bulk Delete Agents

**Endpoint:** `DELETE /ras/v1.0/agents/bulk`

**Request:**

```json
{
  "agentIds": ["uuid1", "uuid2", "uuid3"]
}
```

**Backend per agent:** Same as Phase 1 UC-7 (ordered: verifier DELETE → registrar DELETE). If verifier DELETE fails for an agent, registrar DELETE is skipped for that agent.

**Response (207 Multi-Status):**

```json
{
  "total": 3,
  "succeeded": [
    { "id": "uuid1", "status": "completed" },
    { "id": "uuid3", "status": "completed" }
  ],
  "failed": [
    { "id": "uuid2", "errorCode": 503, "error": "Verifier unavailable", "details": { "verifier": "failed", "registrar": "skipped" } }
  ],
  "successCount": 2,
  "failureCount": 1
}
```

**Failure handling:** Agents where verifier succeeds but registrar fails are reported in `failed` with `details: { "verifier": "deleted", "registrar": "failed" }`. Background retry for registrar deletion follows the same pattern as Phase 1 UC-7.

**Idempotency:** Agents already deleted from both verifier and registrar → reported in `succeeded` with `"status": "completed"`.

**Error Responses:**

| Code | Condition |
|---|---|
| 400 | Missing `agentIds`/`filter`, limit exceeded |
| 207 | Mixed results (partial failures per agent) |

**Phase Evolution:**
- **Phase 1:** Ordered fan-out per agent: Keylime Verifier DELETE → Registrar DELETE. Return aggregated result immediately.
- **Phase 2:** Same fan-out. Remove each agent from Redis cache entirely on success.
- **Phase 3:** Same fan-out. Remove each agent from OMC DB. Record deletion in `agent_state_history` with final state.

**Audit Logging:**
- Audit level: Full audit
- Bulk-level entry: caller identity, operation type (`bulk_delete`), total/success/failure counts, partial failure count, total latency
- Per-agent entries: `id`, previous `state` → `removed`, Keylime verifier response code + latency, Keylime registrar response code + latency, partial failure details, background retry queued flag

---

## 6. Serviceability Impacts

Refer to Phase 1 study. Additional considerations:

| Consideration | Answer | Comment |
|---|---|---|
| Impact on existing deployment? | No | No new infrastructure; uses same Keylime backends as Phase 1 |
| Dimensioning impacts? | Yes | Bulk operations generate burst load on verifier. Bounded concurrency (default 20) limits peak. Max 200 agents per bulk request. |
| Monitoring impacts? | Yes | New metrics: `ras_bulk_operations_total` counter, `ras_bulk_operation_duration_seconds` histogram, `ras_bulk_partial_failures_total` counter |

## 7. Security Impacts

Refer to Phase 1 study. No additional security impacts — bulk endpoints use the same authentication, authorization, and sensitive field filtering as single-agent endpoints.

## 8. Test Scope

| UC | Test Type | Key Scenarios |
|---|---|---|
| UC-B1 | Integration, E2E | Bulk attest 50 agents; mixed success/failure; filter-based targeting; limit exceeded (>200) → 400; idempotency |
| UC-B2 | Integration | Bulk stop; bulk resume; invalid state transitions reported per-agent; filter by state+verifierId |
| UC-B3 | Integration | Bulk remove; idempotency (agents not in verifier); filter by `state=fail` |
| UC-B4 | Integration, E2E | Ordered deletion; partial failure (verifier ok, registrar fail); background retry; all agents not found → 200 |
| Concurrency | Load test | 200 agents with MAX_CONCURRENT_BULK_OPS=20; verify verifier is not overwhelmed; measure total operation time |
| Audit | Integration | Bulk audit entry + individual per-agent audit entries; verify counts match |

## 9. Limitations

1. **Max 200 agents per bulk request** — Hard limit to protect Keylime backends. Clients must paginate bulk operations for larger sets.
2. **No transactional atomicity** — Bulk operations are best-effort. Individual agents can succeed or fail independently. There is no rollback mechanism.
3. **Filter resolution is point-in-time** — When using filter-based targeting, the filter is resolved to a UUID list at request time. Agents that change state between resolution and execution may produce unexpected results.

## 10. Study Log

### 10.1. Study Team

Refer to Phase 1 study.

### 10.2. Updates

| Date | Type | Details |
|---|---|---|
| 2026-04-12 | 1/3 | Initial draft — Bulk operations API design |
| 2026-04-12 | 2/3 | Added phase evolution, audit logging, error responses per UC; expanded audit logging structure; schema design notes |
| | Final | |
| | Approval | |
