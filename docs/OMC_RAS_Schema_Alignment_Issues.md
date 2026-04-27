# OMC RAS Feature Study — Schema vs UC Response Alignment Issues

**Date:** 2026-04-14
**Source:** `OMC_RAS_Feature_Study.md`, Sections 5.5 (Response Schemas) and 5.6–5.11 (Use Cases)

---

## Issue 1: UC-4/UC-5 (Stop/Resume) responses omit optional schema fields

**Schema:** `attestation.result.schema.json` (Section 5.5.3)
**Affected UCs:** UC-4 (Stop Attestation), UC-5 (Resume Attestation)

The schema declares `verifier_id`, `verification_initiated_at`, and `operation_id` as optional properties. The UC-4/UC-5 response examples omit these fields entirely rather than including them as `null`:

```json
{
  "agent_uuid": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "state": "paused",
  "status": "completed"
}
```

**Problem:** A strict JSON Schema validator would pass this (fields are not required), but the inconsistency with UC-3 examples (which include all fields) creates ambiguity for client implementors about whether these fields should be expected.

**Recommended fix:** Either:
- Split `attestation.result.schema.json` into `attestation.result.schema.json` (POST) and `attestation.action.result.schema.json` (PATCH), or
- Add `"verifier_id": null, "verification_initiated_at": null, "operation_id": null` to UC-4/UC-5 examples for consistency

---

## Issue 2: UC-7 partial failure (207) response has no schema

**Schema:** Missing
**Affected UC:** UC-7 (Delete Agent)

The 207 Partial Success response has a unique structure not covered by any defined schema:

```json
{
  "agent_uuid": "d432fbb3-d2f1-4a97-9ef7-75bd81c00000",
  "status": "partial_failure",
  "details": {
    "verifier": "deleted",
    "registrar": "failed"
  }
}
```

**Problems:**
1. No schema exists for this response shape.
2. The `status` value `"partial_failure"` is not in the `attestation.result.schema.json` enum `["in_progress", "completed", "failed"]`.
3. The `details` object with `verifier`/`registrar` sub-status is not defined anywhere.
4. The response has no `state` field, which is `required` in `attestation.result.schema.json`.

**Recommended fix:** Add a `partial_failure.schema.json` (or `delete.result.schema.json`) in Section 5.5:

```json
{
  "$id": "http://omc.ericsson.com/ras/v1.0/partial_failure.schema.json",
  "type": "object",
  "required": ["agent_uuid", "status", "details"],
  "properties": {
    "agent_uuid": { "type": "string", "format": "uuid" },
    "status": { "type": "string", "enum": ["partial_failure"] },
    "details": {
      "type": "object",
      "required": ["verifier", "registrar"],
      "properties": {
        "verifier": { "type": "string", "enum": ["deleted", "failed", "not_found"] },
        "registrar": { "type": "string", "enum": ["deleted", "failed"] }
      }
    }
  }
}
```

---

## Issue 3: UC-3 idempotent response — ambiguous schema description

**Schema:** `attestation.result.schema.json` (Section 5.5.3)
**Affected UC:** UC-3 (Attest Agent), 200 OK idempotent case

The UC-3 idempotent response sets `verification_initiated_at: null` and `operation_id: null`. The schema description for these fields says "Present in attest responses only" — but the idempotent 200 *is* an attest response that simply didn't trigger a new attestation.

**Problem:** The description is misleading. A reader could interpret "present in attest responses only" as "always non-null in attest responses."

**Recommended fix:** Update the schema descriptions to:
- `verification_initiated_at`: "Timestamp of when attestation was triggered. Null for idempotent responses where no new attestation was initiated."
- `operation_id`: "Unique operation identifier. Null for idempotent responses where no new operation was created."

---

## Issue 4: UC-6 (Remove Attestation) — no schema reference for 204 No Content

**Schema:** N/A
**Affected UC:** UC-6 (Remove Attestation)

UC-6 returns `204 No Content` (no response body). Section 5.5.3 states the Attestation Result Schema is "Used in: `POST` ... `PATCH`" — correctly excluding DELETE by omission. However, the schema section never explicitly notes that UC-6 and UC-7 (success case) produce no response body.

**Problem:** A reader scanning Section 5.5 for "which schema covers which UC" has no explicit mapping for UC-6 or UC-7's 204 case.

**Recommended fix:** Add a note in Section 5.5 or a schema-to-UC mapping table:

| Schema | UCs |
|---|---|
| `agent.list.schema.json` | UC-1 (200) |
| `agent.detail.schema.json` | UC-2 (200) |
| `attestation.result.schema.json` | UC-3 (200, 202), UC-4 (200), UC-5 (200) |
| `error.schema.json` | All UCs (4xx, 5xx) |
| `partial_failure.schema.json` | UC-7 (207) |
| No body (204) | UC-6, UC-7 (success) |

---

## Issue 5: UC-1 `next_marker` — example contradicts pagination design

**Schema:** `agent.list.schema.json` (Section 5.5.5)
**Affected UC:** UC-1 (List All Agents)

The pagination design (Section 5.6) states:
> `next_marker = base64(last_uuid_in_page)`

But the UC-1 response example shows a raw UUID:
```json
"next_marker": "e1ef9f28-be55-47b0-a6c1-8bef90294b93"
```

A base64-encoded UUID would look like: `"next_marker": "ZTFlZjlmMjgtYmU1NS00N2IwLWE2YzEtOGJlZjkwMjk0Yjkz"`

**Problem:** The example and the design description are inconsistent. Client implementors won't know whether to expect a raw UUID or a base64 string.

**Recommended fix:** Update the UC-1 example to use a base64-encoded marker, or change the design to use raw UUIDs (simpler, and the marker is already opaque to clients).

---

## Summary

| # | Issue | Severity | UCs | Fix type |
|---|---|---|---|---|
| 1 | Stop/Resume responses omit optional fields present in schema | Low | UC-4, UC-5 | Example or schema update |
| 2 | 207 partial failure has no schema definition | High | UC-7 | New schema required |
| 3 | Idempotent attest response description is ambiguous | Low | UC-3 | Description clarification |
| 4 | No explicit schema mapping for 204 responses | Medium | UC-6, UC-7 | Add mapping table |
| 5 | `next_marker` example contradicts base64 design | Medium | UC-1 | Align example with design |
