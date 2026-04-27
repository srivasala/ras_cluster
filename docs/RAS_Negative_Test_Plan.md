# RAS Functional & Negative Test Plan

Covers application-level negative scenarios, security validation, and robustness tests. These are distinct from the Scale/HA/Stress/Soak tests in `RAS_Scale_HA_Test_Plan.md`.

---

## 1. Security — Attestation Integrity

#### NEG-SEC-01: PCR Tamper — Attestation Failure Detection

**Purpose:** Verify keylime's core function: detecting a compromised agent.

| Setup | 10 agents attesting normally |
|---|---|
| Action | Modify PCR values on 1 agent (extend a PCR with unexpected value) |

**Expected:**
- Verifier detects PCR mismatch on next quote
- Agent transitions to `FAILED` with `INVALID_QUOTE`
- Revocation notification fires (webhook / ZMQ)
- Other 9 agents unaffected

**Pass criteria:** Failed agent detected within 1× `quote_interval`. Revocation event received. No impact on healthy agents.

#### NEG-SEC-02: Agent Re-Registers with Different TPM Identity

**Purpose:** Verify registrar rejects an agent that presents a different EK/AK than its original registration.

| Setup | Agent registered with EK-A |
|---|---|
| Action | Restart agent with a different SWTPM instance (new EK-B), same UUID |

**Expected:** Registrar returns **403 Forbidden** on the registration POST. Agent cannot re-register with a different identity.

**Pass criteria:** 403 response. Original agent record unchanged in DB. Verifier continues attesting the original identity (if agent with EK-A is still running) or marks agent as unreachable (if only EK-B agent exists).

#### NEG-SEC-03: Revocation Cascade — Single Failure Among Many

**Purpose:** Verify that one agent's attestation failure doesn't disrupt others.

| Setup | 200 simulators attesting normally |
|---|---|
| Action | Tamper PCR on 1 agent |

**Pass criteria:**
- Failed agent detected and revocation fired
- Remaining 199 agents: zero change in attestation latency, zero `GET_QUOTE_RETRY` entries
- Verifier RSS: no spike from revocation processing

#### NEG-SEC-04: Expired mTLS Certificates

**Purpose:** Verify behavior when the verifier's TLS certificate expires.

| Setup | Agents attesting normally |
|---|---|
| Action | Replace verifier TLS cert with an expired cert, restart verifier |

**Expected:** Agents reject TLS handshake (cert validation fails). Verifier logs TLS errors. Agents become unreachable → `GET_QUOTE_RETRY` → `FAILED`.

**Pass criteria:** Verifier does not crash. Clear error logs indicating TLS failure. After cert replacement with valid cert + restart: agents recover.

---

## 2. Robustness — Malformed Input

#### NEG-ROB-01: Malformed Quote Response

**Purpose:** Verify verifier handles garbage data from an agent.

| Setup | Agent attesting normally |
|---|---|
| Action | Configure agent simulator to return random bytes instead of a valid quote |

**Expected:** Verifier fails to parse the quote, logs an error, transitions agent to `FAILED` or `INVALID_QUOTE`.

**Pass criteria:** No crash, no OOM, no hang. Agent marked as failed. Other agents unaffected.

#### NEG-ROB-02: Oversized Quote Response

**Purpose:** Verify verifier handles an excessively large response.

| Setup | Agent attesting normally |
|---|---|
| Action | Configure agent simulator to return a 50 MB response body |

**Expected:** Verifier rejects or truncates the response. Agent enters `FAILED`.

**Pass criteria:** No OOM. Verifier RSS spike < 100 MB. Other agents unaffected.

#### NEG-ROB-03: Agent Returns HTTP Errors

**Purpose:** Verify verifier handles non-200 responses from agents.

| Scenarios | Agent returns 500, 404, 503, connection reset |
|---|---|

**Pass criteria per scenario:** Agent enters `GET_QUOTE_RETRY` → `FAILED` after `max_retries`. Verifier does not crash. Error logged with agent ID.

---

## 3. Registrar — Negative Scenarios

#### NEG-REG-01: Duplicate Agent UUID — Different Pods

**Purpose:** Verify registrar handles two different agents registering with the same UUID.

| Setup | Agent-A registered with UUID `abc-123` |
|---|---|
| Action | Deploy Agent-B (different SWTPM) with same UUID `abc-123` |

**Expected:** If EK differs → 403 Forbidden. If EK matches (same TPM identity) → re-registration accepted (overwrite).

**Pass criteria:** No DB corruption. No duplicate rows. Clear 403 or successful overwrite.

#### NEG-REG-02: Registration Phase 1 Completes, Phase 2 Never Arrives

**Purpose:** Verify registrar handles agents that start registration but never activate.

| Action | Send POST to registrar (Phase 1), but never send the activate (Phase 2) |
|---|---|

**Expected:** Agent record exists with `active=False`. Per-agent lock created in SharedDataManager. No cleanup job exists — lock persists until pod restart.

**Pass criteria:** Registrar functional for other registrations. Stale record doesn't block new agents. Document: this is a known leak (per Bloat Analysis Section 7.4, Risk 3).

#### NEG-REG-03: SharedDataManager Process Death

**Purpose:** Verify registrar behavior when the Manager process dies.

| Action | `kill -9 <Manager_PID>` inside registrar container |
|---|---|

**Expected:** All subsequent registrations fail with `ConnectionRefusedError` or `BrokenPipeError`. Workers return 500 to all registration requests. No automatic recovery — pod restart required.

**Pass criteria:**
- Registrations fail with 500 (not hang)
- Existing registered agents unaffected (data is in DB, not Manager)
- Liveness probe detects failure (if `/health` endpoint exists) or pod eventually OOMKills/restarts

#### NEG-REG-04: Concurrent Enroll and Delete — Same Agent

**Purpose:** Verify no deadlock or orphaned state from concurrent operations.

| Action | Simultaneously: POST enroll agent `abc-123` + DELETE agent `abc-123` |
|---|---|

**Pass criteria:** One operation wins. No DB deadlock. No orphaned lock in SharedDataManager. Final state is consistent (agent exists or doesn't, not partial).

---

## 4. Configuration — Invalid Values

#### NEG-CFG-01: `retry_interval=0` with Exponential Backoff

**Purpose:** Verify behavior with degenerate retry config.

| Config | `retry_interval=0`, `exponential_backoff=true` |
|---|---|

**Expected:** `0^n = 0` for all n. Retries fire immediately with no delay. Could cause tight retry loop.

**Pass criteria:** Verifier starts (no crash). Document whether this causes CPU spin or is handled gracefully.

#### NEG-CFG-02: `retry_interval=10` with Exponential Backoff

**Purpose:** Verify the uncapped backoff problem documented in Bloat Analysis Section 2.6.

| Config | `retry_interval=10`, `exponential_backoff=true`, `max_retries=5` |
|---|---|
| Action | Make 1 agent unreachable |

**Expected:** Retry delays: 10s, 100s, 1000s, 10000s, 100000s. Total hold time ~31 hours. `call_later` pins agent dict + policies for entire duration.

**Pass criteria:** This is a **characterization test** — document the actual behavior. Verify memory is pinned as predicted. This test validates the Bloat Analysis findings.

#### NEG-CFG-03: `request_timeout=0`

**Purpose:** Verify behavior with zero timeout.

**Pass criteria:** Verifier either rejects the config at startup or every quote request times out immediately (all agents → `FAILED`). No crash.

#### NEG-CFG-04: Invalid `db_pool_sz_ovfl` Format

**Purpose:** Verify behavior with malformed DB pool config.

| Config | `db_pool_sz_ovfl=abc,xyz` |
|---|---|

**Pass criteria:** Verifier fails at startup with clear error message. No silent fallback to unbounded pool.

---

## 5. Upgrade / Schema

#### NEG-UPG-01: Verifier Starts Against Wrong Alembic Revision

**Purpose:** Verify behavior when DB has a revision the verifier doesn't recognize.

| Setup | DB at revision `5a8b2c3d4e6f` (7.14.1 head) |
|---|---|
| Action | Start verifier from an older keylime version (7.13.x, head `57b24ee21dfa`) |

**Expected:** Verifier fails at startup with alembic error. Does not corrupt data.

**Pass criteria:** CrashLoopBackOff with clear error in logs. DB data intact after failed startup.

#### NEG-UPG-02: Migration Downgrade Failure

**Purpose:** Verify rollback behavior when a migration's `downgrade()` function has a bug.

| Setup | DB at 7.14.1 head |
|---|---|
| Action | Attempt `alembic downgrade` to 7.13.x head |

**Pass criteria:** If downgrade fails, error is clear and DB is not left in a partially-migrated state. Rollback script (from IS UC1) retries and reports failure.

---

## 6. Test Summary

| Category | Tests | Purpose |
|---|---|---|
| Security (NEG-SEC) | 4 | Attestation integrity, identity spoofing, cert expiry |
| Robustness (NEG-ROB) | 3 | Malformed/oversized responses, HTTP errors |
| Registrar (NEG-REG) | 4 | Duplicate UUID, stale registration, Manager death, race conditions |
| Configuration (NEG-CFG) | 4 | Degenerate config values, uncapped backoff validation |
| Upgrade (NEG-UPG) | 2 | Schema mismatch, downgrade failure |
| **Total** | **17** | |

### Automation Notes

Most of these tests are short-running (< 30 minutes) and can be automated with the same framework from `RAS_Scale_HA_Test_Plan.md`. The Agent Manager needs an extension to support:
- PCR tampering (`agent.tamper_pcr(pcr_index, value)`)
- Response manipulation (`agent.set_response_mode("garbage" | "oversized" | "http_error")`)
- Cert replacement (`injector.replace_cert(pod, namespace, cert_path)`)

### CI Integration

| Test | Frequency | Duration | Blocking? |
|---|---|---|---|
| NEG-SEC-01 (PCR tamper) | Nightly | 10 min | Yes |
| NEG-SEC-02 (identity spoof) | Nightly | 10 min | Yes |
| NEG-REG-01 (duplicate UUID) | Nightly | 10 min | Yes |
| NEG-REG-03 (Manager death) | Weekly | 15 min | No |
| NEG-CFG-02 (uncapped backoff) | Once | 2h | N/A (characterization) |
| NEG-UPG-01 (schema mismatch) | Per release | 10 min | Yes |
| All others | Weekly | 1h total | No |


---

## 7. Agent Response Validation — Defensive Tests Against External Compute

These tests address a specific deployment reality: agents run on compute nodes owned by external parties. OMC controls the verifier/registrar but **not** the agent side. Misbehaving or misconfigured agents can send unexpected data that impacts verifier performance. These tests validate that the verifier is resilient to such scenarios.

**Context:** It has been observed that a compute owner is sending MB (Measured Boot) logs in the quote response even though MB policy is not configured on the verifier side. The verifier receives and processes this data unnecessarily, consuming memory and CPU.

### Agent Response Profile — What's Normal vs Abnormal

The quote response from an agent (`GET /quotes/integrity`) contains:

| Field | Expected (no IMA, no MB) | Abnormal |
|---|---|---|
| `quote` | ~1-2 KB (TPM quote blob) | > 10 KB |
| `pubkey` | ~1 KB (RSA/ECC public key) | > 5 KB |
| `ima_measurement_list` | `null` (IMA not enabled) | Non-null, any size |
| `mb_measurement_list` | `null` (MB not configured) | Non-null, potentially MBs |
| `boottime` | Integer (unix timestamp) | Non-integer, string, huge number |
| Total response | ~5-10 KB | > 100 KB |

### Tests

#### NEG-AGT-01: Agent Sends MB Log When MB Policy Not Configured

**Purpose:** Validate verifier behavior when an agent includes `mb_measurement_list` in its quote response but no MB policy is assigned to that agent.

| Setup | 10 agents attesting normally, no MB policy configured on verifier |
|---|---|
| Action | Configure 1 agent simulator to include a 2 MB `mb_measurement_list` in every quote response |
| Duration | 4 hours |

**Expected behavior:** The verifier receives the MB log in `process_quote_response()` (`cloud_verifier_common.py` line 58: `mb_measurement_list = json_response.get("mb_measurement_list", None)`). Since `mb_policy` is `None`, the MB validation is skipped (`tpm_main.py` line 453: `if mb_policy is not None`). But the data is still received, parsed from JSON, and held in memory during the quote processing cycle.

**Pass criteria:**
- Verifier does not crash
- Memory spike per attestation cycle for the offending agent: < 5 MB (the 2 MB log is transient, should be GC'd after processing)
- Other 9 agents: zero impact on attestation latency
- No `FAILED` state for the offending agent (MB log is ignored, not rejected)

**Fail indicators:**
- RSS grows by 2 MB per cycle for the offending agent (log not being freed) → memory leak
- Other agents' attestation latency increases → the large response is blocking the event loop

**Regression value:** This is the exact scenario observed in production. Must be in nightly CI.

#### NEG-AGT-02: Agent Sends Oversized MB Log (10 MB+)

**Purpose:** Find the threshold at which an MB log impacts verifier stability.

| Setup | 50 agents attesting normally |
|---|---|
| Action | Configure 5 agents to send 10 MB `mb_measurement_list` each |
| Duration | 2 hours |

**Pass criteria:**
- Verifier RSS spike < 100 MB above baseline during attestation cycles
- No OOMKill
- Other 45 agents unaffected

**Fail indicators:**
- RSS spike > 200 MB → 5 agents × 10 MB × concurrent processing = 50 MB minimum, but if not freed promptly, accumulates
- OOMKill → keylime has no response size limit (confirmed: no `MAX_RESPONSE_SIZE` check in codebase)

#### NEG-AGT-03: Agent Sends IMA Measurement List When IMA Not Configured

**Purpose:** Same as NEG-AGT-01 but for IMA instead of MB.

| Setup | 10 agents, no IMA runtime policy configured |
|---|---|
| Action | 1 agent sends 5 MB `ima_measurement_list` in every response |
| Duration | 4 hours |

**Pass criteria:** Same as NEG-AGT-01. IMA list received but validation skipped. Memory transient, not accumulated.

#### NEG-AGT-04: All Agents Send Bloated Responses Simultaneously

**Purpose:** Worst case — every agent sends large unnecessary data.

| Setup | 100 agents |
|---|---|
| Action | All 100 agents include 1 MB `mb_measurement_list` in every response |
| Duration | 2 hours |

**Expected:** At `quote_interval=180`, agents are polled in staggered fashion. But with no concurrency semaphore, multiple large responses can be in-flight simultaneously.

**Pass criteria:**
- Verifier RSS < 1.5 GiB (baseline ~300 MB + transient large responses)
- No OOMKill
- All agents continue attesting

**Fail indicators:**
- RSS > 2 GiB → concurrent large responses accumulating faster than GC can free them
- Agents entering `GET_QUOTE_RETRY` → verifier too slow processing large responses, timing out on subsequent agents

#### NEG-AGT-05: Agent Response Size Grows Over Time

**Purpose:** Detect agents whose response size increases gradually (e.g., IMA log growing as files are accessed).

| Setup | 20 agents |
|---|---|
| Action | 5 agents start with 10 KB response, grow by 100 KB per attestation cycle |
| Duration | 24 hours (480 cycles × 100 KB = ~48 MB final response size per agent) |

**Pass criteria:**
- Verifier handles growing responses without crash
- Identify the response size at which attestation latency degrades
- Document the ceiling: "agent responses above X MB cause verifier degradation"

#### NEG-AGT-06: Agent Sends Malformed JSON in Quote Response

**Purpose:** Verify verifier handles unparseable responses.

| Scenarios | (a) Invalid JSON, (b) Valid JSON but missing `quote` field, (c) `quote` field is null, (d) Extra unexpected fields |
|---|---|

**Pass criteria per scenario:**
- (a): Agent enters `GET_QUOTE_RETRY` → `FAILED`. No crash.
- (b): `process_quote_response()` catches KeyError, returns Failure. Agent → `FAILED`.
- (c): Quote validation fails. Agent → `FAILED`.
- (d): Extra fields ignored. Agent continues attesting normally.

#### NEG-AGT-07: Agent Response Latency Varies Wildly

**Purpose:** Verify verifier handles agents with inconsistent response times.

| Setup | 20 agents |
|---|---|
| Action | 5 agents alternate between 100ms and 9.5s response time (just under 10s timeout) |
| Duration | 4 hours |

**Pass criteria:**
- Erratic agents stay in `GET_QUOTE` (no false timeouts)
- Stable agents unaffected
- No memory accumulation from the variable-latency agents

#### NEG-AGT-08: Agent Sends Response After Timeout

**Purpose:** Verify verifier handles late responses correctly (agent responds after `request_timeout` has expired).

| Setup | 10 agents |
|---|---|
| Action | 2 agents configured with 15s response latency (exceeds 10s timeout) |

**Expected:** Verifier times out at 10s, closes the connection, moves to retry. Agent's late response arrives on a closed connection — should be discarded.

**Pass criteria:**
- Timed-out agents enter `GET_QUOTE_RETRY` → `FAILED` after max_retries
- No memory leak from orphaned late responses
- No "ghost" state updates from late responses arriving after the agent is already in `FAILED`

### Monitoring Additions for Agent Response Tests

Add these metrics to the monitoring stack (Section 2.3) when running agent response tests:

| Metric | Source | Interval |
|---|---|---|
| Quote response size per agent | Verifier logs (add logging if not present) | Per attestation cycle |
| Quote processing time per agent | Verifier logs | Per attestation cycle |
| `mb_measurement_list` presence | Verifier logs / API | Per attestation cycle |
| `ima_measurement_list` presence | Verifier logs / API | Per attestation cycle |

### Recommended OMC Safeguards

Based on these tests, OMC should implement:

1. **Response size monitoring** — Track quote response size per agent via OMC metrics. Alert when any agent's response exceeds a threshold (e.g., 100 KB when no IMA/MB is configured).
2. **Agent response size limit** — If keylime doesn't add an upstream `MAX_RESPONSE_SIZE`, OMC can enforce one at the proxy/ingress layer.
3. **MB/IMA log presence alerting** — If MB and IMA are not configured, alert when agents include these fields. This catches the exact scenario observed in production.

### CI Integration

| Test | Frequency | Duration | Blocking? |
|---|---|---|---|
| NEG-AGT-01 (MB log, no policy) | **Nightly** | 30 min | **Yes** — this is the observed production issue |
| NEG-AGT-04 (all agents bloated) | Weekly | 2h | No |
| NEG-AGT-06 (malformed JSON) | Nightly | 15 min | Yes |
| NEG-AGT-08 (late response) | Weekly | 30 min | No |
| All others | Weekly | 4h total | No |
