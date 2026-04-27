# RAS-HA.pdf — In-Depth Review and Validation

Review of the RAS (Keylime) High Availability design study targeting an OMC deployment on 4 servers. Validated against the keylime 7.14.1 codebase.

---

## Background: What Problem is This Document Solving?

Keylime has two critical control plane services:

- **Verifier** — continuously checks whether remote machines (agents) are trustworthy by pulling cryptographic quotes from them and validating the results. If the verifier goes down, no one is checking whether machines have been tampered with.
- **Registrar** — a database of all known agents and their TPM public keys. If the registrar goes down, no new agents can register, and the verifier can't look up agent keys.

Both are single-process services by default. If the process crashes or the server hosting it dies, attestation stops. The RAS-HA document proposes ways to make these services survive a single failure — this is called High Availability (HA).

---

## 1. Verifier ID Concept — Validated with Corrections

### What is a Verifier ID?

Think of it as a name tag. If you have 300 agents to attest and one verifier can only handle 100, you deploy 3 verifiers and give each a name: `v_01`, `v_02`, `v_03`. When you enroll an agent, you tell it "you belong to v_01." That verifier — and only that verifier — will poll that agent.

In the database, every agent row has a `verifier_id` column:

```
agent_id     | verifier_id | ip           | ...
-------------|-------------|--------------|----
agent-001    | v_01        | 10.0.1.10    |
agent-002    | v_01        | 10.0.1.11    |
agent-003    | v_02        | 10.0.1.12    |
```

When verifier `v_01` starts, it runs:

```sql
SELECT * FROM agents WHERE verifier_id = 'v_01'
```

It only gets agent-001 and agent-002. It never touches agent-003. This partitioning is what the document calls "sharding."

### What the code actually shows

- The config key is `uuid` under `[verifier]`, **not** `id` as the document states:
  ```python
  # cloud_verifier_tornado.py, line 578
  verifier_id = config.get("verifier", "uuid", fallback=cloud_verifier_common.DEFAULT_VERIFIER_ID)
  ```
- The default value is the string `"default"` (not auto-generated):
  ```python
  # cloud_verifier_common.py, line 21
  DEFAULT_VERIFIER_ID: str = "default"
  ```
- At startup, the verifier queries only its own agents:
  ```python
  # verifier_server.py, line 41-43
  verifier_id = config.get("verifier", "uuid", fallback=...)
  all_agents = cloud_verifier_tornado.get_agents_by_verifier_id(verifier_id)
  ```
- On agent enrollment (POST), the verifier stamps the agent with its own `verifier_id`
- On DELETE, the verifier rejects if the agent doesn't belong to it

### Document error

The config snippet shows `id = v_01` but it should be `uuid = v_01`. This will cause deployment failures if someone follows the document literally. The enrollment command uses `--verifier-id v_01` — this flag does exist in the tenant (`args.verifier_id`), so that part is correct.

### Shard key behavior — validated

The verifier only fetches and attests agents matching its `verifier_id`. This is the foundation the HA design builds on, and it is sound.

---

## 2. Verifier HA Models — Analysis

### The Core Idea

Since the verifier ID is just a config value and all agent state lives in a shared PostgreSQL database, **any** verifier process that starts with `uuid = v_01` will automatically pick up v_01's agents. There's no in-memory state to transfer. This makes failover simple: start a new process with the same ID, and it takes over.

### N+1 Model (3 active + 1 standby)

Deploy 4 pods across 4 servers. 3 are active (each with a unique verifier ID), 1 sits idle as a standby:

```
Server 1: pod-A  →  verifier uuid=v_01  (active, attesting agents 1-100)
Server 2: pod-B  →  verifier uuid=v_02  (active, attesting agents 101-200)
Server 3: pod-C  →  verifier uuid=v_03  (active, attesting agents 201-300)
Server 4: pod-D  →  (idle, waiting for a failure)
```

If pod-A dies, pod-D takes over v_01's identity and starts attesting agents 1-100.

**Critical gap the document does not address:** When the standby takes over, it calls `get_agents_by_verifier_id()` which loads all 100 agents and starts polling them simultaneously. This is the **thundering herd problem** — 100 concurrent HTTP requests fired at once, potentially overwhelming both the network and the agents. The document does not mention startup staggering (e.g., activating 10 agents per second instead of all at once).

### 1:1 Model

A special case of N+1 where N=1. One active verifier, one standby. Simplest deployment, but all agents are on a single verifier — no load distribution.

### 1:2 Model (1 active + 2 standby)

The document correctly identifies this wastes resources (2 idle servers) compared to N+1 for the same failure coverage. However, it notes a valid benefit: with 3 pods participating in leader election, you get a proper quorum (majority vote), which makes the election more robust.

---

## 3. Kubernetes Leases — How They Work (Prerequisite for Understanding the Wrapper)

Before diving into the wrapper solution, you need to understand Kubernetes Leases, since the entire HA mechanism depends on them.

### What is a Lease?

A Lease is a small object stored in etcd (Kubernetes' internal database). Think of it as a sticky note:

> "I, pod-A, am the owner of verifier v_01. I last confirmed this at 12:25:00. This claim expires after 15 seconds."

In Kubernetes API terms:

```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: verifier-v01          # The "thing" being claimed
  namespace: keylime
spec:
  holderIdentity: pod-A        # Who holds it
  leaseDurationSeconds: 15     # How long the claim is valid
  renewTime: "12:25:00"        # Last time the holder said "I'm still here"
```

There is no magic enforcement — Kubernetes does not kill a pod that loses its lease. The **pods themselves** must implement the logic: "check the lease, decide if it's expired, try to take it."

### The Three Timers

These control the speed and safety of failover:

| Timer | Default | What it means |
|---|---|---|
| LeaseDuration | 15s | If nobody renews the lease for this long, it's considered expired and anyone can take it |
| RenewDeadline | 10s | The current holder gives up leadership if it can't renew within this time |
| RetryPeriod | 2s | How often every pod checks/renews the lease |

Think of it like a dead man's switch: the leader must keep pressing a button (renewing) every 2 seconds. If the button isn't pressed for 15 seconds, someone else can take over.

### Normal Operation — Step by Step

All 4 pods start simultaneously:

```
Time 0s:
  pod-A: "Let me try to acquire lease 'verifier-v01'..."
         → Writes to etcd: holderIdentity=pod-A, renewTime=now
         → SUCCESS! "I own v_01. Starting verifier with uuid=v_01"

  pod-B: "verifier-v01 is taken. Try verifier-v02..."
         → SUCCESS! "I own v_02."

  pod-C: → Gets v_03.

  pod-D: "All 3 leases are taken. I'll wait and watch."
```

Now pod-A must keep renewing to prove it's alive:

```
Time 0s:   pod-A writes renewTime = 12:25:00
Time 2s:   pod-A writes renewTime = 12:25:02   ← renew
Time 4s:   pod-A writes renewTime = 12:25:04   ← renew
Time 6s:   pod-A writes renewTime = 12:25:06   ← renew
...keeps going every 2 seconds...
```

Meanwhile, pod-D checks every 2 seconds:

```
Time 2s:   pod-D reads lease v_01: renewTime was 0s ago. Still valid. Do nothing.
Time 4s:   pod-D reads lease v_01: renewTime was 0s ago. Still valid. Do nothing.
...nothing to do, keep waiting...
```

---

## 4. Kubernetes Wrapper (Option 1: Leases) — Mostly Sound, Some Issues

The design uses the Lease mechanism described above. Each of the 4 pods runs a Go wrapper that manages the verifier lifecycle.

### How the wrapper works

1. On startup, try to acquire one of 3 leases (one per verifier ID)
2. If acquired: write the verifier ID into `verifier.conf`, start the verifier process
3. If not acquired: monitor all leases for expiry
4. On lease expiry: acquire the expired lease, take over that verifier ID
5. Continuously renew the held lease every `RetryPeriod`
6. If the verifier child process dies: stop renewing the lease (so the standby can take over)

### Timer configuration — correctly identified as critical

The document lists the three timers and warns about flapping from misconfiguration. This is accurate. If LeaseDuration is too short, transient API server slowness causes false failovers.

### Issue 1: Graceful Shutdown Gap

**The problem:** Even when a failure is detected instantly, the standby can't take over immediately because it doesn't know the lease has expired until `LeaseDuration` passes.

**Step-by-step walkthrough:**

```
Time 12:25:06  pod-A's verifier crashes.
               pod-A's wrapper detects child process died.
               pod-A STOPS renewing the lease.
               Last renewTime in etcd = 12:25:06.

Time 12:25:08  pod-D checks: renewTime was 2s ago. LeaseDuration=15s.
               2s < 15s → "Still valid." Does nothing.

Time 12:25:10  pod-D checks: 4s ago. Still valid.
Time 12:25:12  pod-D checks: 6s ago. Still valid.
Time 12:25:14  pod-D checks: 8s ago. Still valid.
Time 12:25:16  pod-D checks: 10s ago. Still valid.
Time 12:25:18  pod-D checks: 12s ago. Still valid.
Time 12:25:20  pod-D checks: 14s ago. Still valid.

Time 12:25:22  pod-D checks: 16s ago. 16 > 15 → "EXPIRED!"
               pod-D acquires the lease.
               pod-D writes verifier.conf with uuid=v_01.
               pod-D starts verifier process.

Time ~12:25:25 Verifier fully started, first attestation poll begins.
```

**The gap:**

```
12:25:06  ←  pod-A died
              |
              |  ~19 seconds: NO attestation for v_01's agents
              |
12:25:25  ←  pod-D's verifier starts polling
```

**Failover time = LeaseDuration + RetryPeriod + verifier startup time ≈ 20-30 seconds.**

The document mentions lease expiry but does not quantify this gap. Operators need to know this to set SLA expectations.

**Why not make LeaseDuration shorter?** If you set it to 3 seconds, a single missed renewal (due to a K8s API server GC pause or network blip) would cause a false failover — the standby takes over even though the active is fine. The active recovers, sees someone else holds the lease, stops its verifier. You just caused an unnecessary disruption. LeaseDuration must be long enough to tolerate transient slowness.

### Issue 2: Split-Brain During Network Partition

**What is a network partition?** A situation where different parts of the system can't talk to each other, but each part is individually still working.

**The scenario:**

```
┌──────────────────────────────────────────────────────┐
│                                                       │
│  pod-A (active v_01)          K8s API Server (etcd)  │
│  ┌─────────────┐              ┌──────────────────┐   │
│  │ Can reach    │   ╳ BROKEN  │ Stores lease      │   │
│  │ agents       │──────╳──────│ objects            │   │
│  │ Can NOT reach│              │                    │   │
│  │ API server   │              └────────┬───────────┘   │
│  └──────┬──────┘                        │              │
│         │                               │              │
│         │              pod-D (standby)   │              │
│         │              ┌─────────────┐  │              │
│         │              │ CAN reach    │──┘              │
│         │              │ API server   │                 │
│         │              └─────────────┘                 │
│         │                                              │
│    agents (100 machines)                               │
│                                                        │
└────────────────────────────────────────────────────────┘
```

pod-A loses connectivity to the K8s API server but can still reach the agents it's attesting.

**What happens without self-fencing:**

```
Time 12:25:06  Network partition begins.
               pod-A tries to renew lease → FAILS (can't reach API server)
               pod-A's verifier is still running, still attesting agents.

Time 12:25:08  pod-A tries to renew → FAILS again.
               But the verifier process is fine! Agents are responding!

Time 12:25:16  pod-A has failed to renew for 10s (= RenewDeadline).
               If the wrapper does NOT implement self-fencing:
               → verifier keeps running.

Time 12:25:22  pod-D sees lease expired (16s since last renewTime).
               pod-D acquires lease, starts its own verifier with uuid=v_01.

Time 12:25:25  TWO VERIFIERS ARE NOW ATTESTING THE SAME 100 AGENTS:
               - pod-A (old leader, can't reach API server, CAN reach agents)
               - pod-D (new leader, legitimately acquired the lease)
```

This is **split-brain**: two leaders for the same shard, both actively working.

**Why is split-brain bad for keylime?**

1. **Double polling:** Both verifiers send quote requests to the same agents every `quote_interval`. Doubles network and CPU load on agents.
2. **Conflicting state updates:** Both write to the same DB rows. pod-A marks agent-42 as `GET_QUOTE_RETRY` (slow response). A millisecond later, pod-D marks it as `GET_QUOTE` (got a fresh response). The DB state becomes a mess.
3. **Conflicting failure decisions:** pod-A decides agent-42 failed attestation → sets it to `FAILED`. pod-D got a valid quote → sets it back to `GET_QUOTE`. The agent flaps between failed and active.

**The fix — self-fencing:**

The wrapper **must** implement this rule:

> "If I cannot renew my lease within RenewDeadline (10s), I MUST kill my verifier process immediately, even if it's working fine."

```
Time 12:25:06  Network partition begins.
               pod-A tries to renew → FAILS.

Time 12:25:16  pod-A has failed for 10s (= RenewDeadline).
               pod-A's wrapper: "I can't prove I'm the leader anymore."
               pod-A's wrapper: KILLS the verifier process.  ← SELF-FENCING
               pod-A goes back to standby mode.

Time 12:25:22  pod-D acquires lease, starts verifier.
               Only ONE verifier for v_01 now. No split-brain.
```

The cost: between 12:25:16 (pod-A self-fences) and 12:25:22 (pod-D takes over), nobody is attesting v_01's agents. That's a ~6 second gap. But that's far better than split-brain.

**Why the RAS-HA document's claim is incomplete:** The document says "Verifier ID helps avoid split brain scenario." This is true during normal operation — two verifiers with different IDs (`v_01` and `v_02`) will never attest each other's agents. But during a failover with network partition, two verifiers can end up with the **same** ID (`v_01`). The Verifier ID concept doesn't protect against this — only self-fencing does.

### Issue 3: Config File Race Condition

The wrapper "dynamically inserts the verifier ID into verifier.conf" then starts the verifier. If the wrapper crashes between writing the config and starting the process, the config file is left in a modified state. On restart, the wrapper might try to acquire a different lease but the config still has the old verifier ID.

The wrapper should set the verifier ID via environment variable (`keylime_VERIFIER_CONFIG`) or command-line override rather than mutating the config file.

### Summary: Failover Timeline

```
NORMAL:     pod-A renews lease every 2s, attests agents, everything fine
                │
FAILURE:    pod-A's verifier crashes (or network partition begins)
                │
                ├── pod-A stops renewing (crash) or can't renew (partition)
                │
GAP:        0s ─────────────── 15s (LeaseDuration) ──────────────────
                │                                                     │
                │  No one is attesting v_01's agents                  │
                │  (unless pod-A is still running = split-brain risk) │
                │                                                     │
SELF-FENCE: │  At 10s (RenewDeadline), pod-A MUST kill its verifier  │
                │                                                     │
TAKEOVER:   │                                              pod-D acquires lease
                │                                              pod-D starts verifier
                │                                              pod-D begins attesting
                │                                                     │
RECOVERED:  ──────────────── ~20-30s total ───────────────────────────
```

Two key takeaways:
1. **Graceful shutdown gap** is unavoidable — it's the price of distributed coordination. You tune it by adjusting LeaseDuration (shorter = faster failover but more false failovers).
2. **Split-brain** is avoidable but only if the wrapper implements self-fencing. The lease mechanism alone doesn't prevent it — it's just a shared record, not an enforcer.

---

## 5. Kubernetes Wrapper (Option 2: PostgreSQL Locks) — Valid but Unnecessary Complexity

Instead of Kubernetes Leases, this option uses a custom database table for locking:

```
ID | verifier_id | holder_pod | last_renewed | failure_count
---|-------------|------------|--------------|---------------
1  | v_01        | pod-A      | 12:25:06     | 0
2  | v_02        | pod-B      | 12:25:07     | 0
3  | v_03        | pod-C      | 12:25:06     | 0
```

The wrapper periodically updates `last_renewed`. If it expires, another pod takes over — same concept as Leases, but using PostgreSQL instead of etcd.

The document correctly identifies the cons:
- Must manage the table lifecycle, connection handling, and key infrastructure yourself
- Database traffic from standby pod
- All the same split-brain and gap issues apply — the locking mechanism doesn't change the fundamental distributed coordination problem

Since K8s Leases are a native primitive and the deployment is already on K8s, Option 1 is clearly better. The document's assessment is accurate here.

---

## 6. Option 3: Manual Switchover — Correctly Scoped

For environments where automated failover is not desired (e.g., strict change control), manual switchover is a valid option. The wrapper still monitors leases and raises alarms, but a human triggers the actual failover by running a script.

This trades recovery speed for control — the failover gap is however long it takes a human to respond to the alarm.

---

## 7. Kubernetes Operator — Correctly Described but Over-Engineered for the Scale

### What is an Operator?

A Kubernetes Operator is a custom program that watches for a configuration object (called a CRD — Custom Resource Definition) and automatically manages the application to match that configuration. Instead of manually managing 4 pods and 3 leases, you declare what you want:

```yaml
apiVersion: keylime.example.com/v1
kind: KeylimeVerifierCluster
metadata:
  name: production-attestation
spec:
  totalAgents: 300
  agentsPerShard: 100
  standbyReplicas: 1
```

The operator reads this and automatically:
- Creates 3 verifier pods (300 agents ÷ 100 per shard)
- Creates 1 standby pod
- Handles failover, shard assignment, and monitoring

### Assessment

This is architecturally clean but significant development effort for the current scale (3 shards + 1 standby). The document does not explicitly recommend one approach over the other, which is a gap.

**Recommendation:** The wrapper (Option 1 with Leases) is the right choice for the stated scale (80-200 agents across 3-4 servers). An operator makes sense if the deployment grows to dozens of verifier shards across multiple clusters.

---

## 8. Registrar HA — Active-Active Claim Needs Qualification

### What the document proposes

> "Registrar can run in active-active HA model, which will be front ended by load balancer."

Unlike the verifier (where only one instance should handle a given agent), the registrar can have multiple instances running simultaneously. A load balancer distributes requests across them. This is simpler than the verifier's active-standby model.

```
                    ┌──────────────┐
                    │ Load Balancer│
                    └──────┬───────┘
                     ┌─────┴─────┐
              ┌──────┴──┐   ┌────┴─────┐
              │Registrar│   │Registrar │
              │  Pod 1  │   │  Pod 2   │
              └────┬────┘   └────┬─────┘
                   └──────┬──────┘
                   ┌──────┴──────┐
                   │ PostgreSQL  │
                   │ (shared DB) │
                   └─────────────┘
```

### This is partially correct — with a caveat

The registrar uses `SharedDataManager` (Python `multiprocessing.Manager`) for cross-process locking during agent registration. This is an **in-process** mechanism — it only synchronizes workers within a single registrar pod. If you run two registrar pods behind a load balancer, each has its own independent `SharedDataManager`. The per-agent registration locks do not span across pods.

### Why it works in practice despite this

The registration race condition the locks protect against (two concurrent POSTs for the same `agent_id`) is unlikely to hit across pods because:

1. A given agent only registers once (at boot) — it's not a high-frequency operation
2. The DB has a unique constraint on `agent_id` — if two pods try to insert the same agent simultaneously, one will get a database error (`IntegrityError`), which the code catches and returns as a 403 response

So active-active registrar works in practice, but the document should note that the SharedDataManager locks are pod-local and the **database unique constraint** is the actual cross-pod safety mechanism.

### Certificate requirement — correct

The document correctly notes "all certificates should have same CA." This is required because the verifier and tenant validate the registrar's TLS certificate. If different registrar instances have certs from different CAs, clients would need to trust multiple CAs, which complicates deployment.

---

## 9. Scale Numbers — Cannot Validate, but Context is Important

The document claims:
- Single registrar: up to 600 mock agent onboardings
- Single verifier: up to 600 mock agent attestations
- Target: 80 real agents in OMC 2.12, 160 in OMC 2.13

These numbers are plausible given the findings in `Verifier_Memory_Bloat_Analysis.md` (no concurrency limit, 60s default timeout, per-agent memory of 15KB-15MB). The document does not explain the mock-to-real agent ratio, which is a gap — a real agent with IMA policies generates much larger quote responses (potentially megabytes) than a mock agent.

---

## 10. Summary of Issues Found

| # | Issue | Severity | Section |
|---|---|---|---|
| 1 | Config key is `uuid`, not `id` | Medium (will cause deployment failures) | Verifier Configuration |
| 2 | Thundering herd on failover not addressed | High (standby takeover causes burst of concurrent requests) | HA Models |
| 3 | Split-brain during network partition not addressed | High (two verifiers attesting same agents simultaneously) | Kubernetes Wrapper |
| 4 | Config file mutation race condition | Medium (wrapper crash leaves stale config) | Kubernetes Wrapper |
| 5 | SharedDataManager is pod-local — not mentioned for active-active registrar | Medium (misleading completeness) | Registrar |
| 6 | No explicit recommendation between Wrapper vs Operator | Low (reader left to decide) | Solution options |
| 7 | Failover time not quantified | Medium (operators need SLA expectations) | HA Models |
| 8 | Push model HA explicitly out of scope but no forward reference to what changes | Low | Out of Scope |

---

## 11. Recommendations

| Priority | Action |
|---|---|
| P0 | Fix config key from `id` to `uuid` in the Verifier Configuration section |
| P0 | Add startup staggering requirement for standby takeover (mitigate thundering herd) |
| P0 | Require wrapper to implement self-fencing: stop verifier process when lease renewal fails within `RenewDeadline` |
| P1 | Quantify failover time SLA: `LeaseDuration + RetryPeriod + startup time` (~20-30s) |
| P1 | Document that registrar active-active relies on DB unique constraint as cross-pod safety, not SharedDataManager |
| P1 | Use environment variable or command-line override for verifier ID instead of config file mutation |
| P2 | Add explicit recommendation: Wrapper (Option 1) for current scale, Operator for future multi-cluster growth |
| P2 | Document mock-to-real agent ratio and its impact on scale numbers |

---

## Glossary

| Term | Meaning |
|---|---|
| Active-Active | Both instances handle requests simultaneously (used for registrar) |
| Active-Standby | One instance handles requests, the other waits to take over on failure (used for verifier) |
| CRD | Custom Resource Definition — a way to extend Kubernetes with your own configuration objects |
| etcd | The distributed key-value store that Kubernetes uses internally to store all cluster state |
| Failover | The process of a standby taking over when the active instance fails |
| Flapping | Rapid, repeated failovers caused by misconfigured timers — active and standby keep swapping roles |
| HA | High Availability — the ability to continue operating when a component fails |
| Lease | A Kubernetes object used for leader election — a record in etcd that says "this pod owns this resource" |
| Leader Election | The process by which multiple pods decide which one is the active leader for a given role |
| N+1 | A redundancy model with N active instances and 1 shared standby |
| Network Partition | A failure where parts of the system can't communicate with each other but are individually still working |
| OMC | Operations Management Controller — the orchestration layer managing keylime components |
| Operator | A Kubernetes pattern where a custom controller automatically manages an application based on a CRD |
| Quorum | A majority of participants agreeing — needed for reliable leader election (e.g., 2 out of 3) |
| RBAC | Role-Based Access Control — Kubernetes permission system controlling who can do what |
| Self-Fencing | When a leader voluntarily stops itself because it can't prove it's still the legitimate leader |
| Shard | A partition of work — each verifier ID represents a shard of agents |
| Split-Brain | A dangerous state where two instances both believe they are the active leader for the same shard |
| Thundering Herd | A burst of simultaneous requests caused by many operations starting at the same time |
