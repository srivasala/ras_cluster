# RAS Scale, HA, Stress & Soak Test Plan

Derived from: `Verifier_Memory_Bloat_Analysis.md`, `RAS-HA-Review.md`, `Keylime_Enterprise_Assessment.md`, `RAS-IS-Review.md`, `Keylime_Agent_Registration_Behavior.md`.

> **Note:** The quantification details in this plan — pass/fail thresholds (e.g., RSS limits, latency ceilings, connection counts), test durations, agent counts, and hardware sizing — are derived from codebase analysis and initial observations. They are **subjective starting points** and must be refined by the test architects and engineers through a fine-tuning exercise based on actual test execution results, production telemetry, and environment-specific characteristics.

---

## 1. Test Plan Structure

The test plan is organized into three progressive phases, each building on the previous:

| Phase | Scope | Verifier Topology | Prerequisites |
|---|---|---|---|
| **Phase A** | Single verifier instance — scale, stress, soak | 1 active verifier, no standby | Tuned config, agent simulators |
| **Phase B** | Multi-instance — scale-out, partitioning | N active verifiers (verifier ID partitioning via OMC hash ring) | Phase A validated, OMC hash ring implemented |
| **Phase C** | HA & redundancy — failover, split-brain, recovery | N active + standby verifiers (K8s Lease wrapper) | Phase B validated, HA wrapper implemented |

Each phase contains: Scale tests, Stress tests, Soak tests, and Edge Case tests appropriate to that topology.

---

## 2. Test Environment

### 2.1. Baseline Configuration (Tuned Single Instance)

All Phase A tests use this baseline. Phase B/C extend it with multi-instance config.

```yaml
# Verifier
PYTHON_CPU_COUNT: "1"
num_workers: 1              # Currently ignored — PYTHON_CPU_COUNT is the actual control
request_timeout: 10
quote_interval: 180
max_retries: 3
retry_interval: 2
exponential_backoff: true
db_pool_sz_ovfl: "5,10"
resources:
  requests: { cpu: 200m, memory: 512Mi }
  limits:   { cpu: 500m, memory: 1Gi }

# Registrar
PYTHON_CPU_COUNT: "1"
db_pool_sz_ovfl: "5,10"
resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

### 2.2. Agent Simulators

SWTPM-based agent simulators (3-container pod: swtpm + tpm2-tools + keylime-agent):
- Latency: 700ms (matching real agent response time)
- Jitter: 50ms
- Pull mode (agent serves HTTP, verifier polls)
- No IMA policies

### 2.3. Monitoring Stack

Every test must collect these metrics continuously:

| Metric | Source | Interval |
|---|---|---|
| Pod RSS memory | cgroup `memory.current` | 30s |
| Per-process RSS | `/proc/[pid]/status` VmRSS | 60s |
| CPU usage | `kubectl top pods` | 30s |
| DB connection count | `pg_stat_activity` | 60s |
| Agent states | Verifier bulk API (`/agents`) | 60s |
| `last_received_quote` per agent | Verifier API | 60s |
| Agents in `GET_QUOTE_RETRY` / `FAILED` | Verifier API | 60s |
| Attestation count per agent | Verifier API | 300s |
| Pod restart count | `kubectl get pods` | 60s |
| Verifier process count | `/proc` scan inside container | 300s |

---

## 3. Phase A — Single Verifier Instance

### 3A. Scale Tests

#### A-ST-01: Interim Target — 50 Agents

**Purpose:** Validate a single tuned verifier at the interim scale target.

| Parameter | Value |
|---|---|
| Agents | 100 simulators (2:1 ratio = 50 real equivalent) |
| Duration | 48 hours |
| Config | Baseline (Section 2.1) |

**Pass criteria:**
- Pod RSS < 500 MB for 48 hours
- All agents in `GET_QUOTE` after enrollment
- Zero `FAILED` agents due to `not_reachable`
- `last_received_quote` staleness < 360s for all agents
- DB connections ≤ 15
- CPU < 300m sustained
- Process count = 4 (entry + parent + Manager + 1 worker)

#### A-ST-02: Long-Term Target — 100 Agents

**Purpose:** Validate the 100-agent target on a single tuned instance.

| Parameter | Value |
|---|---|
| Agents | 200 simulators (2:1 ratio = 100 real equivalent) |
| Duration | 48 hours |
| Config | Baseline, memory limit raised to 1.5Gi |

**Pass criteria:**
- Pod RSS < 800 MB for 48 hours
- All agents in `GET_QUOTE` after enrollment
- Zero `FAILED` agents due to `not_reachable`
- Staleness < 360s for all agents
- CPU < 400m sustained

**Fail indicators:**
- RSS > 1 GiB → single instance insufficient for 100 agents; triggers Phase B (partitioning)
- Attestation latency > 3× `quote_interval` → verifier falling behind

#### A-ST-03: Scale Ceiling Discovery — Incremental Ramp

**Purpose:** Find the maximum agents a single tuned instance can handle.

| Parameter | Value |
|---|---|
| Starting agents | 100 simulators |
| Ramp | +50 simulators every 2 hours |
| Max | 600 simulators or until failure |
| Config | Baseline, memory limit 2Gi |

**Ceiling identified when:** OOMKilled, agents entering `FAILED` due to `not_reachable`, or attestation latency > 3× `quote_interval`.

#### A-ST-04: Registrar Bulk Registration

**Purpose:** Validate registrar handles burst registration at target scale.

| Parameter | Value |
|---|---|
| Agents | 200 simulators started simultaneously |

**Pass criteria:** All registered within 10 minutes, RSS < 400 MB, no `IntegrityError`, SharedDataManager alive.

#### A-ST-05: Simulator Ratio Validation

**Purpose:** Validate the 2:1 simulator-to-real-agent ratio.

| Parameter | Value |
|---|---|
| Phase 1 | 10 real agents, 48 hours |
| Phase 2 | 20 simulators (700ms), 48 hours, identical config |

**Pass criteria:** CPU and memory within ±20%. If ratio differs, recalibrate all simulator counts.

### 3B. Stress Tests

#### A-STR-01: All Agents Killed Simultaneously

**Purpose:** Verify verifier behavior when every agent becomes unreachable at once.

| Parameter | Value |
|---|---|
| Agents | 200 simulators, all attesting normally |
| Failure injection | `kubectl delete pods -l app=agent-simulator` (kill all agent pods) |
| Duration | Agents down for 15 minutes, then redeploy |

**Expected behavior:**
1. All 200 agents enter `GET_QUOTE_RETRY` within `request_timeout` (10s)
2. After `max_retries` (3) with exponential backoff (2s, 4s, 8s + 10s timeout each = ~44s total), all transition to `FAILED`
3. Memory spike from retry callbacks: 200 × ~50 KB × 3 retries = ~30 MB above baseline
4. After redeployment: agents re-register with registrar, verifier must be told to re-enroll them (manual `keylime_tenant -c add` or OMC re-enrollment)

**Pass criteria:**
- Verifier does NOT crash or OOMKill
- All agents reach `FAILED` state within 2 minutes (not stuck in retry)
- Memory spike < 200 MB above baseline
- After agent redeployment + re-enrollment: all agents resume `GET_QUOTE` within 2× `quote_interval`
- DB state is clean — no orphaned agent records in inconsistent states

**Key observation:** Agents in `FAILED` state do NOT automatically recover when they come back. The verifier stops polling them. Re-enrollment is required. This is a keylime design choice, not a bug — but OMC must handle it.

#### A-STR-02: Mass Enrollment Burst

**Purpose:** Verify verifier behavior when a large number of agents are enrolled simultaneously (fleet rollout).

| Parameter | Value |
|---|---|
| Existing agents | 100 simulators, attesting normally |
| Burst | 100 additional simulators enrolled within 60 seconds |

**Expected behavior:**
1. Verifier receives 100 POST requests in rapid succession
2. Each triggers `process_agent()` → `invoke_get_quote()` → 100 concurrent outbound HTTP requests (no semaphore)
3. Existing 100 agents continue being polled on their normal `quote_interval` cycle

**Pass criteria:**
- All 200 agents attesting within 5 minutes of burst
- No existing agents enter `FAILED` during the burst (existing attestation not disrupted)
- Memory spike < 200 MB above pre-burst baseline
- No DB connection pool exhaustion

#### A-STR-03: Unreachable Agent Storm — Partial

**Purpose:** Simulate a network partition affecting a subset of agents.

| Parameter | Value |
|---|---|
| Total agents | 200 simulators |
| Unreachable | 100 simulators (NetworkPolicy block) |
| Reachable | 100 simulators (unaffected) |
| Duration | 10 minutes, then restore |

**Pass criteria:**
- Reachable agents: zero impact on attestation latency or state
- Unreachable agents: transition to `FAILED` after retries (~44s)
- Memory spike < 100 MB
- After restore: unreachable agents require re-enrollment (they're in `FAILED`)
- No OOMKill

#### A-STR-04: Slow Agent Injection

**Purpose:** Verify behavior when agents respond near the timeout threshold.

| Parameter | Value |
|---|---|
| Normal agents | 160 simulators (700ms latency) |
| Slow agents | 40 simulators (8-9s latency, just under 10s timeout) |
| Duration | 4 hours |

**Pass criteria:**
- Slow agents stay in `GET_QUOTE` (not timing out)
- Normal agents unaffected
- Memory growth rate same as baseline

#### A-STR-05: Quote Interval Pressure

**Purpose:** Test with aggressive polling frequency.

| Parameter | Value |
|---|---|
| Agents | 200 simulators |
| `quote_interval` | 10 (instead of 180) |
| Duration | 4 hours |

**Pass criteria:** No OOMKill, all agents attested, CPU < 500m sustained.

#### A-STR-06: Agent Restart Storm

**Purpose:** Verify behavior when agents restart repeatedly (simulating unstable nodes).

| Parameter | Value |
|---|---|
| Agents | 200 simulators |
| Churn | Every 5 minutes: restart 20 random agent pods (rolling) |
| Duration | 2 hours |

**Expected behavior:**
- Restarting agents re-register with registrar (Rust agent re-registers on every startup)
- Verifier sees the agent go unreachable briefly, then resume
- If agent restarts within `max_retries` window, it may recover without entering `FAILED`
- If restart takes longer, agent enters `FAILED` and needs re-enrollment

**Pass criteria:**
- Agents that restart quickly (< 44s) recover automatically
- Verifier RSS stable (no accumulation from repeated registration cycles)
- Registrar SharedDataManager stable (per-agent locks cleaned up on re-registration)

#### A-STR-07: Registrar Burst with SharedDataManager Stress

**Purpose:** Stress the registrar's SharedDataManager IPC bottleneck.

| Parameter | Value |
|---|---|
| Agents | 200 simulators started within 30 seconds |
| Registrar | 1 pod, 1 worker |

**Pass criteria:** 100% registration success, p99 latency < 30s, SharedDataManager RSS < 200 MB.

### 3C. Soak Tests

#### A-SOA-01: 7-Day Soak at Target Scale

**Purpose:** Detect slow memory leaks and degradation.

| Parameter | Value |
|---|---|
| Agents | 200 simulators (100 real equivalent) |
| Duration | 7 days |

**Pass criteria:**
- RSS growth < 1 MB/hour
- Final RSS < 800 MB
- DB connections stable
- Zero `FAILED` agents due to `not_reachable`
- Attestation count per agent within ±5% of expected (3,360)
- No pod restarts

#### A-SOA-02: 72-Hour Soak with Agent Churn

**Purpose:** Detect leaks in registration/deregistration path.

| Parameter | Value |
|---|---|
| Steady-state | 160 simulators |
| Churn | Every 2 hours: delete 20, add 20 new |
| Duration | 72 hours |

**Pass criteria:** Same as A-SOA-01, plus SharedDataManager RSS stable across churn cycles.

#### A-SOA-03: Characterization — Untuned Config

**Purpose:** Quantify memory growth with default config. The "before" baseline.

| Parameter | Value |
|---|---|
| Agents | 50 simulators |
| Duration | 48 hours |
| Config | Untuned (no `PYTHON_CPU_COUNT`, `request_timeout=30`, `db_pool_sz_ovfl=20,30`, memory limit 8Gi) |

**Expected:** 32+ workers spawned, RSS growth to ~3-4 GB, up to 1,600 potential DB connections.

### 3D. Edge Cases — Single Instance

#### A-EC-01: Zero Agents — Idle Verifier

**Purpose:** Verify verifier behavior with no agents enrolled.

| Duration | 24 hours |
|---|---|

**Pass criteria:** RSS stable at baseline (~250 MB), no errors in logs, `/version` endpoint responsive, DB connections at pool minimum.

#### A-EC-02: Single Agent — Minimum Load

**Purpose:** Verify correct behavior at minimum scale.

| Agents | 1 simulator |
|---|---|
| Duration | 24 hours |

**Pass criteria:** Agent continuously attested, attestation count matches expected (480), no anomalies.

#### A-EC-03: Agent Enrolled But Never Reachable

**Purpose:** Verify behavior when an agent is enrolled in the verifier but the agent pod never starts.

| Setup | Enroll agent via tenant, but don't deploy the simulator pod |
|---|---|

**Expected:** Agent enters `GET_QUOTE_RETRY` → `FAILED` after ~44s. Verifier does not retry indefinitely. Memory released after `FAILED` transition.

**Pass criteria:** Agent reaches `FAILED` within 2 minutes, verifier RSS unchanged after transition.

#### A-EC-04: Database Full / Slow

**Purpose:** Verify behavior when PostgreSQL is slow (disk pressure) or connection pool exhausted.

| Failure injection | Introduce 2s latency on all DB queries (via `pg_sleep` or network shaping) |
|---|---|
| Duration | 30 minutes, then restore |

**Pass criteria:** Verifier degrades gracefully (slower attestation cycles, not crash). Agents may enter `GET_QUOTE_RETRY` but recover after DB normalizes.

#### A-EC-05: Verifier Process Killed (Not Pod)

**Purpose:** Verify behavior when the verifier Python process crashes but the pod container stays running (e.g., unhandled exception).

| Failure injection | `kill -9 <verifier_python_pid>` inside the container |
|---|---|

**Expected:** Container's liveness probe (`/version`) fails → K8s restarts the container (not the pod). All agents re-activated on startup.

**Pass criteria:** Container restart within `failureThreshold × periodSeconds` (30s with default probe). Agents resume attestation. No pod-level restart (container restart only).

#### A-EC-06: Clock Skew Between Verifier and Agents

**Purpose:** Verify `last_received_quote` staleness detection works correctly when clocks diverge.

| Setup | Set agent simulator clocks 5 minutes ahead of verifier |
|---|---|

**Pass criteria:** Staleness detection (OMC layer) correctly identifies the skew. Attestation itself should be unaffected (keylime uses relative timing for quote validation, not absolute).

---

## 4. Phase B — Multi-Instance Scale-Out

**Prerequisites:** Phase A validated (single instance supports target load). OMC hash ring for agent-to-verifier distribution implemented.

### 4B. Scale Tests

#### B-ST-01: Two Verifier Partitions — 200 Agents

**Purpose:** Validate agent distribution across 2 verifier instances.

| Parameter | Value |
|---|---|
| Agents | 400 simulators (200 real equivalent) |
| Verifiers | 2 pods (`uuid=v_01`, `uuid=v_02`), 100 agents each |
| Duration | 48 hours |

**Pass criteria:**
- Each verifier handles ~200 simulators
- Both verifiers RSS < 800 MB
- All agents attesting, zero `FAILED`
- Agent distribution is balanced (±10%)

#### B-ST-02: Partition Rebalancing — Add Verifier

**Purpose:** Verify agent migration when a 3rd verifier is added.

| Setup | 2 verifiers with 200 agents each |
|---|---|
| Action | Add 3rd verifier (`uuid=v_03`), trigger OMC rebalancing |

**Pass criteria:**
- Agents redistributed ~133 per verifier within 10 minutes
- No attestation gap > 2× `quote_interval` during migration
- No agents in `FAILED` during rebalancing

#### B-ST-03: Partition Drain — Remove Verifier

**Purpose:** Verify agent migration when a verifier is removed (scale-down).

| Setup | 3 verifiers with ~133 agents each |
|---|---|
| Action | Drain `v_03`, reassign its agents to `v_01` and `v_02` |

**Pass criteria:** All agents reassigned and attesting within 10 minutes. No `FAILED` agents.

### 4C. Edge Cases — Multi-Instance

#### B-EC-01: Uneven Agent Distribution

**Purpose:** Verify behavior when one verifier has significantly more agents than others.

| Setup | `v_01`: 350 simulators, `v_02`: 50 simulators |
|---|---|

**Pass criteria:** Both verifiers functional. `v_01` may show higher latency but no `FAILED` agents. OMC monitoring detects the imbalance.

#### B-EC-02: Agent Enrolled to Non-Existent Verifier

**Purpose:** Verify behavior when an agent's `verifier_id` doesn't match any running verifier.

| Setup | Enroll agent with `verifier_id=v_99` (no such verifier running) |
|---|---|

**Expected:** Agent sits in DB unpolled. OMC staleness detection flags it as `unknown`.

---

## 5. Phase C — HA & Redundancy

**Prerequisites:** Phase B validated (multi-instance works). K8s Lease wrapper (or equivalent failover mechanism) implemented.

### 5A. HA Tests

#### C-HA-01: Verifier Pod Crash — Automated Failover

**Purpose:** Measure attestation gap with standby takeover.

| Parameter | Value |
|---|---|
| Agents | 200 simulators on `v_01` |
| Active | 1 pod (`v_01`) |
| Standby | 1 pod (monitoring lease) |
| Failure | `kubectl delete pod <verifier> --grace-period=0` |

**Pass criteria:**
- Failover gap < 30 seconds
- All agents resume `GET_QUOTE` within 60 seconds
- Zero split-brain (DB: only one `verifier_id` active)

#### C-HA-02: Verifier Pod Crash — No Standby (K8s Restart)

**Purpose:** Measure gap when K8s restarts the pod (no standby).

| Failure | `kubectl delete pod <verifier> --grace-period=0` |
|---|---|

**Pass criteria:**
- Gap < 90 seconds
- Thundering herd on startup (200 agents polled at once) — no OOM or cascade

#### C-HA-03: Network Partition — Self-Fencing

**Purpose:** Verify active verifier stops when it can't renew lease.

| Failure | NetworkPolicy blocking verifier → K8s API server |
|---|---|

**Pass criteria:**
- Active self-fences within `RenewDeadline` (10s)
- Standby acquires lease after `LeaseDuration` (15s)
- No split-brain (no concurrent polling of same agents)

#### C-HA-04: Registrar Active-Active — Pod Failure

**Purpose:** Verify registrar survives a pod failure in active-active mode.

| Setup | 2 registrar pods behind K8s Service |
|---|---|
| Failure | Kill 1 pod, register 10 new agents during failure |

**Pass criteria:** All registrations succeed via surviving pod. Killed pod restarts and rejoins.

#### C-HA-05: Database Failure — Full Stack

**Purpose:** Verify behavior when PostgreSQL is unreachable.

| Failure | Kill PostgreSQL pod for 5 minutes, then restore |
|---|---|

**Pass criteria:**
- Verifier: agents → `FAILED` after retries. No crash.
- Registrar: registrations fail with 500. No crash. SharedDataManager alive.
- After restore: verifier resumes, agents recover. Registrar accepts registrations.

### 5B. Edge Cases — HA

#### C-EC-01: Standby Takes Over, Then Original Comes Back

**Purpose:** Verify no conflict when the original verifier pod recovers after failover.

| Scenario | `v_01` crashes → standby takes `v_01` lease → original pod restarts |
|---|---|

**Expected:** Original pod starts, sees lease held by standby, enters standby mode itself. No split-brain.

**Pass criteria:** Only one verifier polls `v_01` agents at any time. Original becomes the new standby.

#### C-EC-02: Rapid Sequential Failures

**Purpose:** Verify behavior when the standby also fails shortly after taking over.

| Scenario | Active crashes → standby takes over → standby crashes within 60 seconds |
|---|---|

**Expected:** Both pods restart via K8s. First to acquire lease becomes active. Attestation gap = 2× failover time.

**Pass criteria:** System recovers without manual intervention. All agents eventually resume attestation.

#### C-EC-03: Rolling Upgrade — Zero Attestation Gap

**Purpose:** Verify rolling upgrade of verifier pods doesn't cause attestation gaps.

| Setup | 2 active verifiers (`v_01`, `v_02`) + 1 standby |
|---|---|
| Action | Rolling upgrade via StatefulSet (`maxUnavailable=1`) |

**Pass criteria:**
- At most 1 partition's agents experience a gap at any time
- Gap per partition < 30 seconds
- All agents attesting throughout the upgrade

---

## 6. Automation Design

### 6.1. Test Framework

```
┌─────────────────────────────────────────────────────┐
│                  Test Orchestrator                    │
│              (Python + pytest + kubectl)              │
├──────────┬──────────┬───────────┬───────────────────┤
│ Agent    │ Failure  │ Metrics   │ Assertion          │
│ Manager  │ Injector │ Collector │ Engine             │
└────┬─────┴────┬─────┴─────┬─────┴────┬──────────────┘
     │          │           │          │
     ▼          ▼           ▼          ▼
  K8s API   K8s API    Verifier    Prometheus/
  (deploy   (delete    Registrar   JSON files
  agents)   pods,      APIs
            netpol)
```

### 6.2. Components

**Agent Manager** — Deploys/removes agent simulator pods.
```python
class AgentManager:
    def deploy(self, count, namespace, start_id, latency_ms=700, jitter_ms=50)
    def remove(self, count, namespace)
    def remove_by_id(self, agent_ids, namespace)
    def remove_all(self, namespace)
    def restart_random(self, count, namespace)
    def get_running_count(self, namespace) -> int
    def wait_for_ready(self, namespace, timeout=300)
```

**Failure Injector** — Injects failures via K8s API.
```python
class FailureInjector:
    def kill_pod(self, name, namespace, grace_period=0)
    def kill_process(self, pod, namespace, pid)
    def block_network(self, source_label, dest_label, namespace)
    def restore_network(self, policy_name, namespace)
    def kill_db(self, db_pod, namespace)
    def restore_db(self, db_pod, namespace)
    def inject_db_latency(self, db_pod, namespace, latency_ms)
```

**Metrics Collector** — Polls verifier/registrar APIs and K8s metrics.
```python
class MetricsCollector:
    def start(self, interval_seconds=30)
    def stop(self) -> MetricsReport
    def get_pod_memory(self, pod, namespace) -> int
    def get_process_tree(self, pod, namespace) -> List[ProcessInfo]
    def get_agent_states(self, verifier_url) -> Dict[str, int]
    def get_agent_staleness(self, verifier_url) -> Dict[str, float]
    def get_db_connections(self, db_pod, namespace) -> Dict[str, int]
    def get_attestation_counts(self, verifier_url) -> Dict[str, int]
```

**Assertion Engine** — Evaluates pass/fail criteria.
```python
class AssertionEngine:
    def assert_memory_below(self, max_mb, duration_hours)
    def assert_memory_growth_rate(self, max_mb_per_hour)
    def assert_all_agents_attesting(self, verifier_url)
    def assert_no_failed_agents(self, verifier_url)
    def assert_staleness_below(self, max_seconds, verifier_url)
    def assert_db_connections_below(self, max_count, db_pod, namespace)
    def assert_process_count(self, expected, pod, namespace)
    def assert_failover_gap(self, max_seconds, t_failure, t_recovery)
    def assert_no_split_brain(self, db_pod, namespace, verifier_id)
```

### 6.3. CI Integration

| Test | Phase | Frequency | Duration | Blocking? |
|---|---|---|---|---|
| A-ST-01 (50 agents) | A | Weekly | 48h | No |
| A-ST-02 (100 agents) | A | Weekly | 48h | No |
| A-ST-04 (registrar burst) | A | Nightly | 30 min | Yes |
| A-STR-01 (all agents killed) | A | Weekly | 1h | No |
| A-STR-02 (mass enrollment) | A | Weekly | 1h | No |
| A-SOA-01 (7-day soak) | A | Monthly | 7 days | No |
| B-ST-01 (2 partitions) | B | Weekly | 48h | No |
| C-HA-01 (failover) | C | Nightly | 30 min | Yes |
| C-HA-03 (self-fencing) | C | Nightly | 30 min | Yes |

---

## 7. Hardware Resource Estimates

### 7.1. Agent Simulator Pods

| Resource | Per Pod | 200 Pods | 400 Pods | 600 Pods |
|---|---|---|---|---|
| CPU request | 100m | 20 cores | 40 cores | 60 cores |
| CPU limit | 200m | 40 cores | 80 cores | 120 cores |
| Memory request | 128Mi | 25 GiB | 50 GiB | 75 GiB |
| Memory limit | 256Mi | 50 GiB | 100 GiB | 150 GiB |

### 7.2. Keylime Components

| Component | CPU Req/Limit | Memory Req/Limit | Instances |
|---|---|---|---|
| Verifier (active) | 200m / 500m | 512Mi / 1.5Gi | 1-3 |
| Verifier (standby) | 200m / 500m | 512Mi / 1.5Gi | 0-1 |
| Registrar | 200m / 500m | 256Mi / 512Mi | 2 |
| PostgreSQL (verifier) | 500m / 1000m | 512Mi / 1Gi | 1 |
| PostgreSQL (registrar) | 250m / 500m | 256Mi / 512Mi | 1 |

### 7.3. Cluster Sizing

| Tier | Phase | Tests | Nodes | Cores | RAM | Dedicated? |
|---|---|---|---|---|---|---|
| Tier 1 | A + C | Scale (100 agents), HA, stress, edge cases | 4 × 16c/32G | 64 | 128 GiB | No |
| Tier 2 | B | Multi-instance (200+ agents), partitioning | 4 × 16c/32G | 64 | 128 GiB | No |
| Tier 3 | A | Ceiling discovery (600), 7-day soak | 6 × 16c/64G | 96 | 384 GiB | **Yes** |

**Minimum viable:** Tier 1 (4 nodes) covers Phase A and C. Tier 2 reuses Tier 1 hardware for Phase B. Tier 3 needed only for ceiling discovery and long soak tests.

---

## 8. Execution Order

| Step | Tests | Duration | Prerequisites |
|---|---|---|---|
| 1 | A-ST-05 (ratio validation) | 96h | Tier 1, real agents available |
| 2 | A-SOA-03 (untuned characterization) | 48h | Tier 1 |
| 3 | A-ST-01 (50 agents), A-EC-01/02/03 (edge cases) | 48h + 24h | Ratio validated |
| 4 | A-ST-02 (100 agents), A-ST-04 (registrar burst) | 48h + 30m | Step 3 passed |
| 5 | A-STR-01 through A-STR-07 (stress + edge cases) | 24h | Step 4 passed |
| 6 | A-SOA-01 (7-day soak), A-SOA-02 (72h churn) | 10 days | Tier 3, step 4 passed |
| 7 | A-ST-03 (ceiling discovery) | 24-48h | Tier 3 |
| 8 | B-ST-01/02/03, B-EC-01/02 (multi-instance) | 48h + 4h | Phase A passed, hash ring ready |
| 9 | C-HA-01 through C-HA-05, C-EC-01/02/03 | 8h | Phase B passed, HA wrapper ready |

**Step 1 is critical.** If the simulator ratio is wrong, all agent counts in subsequent tests need recalibration.
