# OMC_RAS_Feature_Study.md — Change Log

**Date:** 2026-04-22
**Reason:** Address reviewer comment + design rule compliance + field cleanup

---

## Change 1: Added Section 2.1 — RAS Use-Case Scope Map

**Why:** Reviewer could not judge completeness without seeing the full universe of RAS use-cases and which are in/out of scope.

**What:** Inserted new Section 2.1 between the Description (Section 2) and Requirement SOC (Section 3). Contains:
- 20-row table classifying every RAS use-case as Covered / Partial / Out of scope / Deferred / Excluded
- Coverage summary line (13 covered, 2 partial, 3 out of scope, 2 deferred)
- Note [1] explaining why agent registration is not an OMC API (TPM-bound agent-initiated handshake)

---

## Change 2: Removed `registration_count` / `regcount`

**Why:** Keylime fixed `regcount` as a vulnerability — it is now always 1. A constant field provides no value.

**What:** Removed from 4 locations:
- Section 5.3 (transformation layer): removed `regcount → registration_count` from rename list
- Section 5.4 (field classification): removed row from mandatory fields table
- Section 5.5.2 (Agent Detail Schema): removed from `required` array and `properties` block
- Section 5.7 (UC-2 response examples): removed `"registration_count": 1` from all 3 JSON examples (in-verifier, registrar-only, verifier-unreachable)

---

## Change 3: Design Rule Compliance — Path Parameters

**Rule:** DR-A0104-0614-D (MUST use camelCase for path parameters), GL-A0104-0612-D (SHOULD use `id` as primary identifier)

**What:** All endpoint paths changed:

| Before | After |
|---|---|
| `/ras/v1.0/agents/{agent_uuid}` | `/ras/v1.0/agents/{id}` |
| `/ras/v1.0/agents/{agent_uuid}/attestation` | `/ras/v1.0/agents/{id}/attestation` |

Applied in: Section 4.1 UC table, Section 5.1 API mapping table, Sections 5.7–5.11 UC endpoint definitions, Section 5.5.2 "Used in" line.

---

## Change 4: Design Rule Compliance — Query Parameters

**Rule:** DR-A0104-062-D (MUST use camelCase for query parameters), DR-A0104-067-D (MUST use conventional pagination names)

**What:** UC-1 query parameters changed:

| Before | After |
|---|---|
| `verifier_id` | `verifierId` |
| `marker` | `cursor` |

Also in pagination design description: `next_marker` → `nextCursor`, algorithm references updated.

---

## Change 5: Design Rule Compliance — Response Body Fields (snake_case → camelCase)

**Rule:** DR-A0104-062-D / DR-A0104-0614-D (camelCase convention), GL-A0104-0612-D (`id` as primary identifier)

**What:** All OMC API response field names converted. Full mapping:

| Before (snake_case) | After (camelCase) |
|---|---|
| `agent_uuid` | `id` |
| `verifier_id` | `verifierId` |
| `verifier_ip` | `verifierIp` |
| `verifier_port` | `verifierPort` |
| `operational_state` | `operationalState` |
| `attestation_count` | `attestationCount` |
| `last_received_quote_at` | `lastReceivedQuoteAt` |
| `last_successful_attestation_at` | `lastSuccessfulAttestationAt` |
| `severity_level` | `severityLevel` |
| `last_event_id` | `lastEventId` |
| `hash_alg` | `hashAlg` |
| `enc_alg` | `encAlg` |
| `sign_alg` | `signAlg` |
| `has_runtime_policy` | `hasRuntimePolicy` |
| `has_mb_policy` | `hasMbPolicy` |
| `last_refreshed` | `lastRefreshed` |
| `next_marker` | `nextCursor` |
| `total_count` | `totalCount` |
| `operation_id` | `operationId` |
| `verification_initiated_at` | `verificationInitiatedAt` |
| `error_detail` | `errorDetail` |
| `previous_state` | `previousState` |
| `new_state` | `newState` |
| `keylime_response_code` | `keylimeResponseCode` |
| `keylime_latency_ms` | `keylimeLatencyMs` |
| `latency_ms` | `latencyMs` |
| `caller_identity` | `callerIdentity` |
| `request_method` | `requestMethod` |
| `request_path` | `requestPath` |
| `response_code` | `responseCode` |

Applied in: JSON schemas (5.5.1–5.5.5), JSON response examples (5.6–5.11), field classification tables (5.4), audit log structure (5.12), audit log JSON examples (5.12.2), Section 2.1 scope map, Sections 6 and 8.

**Not changed (Keylime-native names preserved):**
- `derive_state` Python code block (Section 5.2)
- `VerifierHashRing` Python code block (Section 5.13)
- State model table `operational_state` column header (Section 5.2)
- Keylime API Mapping table (Section 5.1) — Keylime paths and field names
- Transformation layer Keylime source field references (Section 5.3)
- Source column in field classification tables (Section 5.4)
- Schema descriptions referencing Keylime fields (e.g., "from Keylime has_mb_refstate")

---

## Change 6: Fixed `"active"` → `"pending"` in UC-4/UC-5 Resume Request

**Why:** `"active"` is not a value in the OMC 7-value state enum (`registered`, `pending`, `pass`, `fail`, `paused`, `terminated`, `unknown`). Resume transitions from `paused` → `pending`, so the request should use `"pending"`.

**What:**

Before:
```json
{ "state": "active" }
```

After:
```json
{ "state": "pending" }
```

Applied in:
- Design rationale table: `paused` (stop), `active` (resume) → `paused` (stop), `pending` (resume)
- Resume request body example

---

## Change 7: Added `verifierId` to UC-4/UC-5 Responses

**Why:** Stop/resume operate on agents already enrolled in a verifier. The `verifierId` is known and useful for the caller. The Attestation Result Schema already defines it as optional, and UC-3 includes it — UC-4/UC-5 should be consistent.

**What:**

Stop response before:
```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "paused",
  "status": "completed"
}
```

Stop response after:
```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "paused",
  "status": "completed",
  "verifierId": "verifier-0"
}
```

Resume response before:
```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "pending",
  "status": "in_progress"
}
```

Resume response after:
```json
{
  "id": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "pending",
  "status": "in_progress",
  "verifierId": "verifier-0"
}
```
