# RAS-IS.pdf — Review and Validation

Review of the OMC-55661 SP3 Remote Attestation Server Implementation Specification (PA1, dated 2026-03-12). Validated against the keylime 7.14.1 codebase.

---

## Review Context: What an Implementation Sketch Should Be

An implementation sketch (IS) is a preliminary design artifact that bridges high-level architecture and actual coding. It should provide:

- **Component structure** — what modules/services exist, how they relate
- **Key design decisions** — chosen approaches with rationale, rejected alternatives
- **Interface contracts** — how components communicate (APIs, schemas, protocols)
- **Data flow** — how data moves through the system for each use case
- **Provisioning of enough detail** that a developer can begin implementation without ambiguity on the "what" (the "how" can evolve during coding)

An IS is not expected to be production-ready documentation. Rough edges, incomplete sections, and evolving details are normal. However, it must contain enough substance that a reviewer can assess whether the proposed design is sound and implementable. The bar is: "Can a developer start coding from this?"

---

## Overall Assessment

The document covers three use cases: EK validation alarms (UC1), scale/HA (UC2), and RAS REST API (UC3).

**UC1 (EK validation and upgrade/rollback)** meets the IS bar — it has concrete flows, helm config, sequence diagrams, and enough detail to start implementation. Issues are correctness errors (migration counts) and missing edge cases, not missing design.

**UC3 (REST API)** has architectural direction but falls short of the IS bar — the MVC layering and DAL concept are sketched, but there are no endpoint definitions, schemas, or state derivation logic. A developer cannot start coding the API from this.

**UC2 (Scale and Redundancy/HA)** does not meet the IS bar. It reads as a **test report and demo setup guide**, not an implementation sketch. See Section 3 for detailed analysis.

---

## 1. Document Structure Issues

| # | Issue | Severity | Location |
|---|---|---|---|
| 1.1 | **Duplicate section numbering.** Section 1 "General Information" appears twice — once in the ToC structure and again after Section 15 (Test Specification). The second occurrence contains the actual content (purpose, team, revision info). | Medium | Page structure |
| 1.2 | **Placeholder sections not filled.** Sections 5 (Interface Specification), 6 (Security), 7 (HA & Fault Handling), 8 (Scalability & Performance), 9 (Serviceability), 10 (CPI Impacts), 13 (Implementation Analysis), 14 (References), and 15 (Test Specification) are all template placeholders with no content. For a PA1 this is acceptable for most sections, but Sections 6 (Security) and 7 (HA & Fault Handling) are directly relevant to the use cases and should have at least a sketch. | High | Sections 5-15 |
| 1.3 | **Section 4.1 is empty.** "System Overview and Impacts" under Functional Specification has only template instructions, no actual content. | Medium | Section 4.1 |
| 1.4 | **Purpose statement is too narrow.** Section 1.1 says "This IS covers the raising and clearing of EK certificate validation alarms" — but the document actually covers three use cases (EK alarms, scale/HA, REST API). The purpose should reflect the full scope. | Low | Section 1.1 |

---

## 2. UC1: EK Validation — Comments

### 2.1. EK Validation Flow

| # | Issue | Severity | Comment |
|---|---|---|---|
| 2.1.1 | **Flow numbering is inconsistent.** Steps jump from 1 to 4 to 5 to 6 to 7 to 7 (duplicate) to 1-2. This makes the flow hard to follow. | Medium | Section 4.2.1.1.1 |
| 2.1.2 | **Webhook event payload has trailing comma.** The JSON sample has `"severity": "high",` with a trailing comma before the closing brace — invalid JSON. | Low | Section 4.2.1.1.2 |
| 2.1.3 | **CronJob directly queries registrar DB.** The document says the CronJob makes "a call to the registrar db to retrieve the ek_certs for all registered agents." This bypasses the registrar API and couples the CronJob directly to the DB schema. If the registrar schema changes (column rename, table restructure), the CronJob breaks silently. It should use the registrar REST API instead. | High | Section 4.2.1.1.5 |
| 2.1.4 | **CronJob EK validation and VM metrics auto-clear interaction not explained.** The document says "vm metrics automatically clears the alarm if any" when metrics stop arriving, and the CronJob exists to keep metrics flowing. But it doesn't explain what happens if the CronJob fails — does the alarm auto-clear (false negative) or persist? This is a critical safety question for a security feature. | High | Section 4.2.1.1.5 |
| 2.1.5 | **`ek_check_script` is a tenant-side config.** The code shows `config.get("tenant", "ek_check_script")` in `keylime/tenant.py` line 749. The document describes it as part of `onboard_agents.py` which is correct (tenant-driven), but doesn't mention that this script path is configured in `omc_tenant.conf`, not the registrar or verifier config. | Low | Section 4.2.1.1.1 |

### 2.2. Upgrade and Rollback Handling

| # | Issue | Severity | Comment |
|---|---|---|---|
| 2.2.1 | **Migration count for 7.14.1 is wrong.** The document claims 7.14.1 has "37 migrations" with head `5a8b2c3d4e6f`. The actual codebase has **39 migration files** and the chain to `5a8b2c3d4e6f` is 39 steps. The chain to `57b24ee21dfa` (7.13.x head) is 35, not 33 as claimed. | High | Section 4.2.1.2.2 |
| 2.2.2 | **`517a2d6b5cd3` is not "36+ migrations."** The chain to `517a2d6b5cd3` is exactly 38 migrations, not "36+". | Medium | Section 4.2.1.2.2 |
| 2.2.3 | **`870c218abd9a` migration bug mentioned but not detailed.** The document says this migration has "bugs in their `downgrade()` functions" but doesn't specify what the bug is or how the patched version differs. Reviewers need this to assess the fix. | Medium | Section 4.2.1.2.2 |
| 2.2.4 | **Rollback script retries 3 times with 5s delay — but no failure handling.** What happens after 3 failed retries? Does the rollback abort? Does it proceed with a mismatched schema (guaranteed CrashLoopBackOff)? The document doesn't specify the terminal failure behavior. | High | Section 4.2.1.2.4 |
| 2.2.5 | **`alembic_utility` is described as a "compiled standalone binary" but no details on how it's built or shipped.** Is it a Go binary? A PyInstaller bundle? Where does it get the DB connection string? How does it authenticate to PostgreSQL? | Medium | Section 4.2.1.2.4 |
| 2.2.6 | **Helm values show `head: "57b24ee21dfa"` but the document says 7.14.1 head is `5a8b2c3d4e6f`.** The example helm values are inconsistent with the migration table. The comment says "update when Keylime is uplifted" but the example itself is already stale for the current build. | High | Section 4.2.1.2.5 |

**Corrected migration counts (validated against codebase):**

| Revision | Actual Chain Length | Document Claim | File |
|---|---|---|---|
| `57b24ee21dfa` (7.13.x head) | 35 | 33 | `57b24ee21dfa_extend_meta_data_field.py` |
| `870c218abd9a` (push attestation) | 36 | Not stated | `870c218abd9a_add_push_attestation_support.py` |
| `517a2d6b5cd3` (master/WA head) | 38 | "36+" | `517a2d6b5cd3_add_consecutive_attestation_failures.py` |
| `5a8b2c3d4e6f` (7.14.1 head) | 39 | 37 | `5a8b2c3d4e6f_hash_session_tokens.py` |

---

## 3. UC2: Scale and Redundancy/HA — Does Not Meet IS Bar

### 3.0. Core Problem: This Is a Demo/Test Report, Not an Implementation Sketch

UC2 is titled "Scale and Redundancy/HA" but contains:

- A **simulator setup guide** (how to deploy mock agents with SWTPM) — Section 4.2.2.1
- A **scale test report** (600 simulators ran for 48 hours, "no abnormalities") — Section 4.2.2.2

It does **not** contain:

- Any design for **redundancy** (how to survive a verifier/registrar failure)
- Any design for **HA** (failover mechanism, standby pods, leader election)
- Any design for **scale-out** (how to add verifier capacity as agent count grows)
- Component diagrams showing the HA topology
- Data flow for failover scenarios
- Interface contracts between OMC and keylime for partition management
- Configuration parameters for HA (verifier IDs, lease timers, self-fencing)

An implementation sketch for "Scale and Redundancy/HA" should answer: *"What do we build, how do the components interact, and what happens when something fails?"* UC2 answers: *"We built a simulator and ran a load test."*

**Assessment:** The simulator section (4.2.2.1) is a valid and well-documented **test infrastructure** deliverable. The scale test section (4.2.2.2) is a valid **test report**. Neither is an implementation sketch for scale or HA. They belong in a test plan or test results document, not in the IS under a use case titled "Scale and Redundancy/HA."

### 3.1. What's Missing: The Actual Scale/HA Design

For UC2 to meet the IS bar, it needs to sketch answers to these questions:

**Scale design:**
- How are agents distributed across verifier instances? (verifier ID partitioning via OMC hash ring? static assignment? manual?)
- What is the maximum agents per verifier? How was this determined?
- How does OMC enroll an agent to a specific verifier partition?
- What happens when a new verifier is added? (agent migration? rebalancing?)
- What happens when a verifier is removed? (agent reassignment?)

**Redundancy design:**
- How many active verifiers and how many standbys?
- What HA model? (N+1? 1:1? Active-active?)
- What is the failover mechanism? (K8s Leases? PostgreSQL locks? Manual?)
- What is the failover time SLA?

**Fault handling:**
- What happens when a verifier pod crashes? (Who detects it? Who takes over? How fast?)
- What happens during a network partition? (Split-brain prevention? Self-fencing?)
- What happens when the registrar is down? (Agent registration blocked — impact on new agent onboarding?)
- What happens during a rolling upgrade? (Attestation gap? Agent migration?)

**Configuration:**
- What config parameters control the HA behavior?
- What K8s resources are needed? (StatefulSet? Leases? RBAC?)
- What helm values are introduced?

The RAS-HA design study (reviewed separately in `RAS-HA-Review.md`) addresses many of these questions. UC2 should either incorporate that design or explicitly reference it. Currently it does neither.

### 3.2. Agent Simulator (SWTPM) — Well-Documented Test Infrastructure

| # | Issue | Severity | Comment |
|---|---|---|---|
| 3.2.1 | **Simulator architecture is well-documented.** The 3-container pod design (swtpm + tpm2-tools + agent) is clearly explained with the ASCII diagram. This is one of the strongest sections in the document. | Positive | Section 4.2.2.1 |
| 3.2.2 | **Real vs simulator comparison table is useful but incomplete.** Missing comparison for: quote response size, IMA measurement list behavior, memory footprint per agent, and attestation cycle timing. These are the factors that affect the 2:1 equivalence ratio. | Medium | Section 4.2.2.1 |
| 3.2.3 | **Self-signed mock CA for EK certs is a significant divergence from real agents.** Real agents have vendor-signed EK certs stored in TPM NV RAM. The simulator uses self-signed certs. This means the EK validation flow (UC1) tested with simulators does NOT exercise the real certificate chain validation path. The document should explicitly state this limitation. | High | Section 4.2.2.1 |
| 3.2.4 | **Simulator section belongs in a test plan, not the IS.** The step-by-step deployment instructions (download repo, build images, generate CA, deploy agents) are operational procedures for test infrastructure. They're valuable but they're not an implementation sketch — they don't describe what OMC builds, they describe how to set up a test environment. | Medium | Section 4.2.2.1 |

### 3.3. Scale Test Report — Valid Data, Wrong Document

| # | Issue | Severity | Comment |
|---|---|---|---|
| 3.3.1 | **2:1 simulator-to-real-agent ratio is stated but not justified.** The document says "approximately 2 agent simulators are required to produce verifier resource consumption equivalent to that of 1 real agent" but provides no data to support this. The comparison graphs are "blocked URL" (not accessible). Without the actual data, this ratio cannot be validated. | Critical | Section 4.2.2.2 |
| 3.3.2 | **600 simulators tested but `num_workers=8` is a known bug.** The test configuration shows `num_workers=8` but as documented in the Verifier Memory Bloat Analysis (Section 12), the `num_workers` config is **ignored** by the new Server base class — the actual worker count defaults to `cpu_count()`. The document doesn't acknowledge this. The "no abnormalities" claim over 48 hours needs to be re-evaluated: was the pod actually running 8 workers or `cpu_count()` workers? If the latter, the 8Gi memory limit was absorbing a 32-worker memory footprint, masking the bug. | Critical | Section 4.2.2.2 |
| 3.3.3 | **`db_pool_sz_ovfl=20,30` with potentially 32 workers = 1,600 max DB connections.** If the `num_workers` bug was active during the 600-agent test, the verifier may have been running 32 workers × 50 connections each = 1,600 potential DB connections. The document doesn't mention DB connection monitoring. | High | Section 4.2.2.2 |
| 3.3.4 | **Memory limit of 8Gi with `request_timeout=30` and 600 agents.** With the `num_workers` bug, 32 workers × ~100-130 MB each = ~3.2-4.2 GB baseline before any agent polling overhead. The 8Gi limit may have been masking the problem. The document should report actual peak memory during the 48-hour test. | High | Section 4.2.2.2 |
| 3.3.5 | **Scale target is 50 real agents but test used 600 simulators.** With the 2:1 ratio, 600 simulators = 300 equivalent real agents. But the target is 50. Why test at 6× the target? This is good for headroom validation but the document doesn't explain the rationale or what the actual ceiling was. | Medium | Section 4.2.2.2 |
| 3.3.6 | **"No abnormalities" is not a test result.** A scale test report should include: peak memory, peak CPU, DB connection count, attestation latency p50/p95/p99, quote failure rate, and whether these stayed within defined thresholds. "No abnormalities" is an observation, not a measured outcome. | High | Section 4.2.2.2 |
| 3.3.7 | **`quote_interval=180` is not mentioned as a tuning parameter.** The config table lists it but doesn't explain why 180s was chosen or what the tradeoff is (longer interval = less load but slower detection of compromised agents). | Low | Section 4.2.2.2 |

### 3.4. The "Redundancy/HA" Part Is Entirely Absent

| # | Issue | Severity | Comment |
|---|---|---|---|
| 3.4.1 | **No HA design exists in the document.** UC2 is titled "Scale and Redundancy/HA" but the content only covers scale testing. There is no design for redundancy or HA — no verifier ID partitioning, no failover mechanism, no standby pods. Section 7 (HA & Fault Handling) is empty. | Critical | Section 4.2.2 |
| 3.4.2 | **No reference to the RAS-HA design study.** The RAS-HA study (reviewed separately) proposes K8s Lease wrappers, verifier ID partitioning, and active-standby failover. None of this appears in the IS. At minimum, UC2 should reference the HA study and state which option was selected. | Critical | Section 4.2.2 |
| 3.4.3 | **The JIRA items under UC2 include HA stories but the IS doesn't cover them.** The Design SOC table lists `OMC-73182 PRI-3: RAS HA SUPPORT` and `OMC-73183 PRI-2: RAS REDUNDANCY SUPPORT` under UC2. These are tracked requirements with no corresponding design in the IS. | Critical | Section 2.2 |

### 3.5. Recommendation for UC2

**Rescope UC2.** The Scale/HA study is still in progress. Including a "Redundancy/HA" use case at this stage — with no design behind it — creates a false impression of coverage. Instead, UC2 should be rescoped to what's achievable now:

**Proposed UC2 scope: "Single Verifier Instance Optimization"**

This covers maximizing the capacity and reliability of a single verifier instance through configuration tuning and associated OMC code changes. HA/redundancy becomes a separate use case in a future IS once the HA study concludes.

What this UC2 should contain:

1. **Configuration tuning for scale target** (Section 3.6 below) — the specific verifier config values, resource limits, and env vars needed to reliably support the target agent count on a single instance. This is the core IS content.

2. **OMC code changes to support the config** — what OMC must do to deploy the verifier with the correct configuration:
   - Helm chart changes: `PYTHON_CPU_COUNT` env var, corrected resource limits, liveness probe using `/version`
   - Verifier config template: tuned values for `request_timeout`, `retry_interval`, `db_pool_sz_ovfl`
   - Monitoring: staleness detection via `last_received_quote` (already defined in the Feature Study)

3. **Agent simulator** — retain the SWTPM simulator section as test infrastructure supporting this UC, but move the step-by-step deployment instructions to an appendix or test plan.

4. **Scale test validation** — retain the 600-simulator test results as validation data, but with corrected analysis (acknowledge the `num_workers` bug, report actual metrics not just "no abnormalities").

**What to remove from UC2:** All references to "Redundancy/HA" in the title and scope. The JIRA items `OMC-73182` (HA Support) and `OMC-73183` (Redundancy Support) should be tracked as a separate future use case, not claimed in this IS.

### 3.6. Missing IS Content: Verifier Configuration for Scale Target

The IS lists config values (`num_workers=8`, `db_pool_sz_ovfl=20,30`, `request_timeout=30`, `quote_interval=180`) without rationale. Configuration tuning is core IS content for a scale use case — these values determine whether the 50-agent target is achievable. The IS should include a section covering the following.

#### 3.6.1. Parameters That Must Be Corrected

| Parameter | IS Value | Recommended | Rationale |
|---|---|---|---|
| `num_workers` | 8 | 1 | Config is **ignored** due to a bug in the Server base class — actual worker count defaults to `cpu_count()` (see `Verifier_Memory_Bloat_Analysis.md` Section 12). Until the upstream fix, use `PYTHON_CPU_COUNT=1` env var. Even if fixed, 50 agents don't need multiple workers. Each extra worker adds ~100-130 MB baseline RSS. |
| `retry_interval` | 8 | 2 | **Dangerous at 8 with exponential backoff.** `8^3 = 512 seconds` (~8.5 min) for the 3rd retry delay. A single unreachable agent holds memory for ~11 minutes. At `retry_interval=2`: `2^3 = 8 seconds`, total hold ~44 seconds. 15× improvement. Must be ≤ 2 when `exponential_backoff=true`. |
| `request_timeout` | 30 | 10 | Agents respond in ~700ms. 30s means an unreachable agent holds a coroutine + TCP/TLS connection for 30s. At 10s, hold time drops 3×. |
| `db_pool_sz_ovfl` | 20,30 | 5,10 | 50 agents need at most a few concurrent DB queries per worker. 20,30 = up to 50 connections per worker. With the `num_workers` bug active, this becomes `cpu_count()` × 50 = potentially 1,600 connections. |

#### 3.6.2. Parameters That Must Be Added

| Parameter | Recommended | Rationale |
|---|---|---|
| `PYTHON_CPU_COUNT` (env var) | 1 | **Required workaround** until the upstream `num_workers` bug is fixed. This overrides `multiprocessing.cpu_count()` and is the only way to control worker count in the current codebase. Python ≥ 3.13 required (container has 3.14). |
| `exponential_backoff` | true | Default. Safe only when `retry_interval` ≤ 2. The IS must state this constraint explicitly. |
| CPU request / limit | 200m / 500m | With 1 worker, far less CPU needed than the current 800m / 1000m. |
| Memory request / limit | 512Mi / 1Gi | With 1 worker and 50 agents (no IMA), steady-state is ~250-350 MB. 1Gi is generous. If growth exceeds this, it confirms a genuine leak rather than being masked by an 8Gi limit. |

#### 3.6.3. The `retry_interval=8` Problem in Detail

The IS sets `retry_interval=8` with the default `exponential_backoff=true` and `max_retries=3`. The `retry_time()` function computes `base^ntries` with no cap:

| Retry # | Delay (`8^n`) | + timeout (30s) | Cumulative |
|---|---|---|---|
| 1 | 8s | 30s | 38s |
| 2 | 64s | 30s | 132s |
| 3 | 512s (~8.5 min) | 30s | 674s (~11 min) |

With `retry_interval=2` and `request_timeout=10`:

| Retry # | Delay (`2^n`) | + timeout (10s) | Cumulative |
|---|---|---|---|
| 1 | 2s | 10s | 12s |
| 2 | 4s | 10s | 26s |
| 3 | 8s | 10s | 44s |

Same retry count, ~44 seconds instead of ~11 minutes. During each delay, `call_later` pins the agent dict + policies in memory (unreclaimable by GC). If 10 agents go unreachable simultaneously, that's 10 sets of objects pinned for 11 minutes vs 44 seconds.

#### 3.6.4. Known Keylime Limitations the IS Must Acknowledge

The IS should reference the Verifier Memory Bloat Analysis and at minimum call out:

| Limitation | Impact on Scale Target | Mitigation |
|---|---|---|
| `num_workers` config ignored (Section 12) | Verifier spawns `cpu_count()` workers instead of configured value. 32 workers × ~100 MB = ~3.2 GB baseline. | `PYTHON_CPU_COUNT=1` env var |
| No concurrency control on polling (Section 2.3) | All agents polled concurrently. At 50 agents this is fine (~2.5 MB connections). At 500+ it's a problem. | Not fixable without upstream semaphore. Irrelevant at 50 agents. |
| Uncapped exponential backoff (Section 2.6) | `retry_interval` > 2 causes delays of minutes to hours per unreachable agent. | Set `retry_interval=2`. Upstream `max_retry_delay` cap needed for full fix. |
| No health endpoint (Section 7.5) | K8s cannot detect a stuck verifier. Only `/version` exists (proves HTTP server is alive, not that polling is functional). | Use `/version` as basic liveness probe. Upstream `/health` endpoint needed. |
| Python pymalloc never returns memory to OS (Section 10.7) | RSS grows monotonically over time even after GC frees objects. | Size memory limits to expected steady-state + headroom. Consider periodic pod restart (e.g., every 24h). |

#### 3.6.5. Recommended Helm Values for 50-Agent Scale Target

```yaml
eric-omc-ra-verifier:
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
  env:
    - name: PYTHON_CPU_COUNT
      value: "1"
  verifier:
    num_workers: 1            # Currently ignored — PYTHON_CPU_COUNT is the actual control
    request_timeout: 10
    quote_interval: 180
    max_retries: 3
    retry_interval: 2         # MUST be ≤ 2 when exponential_backoff=true
    exponential_backoff: true
    db_pool_sz_ovfl: "5,10"
  livenessProbe:
    httpGet:
      path: /version
      port: 8881
      scheme: HTTPS
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 3
```

---

## 4. UC3: RAS REST API — Comments

| # | Issue | Severity | Comment |
|---|---|---|---|
| 4.1 | **Architecture description is verbose but lacks specifics.** The MVC description is ~500 words of prose but doesn't include: API endpoint paths, request/response schemas, HTTP methods, error codes, or pagination parameters. These are essential for an IS. | High | Section 4.2.3 |
| 4.2 | **DAL directly queries Keylime's PostgreSQL databases.** The document says the DAL "executes named queries" against "Keylime Registrar and Verifier PostgreSQL databases." This bypasses Keylime's REST API and couples OMC directly to Keylime's internal DB schema. If Keylime changes its schema in a future version (which it does — see the migration chain), the DAL breaks. This is a significant architectural risk. | Critical | Section 4.2.4 |
| 4.3 | **DAL uses FastAPI on port 8600 — a new microservice.** This introduces a new service that needs its own deployment, health checks, resource limits, and monitoring. None of this is specified. Section 5 (Interface Specification) is empty. | High | Section 4.2.4 |
| 4.4 | **"100+ req/sec" and "sub-50ms query response times" claimed without benchmarks.** These are performance claims with no supporting data, test methodology, or conditions under which they were measured. | Medium | Section 4.2.4 |
| 4.5 | **No mention of staleness detection or `unknown` state.** The OMC RAS Feature Study defines a staleness threshold (300s) that overrides keylime's `pass` state to `unknown` when `last_received_quote` is stale. The IS doesn't mention this at all. The REST API must implement this logic — it's not optional. | High | Section 4.2.3 |
| 4.6 | **No mention of agent state derivation logic.** The Feature Study defines a mapping from keylime's 11 `operational_state` values to 7 OMC states (registered, pending, pass, fail, paused, terminated, unknown). The IS doesn't reference this mapping. Without it, the API will return raw keylime states that the GUI can't interpret. | High | Section 4.2.3 |
| 4.7 | **Six API operations listed but no endpoint definitions.** List, Get, Attest, Delete, Stop, Resume are mentioned but there are no paths (`/ras/agents`, `/ras/agents/{id}`), no HTTP methods, no request bodies, no response schemas. | High | Section 4.2.3.1 |
| 4.8 | **Pagination mentioned but not specified.** "Pagination support for efficient data retrieval" is listed as a feature but there's no specification of the pagination model (offset/limit? cursor-based?), default page size, or maximum page size. | Medium | Section 4.2.3.1 |
| 4.9 | **mTLS between API Server and DAL not detailed.** The architecture mentions "mTLS to the OMC API Server" but doesn't specify certificate management, rotation, or what happens when certs expire. | Medium | Section 4.2.3.2 |

---

## 5. Security Section — Empty

| # | Issue | Severity | Comment |
|---|---|---|---|
| 5.1 | **Section 6 (Security) is a template with no content.** For a remote attestation service — a security feature by definition — this is a critical gap. At minimum it should cover: mTLS certificate management, API authentication/authorization model, EK cert chain validation trust anchors, DB credential management, and network policies between RAS components. | Critical | Section 6 |

---

## 6. Cross-Cutting Issues

| # | Issue | Severity | Comment |
|---|---|---|---|
| 6.1 | **No reference to known keylime limitations.** The Verifier Memory Bloat Analysis documents critical issues (`num_workers` bug, uncapped exponential backoff, no concurrency control, no health endpoints) that directly affect the scale and HA claims in this IS. None are referenced. | Critical | Throughout |
| 6.2 | **UC2 should be rescoped to single-instance optimization.** The Scale/HA study is still in progress. Including "Redundancy/HA" in UC2's title with no design behind it creates a false impression of coverage. UC2 should be rescoped to "Single Verifier Instance Optimization" (config tuning + OMC code changes). HA/redundancy should become a separate use case in a future IS once the HA study concludes. JIRA items `OMC-73182` and `OMC-73183` should not be claimed in this IS. | Critical | Section 4.2.2 |
| 6.3 | **Team ownership split (Pallava vs Specter) but no interface contract.** Pallava owns Verifier/Registrar/Tenant, Specter owns Monitoring. The EK validation flow crosses both teams (tenant triggers validation, monitor generates metrics). There's no interface specification between them — only a webhook event payload sample. | Medium | Section 1.2 |
| 6.4 | **Document is PA1 (1/3rd review) — many gaps are expected.** The revision info shows this is the first draft for review. The empty sections and missing details are appropriate for this stage, but the issues flagged as Critical should be addressed before PA2. | Context | Section 1.3 |

---

## 7. Summary

| Category | Critical | High | Medium | Low | Positive |
|---|---|---|---|---|---|
| Document Structure | 0 | 1 | 2 | 1 | 0 |
| UC1: EK Validation | 0 | 3 | 3 | 2 | 0 |
| UC2: Scale/HA | 5 | 3 | 3 | 1 | 1 |
| UC3: REST API | 1 | 4 | 3 | 0 | 0 |
| Security | 1 | 0 | 0 | 0 | 0 |
| Cross-Cutting | 2 | 0 | 1 | 0 | 0 |
| **Total** | **9** | **11** | **12** | **4** | **1** |

### IS Bar Assessment by Use Case

| Use Case | Meets IS Bar? | Rationale |
|---|---|---|
| UC1: EK Validation + Upgrade/Rollback | **Yes** | Concrete flows, helm config, sequence diagrams. Issues are correctness errors, not missing design. A developer can start coding from this. |
| UC2: Scale and Redundancy/HA | **No** | Contains a simulator setup guide and a scale test report — both valid deliverables, but neither is an implementation sketch. The "Redundancy/HA" part is entirely absent despite being in the title. **Recommendation:** Rescope to "Single Verifier Instance Optimization" — config tuning + OMC code changes for a single verifier. Drop HA from scope until the HA study concludes. With the config tuning section added (Section 3.6), the rescoped UC2 would meet the IS bar. |
| UC3: RAS REST API | **Partially** | Architectural direction (MVC, DAL, proxy layer) is sketched. But no endpoint definitions, no schemas, no state derivation logic. A developer can start on the DAL plumbing but cannot implement the API contract. |

### Top Priority Items for PA2

1. **UC2: Rescope to "Single Verifier Instance Optimization"** (Section 3.5) — Remove "Redundancy/HA" from UC2 title and scope. The HA study is in progress; claiming HA coverage with no design is misleading. Scope UC2 to config tuning + OMC code changes for a single verifier instance. Track HA as a separate future use case.
2. **UC2: Add configuration tuning section** (Section 3.6) — The IS lists config values without rationale. Add the parameter corrections (especially `retry_interval=2`, `PYTHON_CPU_COUNT=1`), resource limits, and known keylime limitations. This is the core IS content for the rescoped UC2.
3. **UC2: Acknowledge the `num_workers` bug and re-evaluate scale test** (Section 3.3.2) — The 600-agent test results may be invalid. Report actual worker count and peak memory.
4. **UC2: Justify the 2:1 simulator ratio with data** (Section 3.3.1) — The scale target depends on this ratio. Unblock the comparison graphs or provide the raw data.
5. **UC1: Fix migration counts** (Section 2.2.1) — Verifiably wrong against the codebase.
6. **UC3: Specify REST API endpoints** (Section 4.7) — The IS has no usable API specification.
7. **UC3: Address DAL direct DB access risk** (Section 4.2) — Coupling to keylime's internal schema is an architectural risk that should be a conscious, documented decision.
8. **UC3: Add staleness detection and state derivation** (Sections 4.5, 4.6) — The REST API is incomplete without these.
9. **Fill Security section** (Section 5.1) — Empty security section for a security feature.
