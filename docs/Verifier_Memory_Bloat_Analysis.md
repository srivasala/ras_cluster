# Keylime Verifier & Registrar — Scalability and HA Risk Analysis

## 1. Problem Statement

In pull mode, the Keylime verifier can experience unbounded memory growth when managing large numbers of agents or when agents respond slowly to quote requests. Beyond memory, there are additional architectural factors in both the verifier and registrar that impact scalability and high availability. The verifier has no concurrency control, no per-agent latency tracking, and no backpressure mechanism to protect itself from slow or unresponsive agents.

## 2. Root Cause Analysis

### 2.1. Polling Architecture

The verifier uses Tornado's async IOLoop to poll agents. For each agent, the cycle is:

```
process_agent()
  → invoke_get_quote()          # async HTTP GET to agent
    → await tornado HTTP response  # BLOCKS coroutine until response or timeout
  → process_quote_response()    # validate quote
  → schedule next poll via call_later(quote_interval)
```

**Source:** `keylime/cloud_verifier_tornado.py`, lines 2298–2541

### 2.2. What Each Agent Holds in Memory

Every active agent consumes the following resources simultaneously during a poll cycle:

| Resource | Size | Lifetime | Source |
|---|---|---|---|
| Agent dict (`agent_data`) | ~2–5 KB | Entire polling lifecycle | `_from_db_obj()` at line 175 |
| Ephemeral fields (`exclude_db`) | ~1 KB | Entire polling lifecycle | Lines 157–172 |
| Tornado coroutine | ~1–2 KB | Until agent responds or timeout | `invoke_get_quote()` at line 2031 |
| HTTP connection (TCP socket + TLS state) | ~10–50 KB | Until agent responds or timeout | `tornado_requests.request()` |
| IMA runtime policy (loaded per cycle) | 1 KB – 10 MB | Duration of `process_agent()` | `verifier_read_policy_from_cache()` at line 218 |
| MB policy | 1 KB – 1 MB | Duration of `process_agent()` | Loaded via SQLAlchemy joinedload |
| Quote response body | 1 KB – 5 MB | Duration of quote processing | IMA measurement list in response |

**Per-agent memory during active poll: ~15 KB (minimal) to ~15 MB (with large IMA policy + measurement list)**

### 2.3. No Concurrency Limit

All agents are polled concurrently via `asyncio.ensure_future()`:

```python
# cloud_verifier_tornado.py, line 2453
asyncio.ensure_future(process_agent(agent, states.GET_QUOTE))
```

There is no semaphore, no pool, no queue. If the verifier manages 5,000 agents, it creates 5,000 concurrent coroutines, each holding an HTTP connection.

### 2.4. Default Timeout is 60 Seconds

```python
# keylime/config.py, line 544
DEFAULT_TIMEOUT = 60.0
```

A slow agent holds its coroutine + HTTP connection + TLS state for up to 60 seconds. During this time, the memory is not reclaimable.

**Worst case:** 5,000 agents all responding at 60s timeout = 5,000 concurrent coroutines × ~50 KB each (connection overhead) = **~250 MB just in connection state**, before counting policies and quote payloads.

### 2.5. Retry Loop Keeps Agent Dict Alive

When an agent is unreachable, the verifier enters a retry loop:

```python
# cloud_verifier_tornado.py, lines 2470–2495
agent["num_retries"] += 1
next_retry = retry.retry_time(exponential_backoff, interval, agent["num_retries"], logger)
tornado.ioloop.IOLoop.current().call_later(
    next_retry,
    invoke_get_quote,
    agent,       # ← agent dict stays in memory, referenced by the IOLoop callback
    mb_policy,
    runtime_policy,
    True,
    timeout=timeout,
)
```

The `call_later` callback holds a reference to the `agent` dict, `mb_policy`, and `runtime_policy`. These objects cannot be garbage collected until the callback fires or is cancelled. With exponential backoff and `max_retries` (default 5), an unreachable agent can hold memory for up to ~362 seconds with default settings — see section 2.6 for the full quantified analysis of the retry parameter interaction.

Note: `call_later` is also used on the **successful** attestation path — after each successful quote validation, the next poll is scheduled via `call_later(quote_interval, invoke_get_quote, agent, mb_policy, runtime_policy, ...)`. This holds the same objects for `quote_interval` seconds (the time between polls), not `request_timeout` seconds (the HTTP wait time). The `request_timeout` controls how long the HTTP request waits for a response; the `quote_interval` controls how long the callback holds objects between polls.

### 2.6. Uncapped Retry Hold Time from `max_retries`, `retry_interval`, and `exponential_backoff`

**Source:** `cloud_verifier_tornado.py`, lines 2467–2469; `keylime/common/retry.py`, lines 5–12; `keylime/config.py`, line 545

The retry loop in section 2.5 is governed by three interacting config parameters:

- `max_retries` — number of retry attempts before transitioning to FAILED (default: `DEFAULT_MAX_RETRIES = 5` in `config.py`)
- `retry_interval` — base delay in seconds between retries (fallback: `2.0` in `attestation_controller.py`)
- `exponential_backoff` — if `True`, delay = `retry_interval ^ retry_number` (fallback: `True`)

The `retry_time()` function (`keylime/common/retry.py`) computes the delay:

```python
def retry_time(exponential: bool, base: float, ntries: int, logger: Optional[Logger]) -> float:
    if exponential:
        if base > 1:
            return base**ntries    # ← no upper bound / max_delay clamp
    return abs(base)
```

#### 2.6.1. Default Behavior: Memory Hold Time Per Unreachable Agent

With defaults (`exponential_backoff = True`, `retry_interval = 2.0`, `max_retries = 5`):

| Retry # | Backoff Delay (`2^n`) | HTTP Wait (`request_timeout`) | Cumulative Hold Time (timeout=60s) | Cumulative Hold Time (timeout=10s) |
|---|---|---|---|---|
| 1 | 2s | 60s | 62s | 12s |
| 2 | 4s | 60s | 126s | 26s |
| 3 | 8s | 60s | 194s | 44s |
| 4 | 16s | 60s | 270s | 70s |
| 5 | 32s | 60s | 362s | 112s |

**Formula:** `total_hold = sum(interval^i + request_timeout, for i=1..max_retries)`

With defaults, an unreachable agent holds its `agent` dict, `mb_policy`, and `runtime_policy` in memory for **~362 seconds (~6 minutes)** before transitioning to FAILED. Each retry fires a new `invoke_get_quote` that opens an HTTP connection held for up to `request_timeout`, so up to `max_retries` connections can overlap with pending `call_later` callbacks.

#### 2.6.2. Misconfiguration Risk: No Delay Cap

The exponential backoff has **no `max_delay` clamp**. If `retry_interval` is set to a value larger than 2, delays grow explosively:

| `retry_interval` | Retry 1 | Retry 2 | Retry 3 | Retry 4 | Retry 5 | Total Backoff |
|---|---|---|---|---|---|---|
| 2 | 2s | 4s | 8s | 16s | 32s | 62s |
| 5 | 5s | 25s | 125s | 625s | 3125s | ~65 min |
| 10 | 10s | 100s | 1000s | 10000s | 100000s | ~31 hours |

With `retry_interval = 10` and `max_retries = 5`, a single unreachable agent holds memory for **~31 hours**. The `call_later` callbacks keep the agent dict + policies pinned in memory for the entire duration. There is no validation in the codebase that warns about or caps this interaction.

#### 2.6.3. Fleet-Wide Impact: Network Partition Scenario

When multiple agents become unreachable simultaneously (network partition, agent fleet restart, firewall change), the retry memory cost multiplies:

| Unreachable Agents | Per-Agent Hold (defaults, timeout=60) | Total Memory Pinned (no IMA) | Total Memory Pinned (1MB IMA policy) |
|---|---|---|---|
| 10 | 362s | ~500 KB for 6 min | ~10 MB for 6 min |
| 100 | 362s | ~5 MB for 6 min | ~100 MB for 6 min |
| 500 | 362s | ~25 MB for 6 min | ~500 MB for 6 min |
| 1,000 | 362s | ~50 MB for 6 min | ~1 GB for 6 min |

This is distinct from the "slow agent" problem (section 2.4): slow agents hold one connection at a time, while unreachable agents accumulate up to `max_retries` overlapping `call_later` callbacks, each referencing the full set of objects.

#### 2.6.4. Revocation Notifier Uses the Same Parameters

The `RevocationNotifier` (`keylime/revocation_notifier.py`, lines 37–39) reads the same `verifier.max_retries`, `verifier.retry_interval`, and `verifier.exponential_backoff` config values for webhook delivery retries. A misconfigured `retry_interval` affects both the polling retry loop and revocation notification delivery, compounding the impact.

### 2.7. No Per-Agent Latency Tracking

The verifier records:
- `last_received_quote` — unix timestamp of when a quote was received
- `last_successful_attestation` — unix timestamp of last passing attestation

It does **not** record:
- How long the agent took to respond
- Whether the response was near the timeout threshold
- Historical latency trends

**Source:** `process_get_status()` in `keylime/cloud_verifier_common.py`, lines 264–354 — no latency field in the response.

This means there is no way to identify slow agents from the verifier API. An agent consistently responding at 55s (just under the 60s timeout) is indistinguishable from one responding at 50ms.

## 3. Impact Assessment

| Agent Count | Concurrent Coroutines | Memory (connections only) | Memory (with 1 MB IMA policy each) |
|---|---|---|---|
| 100 | 100 | ~5 MB | ~105 MB |
| 1,000 | 1,000 | ~50 MB | ~1.05 GB |
| 5,000 | 5,000 | ~250 MB | ~5.25 GB |
| 10,000 | 10,000 | ~500 MB | ~10.5 GB |

These are worst-case estimates assuming all agents are being polled simultaneously and all have loaded IMA policies. In practice, `quote_interval` staggers the polls, but a burst of slow agents can still cause concurrent spikes.

## 4. Mitigation Strategies

### 4.1. Immediate — Configuration Changes (No Code Modification)

#### 4.1.1. Reduce Request Timeout

**Change:** Set `request_timeout = 10` in verifier config (down from 60s default).

**Rationale:** A healthy agent in pull mode should respond to a quote request in < 5s. A 10s timeout is generous. This reduces the maximum time a coroutine + connection is held by 6x.

**Risk:** Agents on slow networks or under heavy load may timeout more frequently, causing `GET_QUOTE_RETRY` states. Monitor `attestation_count` and retry rates after change.

```ini
# /etc/keylime/verifier.conf
[verifier]
request_timeout = 10
```

#### 4.1.2. Reduce Max Retries

**Change:** Lower `max_retries` from default 5 to 3.

**Rationale:** Each retry keeps the agent dict + policy in memory via `call_later` callback. With defaults (`max_retries=5`, `retry_interval=2`, `exponential_backoff=True`, `request_timeout=60`), an unreachable agent holds memory for ~362s. Reducing to 3 retries cuts this to ~194s (see section 2.6.1 for the full breakdown). Combined with `request_timeout=10`, the hold time drops to ~44s.

```ini
[verifier]
max_retries = 3
```

#### 4.1.4. Validate `retry_interval` Value

**Change:** Ensure `retry_interval` is not set above 2 when `exponential_backoff = True`.

**Rationale:** The exponential backoff has no `max_delay` clamp (see section 2.6.2). With `retry_interval = 10` and `max_retries = 5`, a single unreachable agent holds memory for ~31 hours. The safe range for `retry_interval` with exponential backoff is 1.5–2.0.

```ini
[verifier]
retry_interval = 2
exponential_backoff = true
```

#### 4.1.3. Increase Quote Interval

**Change:** Increase `quote_interval` to spread out polling.

**Rationale:** A shorter interval means more overlapping polls. If `quote_interval = 2s` and timeout = 60s, up to 30 polls can overlap per agent. With `quote_interval = 10s` and timeout = 10s, at most 1 poll overlaps.

```ini
[verifier]
quote_interval = 10
```

### 4.2. OMC Layer — Agent Distribution

#### 4.2.1. Cap Agents Per Verifier

Use the OMC consistent hash ring to enforce a maximum agent count per verifier pod.

```python
MAX_AGENTS_PER_VERIFIER = 500  # tune based on pod memory limits

def attest_agent(agent_uuid: str) -> str:
    verifier_id, endpoint = hash_ring.get_verifier(agent_uuid)

    # Check current load
    agent_count = get_agent_count_for_verifier(verifier_id)
    if agent_count >= MAX_AGENTS_PER_VERIFIER:
        # Find next verifier in ring with capacity
        verifier_id, endpoint = hash_ring.get_next_available(agent_uuid, MAX_AGENTS_PER_VERIFIER)

    # Proceed with enrollment
    ...
```

#### 4.2.2. Detect Slow Agents Indirectly

Since the verifier doesn't expose per-agent latency, OMC can infer it:

```python
def detect_slow_agents(agents: list[dict], quote_interval: float, timeout: float) -> list[str]:
    """Identify agents whose last_received_quote is significantly older than expected."""
    expected_max_gap = quote_interval + timeout + 5  # 5s buffer
    now = time.time()
    slow_agents = []

    for agent in agents:
        last_quote = agent.get("last_received_quote", 0)
        if last_quote and (now - last_quote) > 3 * expected_max_gap:
            slow_agents.append(agent["agent_id"])

    return slow_agents
```

OMC can then:
- Alert operators about slow agents
- Optionally stop attestation for chronically slow agents to protect verifier resources
- Redistribute agents away from overloaded verifiers

### 4.3. Keylime Code Changes (Upstream Contribution)

#### 4.3.1. Add Concurrency Semaphore

**This is the single most effective fix.** Bounds the number of concurrent agent polls regardless of total agent count.

```python
# cloud_verifier_tornado.py — add at module level
import asyncio

# Maximum concurrent quote requests per verifier process
MAX_CONCURRENT_POLLS = int(config.get("verifier", "max_concurrent_polls", fallback="500"))
QUOTE_SEMAPHORE = asyncio.Semaphore(MAX_CONCURRENT_POLLS)

async def invoke_get_quote(agent, mb_policy, runtime_policy, need_pubkey, timeout=DEFAULT_TIMEOUT):
    async with QUOTE_SEMAPHORE:
        # ... existing invoke_get_quote code unchanged ...
```

**Impact:** With `MAX_CONCURRENT_POLLS = 500` and timeout = 10s:
- Max concurrent memory: 500 × ~50 KB = ~25 MB (connections only)
- Agents beyond the limit queue up and are polled as slots free
- No agent is starved — the semaphore is fair (FIFO)

**Config:**
```ini
[verifier]
max_concurrent_polls = 500
```

#### 4.3.2. Expose Per-Agent Quote Latency

Add `last_quote_latency` to the agent record and include it in `process_get_status()`.

```python
# In invoke_get_quote(), wrap the HTTP call:
start_time = time.time()
res = tornado_requests.request("GET", url, **kwargs, timeout=timeout)
response = await res
agent["last_quote_latency"] = round(time.time() - start_time, 3)
```

```python
# In process_get_status(), add to response dict:
response = {
    ...
    "last_quote_latency": agent.last_quote_latency,  # seconds, float
}
```

**Impact:** OMC and operators can now:
- Identify agents consistently responding near timeout
- Set alerts on p95 quote latency per verifier
- Make data-driven decisions about agent redistribution

#### 4.3.3. Add Response Size Limit

Protect against agents sending excessively large IMA measurement lists:

```python
# In invoke_get_quote(), after receiving response:
MAX_RESPONSE_SIZE = 10 * 1024 * 1024  # 10 MB
if len(response.body) > MAX_RESPONSE_SIZE:
    logger.warning("Agent %s response too large: %d bytes", agent["agent_id"], len(response.body))
    failure.add_event("response_too_large", "Agent quote response exceeded size limit", False)
    asyncio.ensure_future(process_agent(agent, states.FAILED, failure))
    return
```

#### 4.3.4. Cap Exponential Backoff Delay

Add a `max_retry_delay` clamp to `retry_time()` to prevent unbounded delays from misconfigured `retry_interval`:

```python
# keylime/common/retry.py
def retry_time(exponential: bool, base: float, ntries: int, logger: Optional[Logger],
               max_delay: float = 60.0) -> float:
    if exponential:
        if base > 1:
            return min(base**ntries, max_delay)
        if logger:
            logger.warning("Base %f incompatible with exponential backoff", base)
    return abs(base)
```

**Impact:** Prevents a `retry_interval = 10` with `max_retries = 5` from creating a 31-hour memory hold. With `max_delay = 60`, the worst-case total backoff is capped at `5 × 60 = 300s` regardless of `retry_interval`. The `max_delay` could be exposed as a config option (e.g., `max_retry_delay = 60`).

## 5. Recommended Action Plan

| Priority | Action | Type | Effort | Impact |
|---|---|---|---|---|
| P0 | Reduce `request_timeout` to 10s | Config | Minutes | Reduces per-agent hold time by 6x |
| P0 | Cap agents per verifier via OMC hash ring | OMC code | 1 day | Prevents overloading individual verifier pods |
| P0 | Validate `retry_interval` ≤ 2 when `exponential_backoff = true` | Config | Minutes | Prevents unbounded backoff delays (section 2.6.2) |
| P1 | Reduce `max_retries` to 3 | Config | Minutes | Cuts unreachable agent memory hold from ~362s to ~44s (with timeout=10) |
| P1 | OMC slow-agent detection via `last_received_quote` staleness | OMC code | 1 day | Identifies problematic agents without Keylime changes |
| P2 | Upstream: `asyncio.Semaphore` for concurrent poll limit | Keylime PR | 2 days | Definitive fix — bounds memory regardless of agent count |
| P2 | Upstream: expose `last_quote_latency` | Keylime PR | 1 day | Enables data-driven agent management |
| P2 | Upstream: cap exponential backoff with `max_retry_delay` | Keylime PR | Hours | Prevents misconfiguration from causing hour-long memory holds |
| P3 | Upstream: response size limit | Keylime PR | 1 day | Protects against malicious/misconfigured agents |

## 6. Monitoring Recommendations

| Metric | Source | Alert Threshold |
|---|---|---|
| Verifier pod RSS memory | Kubernetes metrics | > 80% of pod memory limit |
| Agents in `GET_QUOTE_RETRY` state | Verifier bulk API | > 10% of total agents |
| `last_received_quote` staleness | OMC derived | > 3× (quote_interval + timeout) |
| Agents in FAILED state due to `not_reachable` | Verifier API (`last_event_id`) | Any increase |
| Verifier pod restart count | Kubernetes | > 0 (OOMKilled) |
| Simultaneous unreachable agents (network partition) | Verifier bulk API — count of agents in `GET_QUOTE_RETRY` | > 20% of total agents (indicates fleet-wide issue, not individual agent failure) |

---

## 7. Additional Scalability and HA Risks

### 7.1. Startup Thundering Herd

**Source:** `cloud_verifier_tornado.py`, `activate_agents()` at line 2544

On verifier restart, `activate_agents()` fires `asyncio.ensure_future(process_agent(...))` for all agents in START state simultaneously:

```python
for agent in agents:
    if agent.operational_state == states.START:
        asyncio.ensure_future(process_agent(agent_run, states.GET_QUOTE))
```

With 1,000 agents per worker, this creates 1,000 concurrent HTTP requests to agents + 1,000 DB reads in a burst at startup.

**Impact:**
- Network saturation from simultaneous outbound connections to all agents
- Database connection pool exhaustion (default pool_size=5, max_overflow=10 per worker)
- Agent-side overload if multiple verifier workers restart simultaneously (e.g., rolling update)

**Mitigation:**

| Priority | Action | Type | Effort | What it does |
|---|---|---|---|---|
| P0 | OMC: configure Kubernetes `maxUnavailable=1` on StatefulSet rolling update | K8s config | Minutes | During planned upgrades (image update, config change), prevents multiple verifier pods from restarting simultaneously. Only one partition's agents experience the burst at a time. Does not help with crash recovery, HA failover, or first-time deployment — those are single-pod restarts where the burst still occurs. |
| P1 | Upstream: add configurable startup rate limit (e.g., activate N agents/second) | Keylime PR | 1 day | Eliminates the burst entirely by staggering agent activation within a single pod. This is the actual fix. See code example below. |

**Startup rate limiting example (for P1 upstream change):**

```python
async def activate_agents(agents, verifier_ip, verifier_port):
    ACTIVATION_RATE = 50  # agents per second
    for i, agent in enumerate(agents):
        if i > 0 and i % ACTIVATION_RATE == 0:
            await asyncio.sleep(1.0)
        # ... existing activation code ...
```

With `ACTIVATION_RATE = 50`, a verifier with 200 agents takes 4 seconds to fully activate instead of firing all 200 at once. The rate could be exposed as a config option (e.g., `startup_activation_rate = 50`).

---

### 7.2. Worker Process Model — No Runtime Load Balancing

**Source:** `cloud_verifier_tornado.py`, line 2705

Agents are distributed to workers via static round-robin at startup:

```python
num_workers = config.getint("verifier", "num_workers")
for task_id in range(0, num_workers):
    active_agents = [agents[i] for i in range(task_id, len(agents), num_workers)]
```

**Problem:** This distribution is fixed at startup. Agents added after startup (via POST) are handled by whichever worker process accepts the HTTP request, but the polling loop runs in that same worker. There is no rebalancing.

**Impact:**
- Workers become unevenly loaded over time as agents are added/removed
- A worker that received many POST requests accumulates more polling coroutines
- No mechanism to migrate an agent's polling loop from one worker to another
- If a worker process dies, its agents stop being polled until the entire verifier pod restarts

**Mitigation:**

| Priority | Action | Type | Effort |
|---|---|---|---|
| P1 | OMC: distribute POST requests evenly across verifier pods via hash ring (already planned) | OMC code | Included in UC-3 |
| P1 | Set `num_workers=1` per pod and scale horizontally via StatefulSet replicas instead | K8s config | Minutes |
| P2 | Upstream: implement agent handoff between workers via shared state | Keylime PR | 5+ days |

**Recommendation:** Use `num_workers=1` per verifier pod. Scale by adding more pods (StatefulSet replicas) rather than more workers per pod. This eliminates the intra-pod load balancing problem entirely and makes each pod's resource usage predictable.

---

### 7.3. Registrar — No Pagination, Full Table Scan on List

**Source:** `keylime/web/registrar/agents_controller.py`, line 14

```python
def index(self, **_params):
    results = RegistrarAgent.all_ids()
    self.respond(200, "Success", {"uuids": results})
```

`all_ids()` executes a full table scan and returns ALL agent UUIDs in a single JSON response.

**Impact:**

| Agent Count | Response Size (approx) | Registrar Memory Spike | Network Transfer |
|---|---|---|---|
| 1,000 | ~40 KB | Minimal | Minimal |
| 10,000 | ~400 KB | Moderate | Acceptable |
| 50,000 | ~2 MB | Significant | Noticeable latency |
| 100,000 | ~4 MB | High | Risk of timeout |

- No pagination support — OMC must fetch the entire list every time
- Response is built entirely in memory before sending (no streaming)
- Under concurrent requests from multiple OMC pods, memory spikes multiply

**Mitigation:**

| Priority | Action | Type | Effort | What it does |
|---|---|---|---|---|
| P0 | OMC: cache registrar agent list with TTL (e.g., 30-60s) and serve subsequent requests from cache | OMC code | Hours | Reduces the number of full table scans to at most 1 per TTL period, regardless of how many OMC components or reconciliation loops request the list. This is effectively rate limiting — P0 because it's the simplest fix with the biggest impact. |
| P1 | Upstream: add `limit` and `offset` query params to registrar list endpoint | Keylime PR | 2 days | Allows OMC to fetch agents in pages (e.g., 100 at a time) instead of all at once. Requires changes to `AgentsController.index()` and `PersistableModel._query()` to pass `limit`/`offset` to the SQLAlchemy query. This is the proper fix at scale (10,000+ agents) where even a cached full list becomes large. |

---

### 7.4. Registrar — SharedDataManager as Single Point of Failure

**Source:** `keylime/shared_data.py`, `SharedDataManager.__init__()`, `keylime/cmd/registrar.py`, `keylime/web/registrar/agents_controller.py`

#### 7.4.1. Architecture Overview

The registrar runs as a multi-process Tornado server with two distinct types of processes: **Workers** and a **Manager**. They serve completely different purposes.

**Workers** handle HTTP requests. When an agent sends a registration request (`POST /agents/:agent_id`), a worker process handles it. Workers exist for parallelism — so the registrar can handle multiple HTTP requests simultaneously. Tornado's `fork_processes(N)` creates N copies of the server process. Each worker is a full, independent Python process with its own Tornado IOLoop (event loop for async I/O), SQLAlchemy connection pool (for DB queries), and memory space. The OS kernel distributes incoming TCP connections across workers. Workers don't talk to each other — they're isolated processes that happen to share the same listening socket.

**The Manager** is a shared state server — not an orchestrator. It does not direct or coordinate workers. It is a passive process that holds shared objects (locks and dictionaries) in its own memory. Workers come to it to acquire and release locks, like a shared locker room. The name comes from Python's `multiprocessing.Manager` class.

| | Workers | Manager |
|---|---|---|
| Purpose | Handle HTTP requests from agents, tenant, verifier | Hold shared locks and data that workers need to coordinate |
| Count | N (= CPU cores visible to the pod, by default) | Always exactly 1 |
| Created by | `tornado.process.fork_processes()` | `multiprocessing.Manager()` |
| Talks to | Clients via HTTP, PostgreSQL via SQLAlchemy | Workers only, via Unix socket IPC |
| Touches DB | Yes (each has its own connection pool) | No (never touches the database) |
| If it dies | That worker's in-flight requests fail; Tornado may respawn it | All workers lose access to shared locks; all registrations fail |

**Why the Manager exists:** Workers are separate processes — they can't use a regular Python `threading.Lock` because locks only work within a single process. If two registration requests for the same `agent_id` land on different workers simultaneously, both would pass the "does this agent exist?" check and both would try to insert — a race condition. The Manager provides cross-process locks to prevent this.

**Example flow** when agent-001 registers:

```
1. HTTP request arrives at the kernel
2. Kernel routes it to Worker 2 (arbitrary)
3. Worker 2's code runs:
   a. get_shared_memory()           → returns the global SharedDataManager singleton
   b. agent_locks["001"]            → IPC to Manager: "get lock for 001"
   c. with agent_lock:              → IPC to Manager: "acquire lock for 001"
   d.   RegistrarAgent.get("001")   → SQL query to PostgreSQL (Worker 2's own DB pool)
   e.   agent.produce_ak_challenge  → CPU work in Worker 2
   f.   agent.commit_changes()      → SQL INSERT to PostgreSQL
   g. (lock released)               → IPC to Manager: "release lock for 001"
4. Worker 2 sends HTTP 200 response to agent-001
```

Steps (b), (c), and (g) are the only ones involving the Manager. Everything else — HTTP handling, DB queries, crypto — happens entirely within the worker.

The startup sequence in `keylime/cmd/registrar.py` is:

1. `initialize_shared_memory()` — creates a single `SharedDataManager` instance in the parent process, which spawns the Manager background process
2. `server.start_multi()` — calls `tornado.process.fork_processes(worker_count)`, forking N worker processes that inherit the connection to the Manager

When `SharedDataManager.__init__()` runs, it does this:

```python
ctx = mp.get_context("fork")
self._manager = ctx.Manager()      # Spawns the Manager as a SEPARATE background process
self._store = self._manager.dict()  # Proxy dict — actual data lives in Manager process
self._lock = self._manager.Lock()   # Proxy lock — actual lock lives in Manager process
```

`ctx.Manager()` starts the dedicated Manager background process that owns the actual dict and lock objects in its own memory space. All other processes (the parent + all forked workers) communicate with it over a **Unix domain socket** using Python's `multiprocessing` proxy protocol. The proxy objects (`_store`, `_lock`) held by workers are thin stubs that serialize every operation into an IPC call.

After `fork_processes()`, the process architecture looks like this:

```
┌──────────────────────────────────────────────────────────┐
│  Manager Process (shared state server)                   │
│  ┌────────────────────────────────────────────────────┐  │
│  │  _store (actual dict with all data)                │  │
│  │  _lock (actual global Lock)                        │  │
│  │  per-agent Lock objects (one per registered agent) │  │
│  └────────────────────────────────────────────────────┘  │
│  Single-threaded event loop                              │
│  Listens on Unix socket for proxy requests               │
│  PASSIVE: only responds to worker requests, never        │
│  initiates actions or touches the database               │
└────────────────────────┬─────────────────────────────────┘
                         │ Unix socket IPC (every read/write/lock)
         ┌───────────────┼───────────────┐
         │               │               │
  ┌──────┴──────┐ ┌──────┴──────┐ ┌──────┴──────┐
  │  Worker 0   │ │  Worker 1   │ │  Worker 2   │
  │  (Tornado)  │ │  (Tornado)  │ │  (Tornado)  │
  │             │ │             │ │             │
  │ Handles HTTP│ │ Handles HTTP│ │ Handles HTTP│
  │ Queries DB  │ │ Queries DB  │ │ Queries DB  │
  │ DictProxy → │ │ DictProxy → │ │ DictProxy → │
  │ LockProxy → │ │ LockProxy → │ │ LockProxy → │
  │ (thin stubs │ │ (thin stubs │ │ (thin stubs │
  │  over IPC)  │ │  over IPC)  │ │  over IPC)  │
  └─────────────┘ └─────────────┘ └─────────────┘
```

**Worker count defaults to CPU count — no config knob exists for the registrar.**

The `Server` base class (`keylime/web/base/server.py`) initializes `__worker_count = 0`, and `RegistrarServer._setup()` never overrides it. The `worker_count` property then falls through to `multiprocessing.cpu_count()`:

```python
# keylime/web/base/server.py, line 605
@property
def worker_count(self) -> int:
    if self.__worker_count == 0 or self.__worker_count is None:
        return multiprocessing.cpu_count()    # ← default for registrar
    else:
        return self.__worker_count
```

This means the registrar forks **as many worker processes as CPU cores visible to the pod/host**. Since there is no config option to override this, the number of workers is implicitly controlled by the CPU resources allocated to the pod (or available on the host).

**Why this matters:** The registrar is I/O-bound, not CPU-bound — it receives a request, does a DB query, generates one TPM challenge, writes to DB, and responds. Each additional worker adds resource overhead without proportional throughput gain, because all workers serialize through the SharedDataManager's single-threaded event loop (Risk 2 below).

Per-worker resource cost:

| Resource | Per Worker |
|---|---|
| Python process baseline RSS | ~200–300 MB (includes loaded modules: SQLAlchemy, Tornado, cryptography) |
| DB connection pool (`pool_size=5, max_overflow=10`) | Up to 15 connections |
| Proxy connection to Manager | 1 socket (serialized through Manager's single thread) |

These costs scale linearly with CPU cores. A pod with 16 cores allocated will fork 16 workers, eventually consuming up to ~3.2–4.8 GB RSS and up to 240 DB connections — most of which sit idle since registration is not a hot path (it happens once per agent lifecycle, not continuously).

Note: The verifier's old tornado code (`cloud_verifier_tornado.py`, line 2700) reads `config.getint("verifier", "num_workers")` with a fallback to `cpu_count()`, but the new `Server` base class used by `RegistrarServer` has no equivalent config option.

**Sizing guidance:**

Pod CPU allocation should be based on the expected registration throughput, not general compute capacity. Since all workers funnel through the SharedDataManager, adding more workers beyond a small number yields diminishing returns.

| Deployment | Approach | Rationale |
|---|---|---|
| Kubernetes (horizontal scaling) | Allocate 1–2 CPU per pod, scale via replicas | Each pod gets 1–2 workers; scale out by adding pods rather than adding cores per pod. Predictable per-pod resource usage; eliminates intra-pod Manager contention |
| Single-node | Limit to 2–4 cores visible to the process | Registration is infrequent per agent; 2–4 workers handle burst registration (e.g., fleet rollout) without excessive idle overhead |

#### 7.4.2. IPC Cost Per Registration

The registration flow in `AgentsController.create()` acquires a per-agent lock via the Manager. Each step that touches the Manager is a synchronous IPC round-trip over the Unix socket:

```python
shared_mem = get_shared_memory()
agent_locks = shared_mem.get_or_create_dict("agent_registration_locks")

if agent_id not in agent_locks:                        # IPC call 1: __contains__ on proxy
    agent_locks[agent_id] = shared_mem.manager.Lock()  # IPC call 2: create Lock + IPC call 3: store it

agent_lock = agent_locks[agent_id]                     # IPC call 4: __getitem__ on proxy

with agent_lock:                                       # IPC call 5: acquire + IPC call 6: release
    agent = RegistrarAgent.get(agent_id)
    # ... validate TPM identity, generate challenge, commit to DB ...
```

A single registration request makes at minimum 5–6 IPC round-trips to the Manager. Every operation on `agent_locks` (a `FlatDictView` backed by the proxy dict) and every lock acquire/release goes through this path. This is why the Manager's single-threaded event loop becomes a bottleneck under load (see Risk 2 below).

#### 7.4.3. Failure Modes

**Risk 1: Manager Process Death (Severity: Critical)**

The Manager is a regular Python process. If it dies (OOM-killed, segfault, unhandled exception), every proxy object becomes invalid instantly. All workers that try to acquire a lock or access the shared dict will get:

```
ConnectionRefusedError: [Errno 111] Connection refused
# or
BrokenPipeError: [Errno 32] Broken pipe
```

There is **no reconnection logic** in `SharedDataManager`. The `cleanup()` method is registered via `atexit` for graceful shutdown, but nothing monitors the Manager in the other direction — no health check, no heartbeat, no auto-restart. The `_parent_pid` tracked in `__init__` is only logged, never used for recovery. The only way to recover is restarting the entire registrar pod.

Since the Manager process death causes unhandled exceptions in the workers (before the DB `IntegrityError` safety net is reached), **all agent registrations fail** until the pod is restarted.

**Risk 2: Serialization Bottleneck (Severity: Medium)**

The Manager process handles proxy requests on a **single-threaded internal event loop** inside `multiprocessing.managers.BaseManager`. All IPC calls from all workers are processed sequentially.

Under high registration throughput (e.g., 100+ agents registering simultaneously during a fleet rollout), the Manager becomes a funnel. With 5–6 IPC round-trips per registration and N workers all serializing through the same Manager, the effective concurrency of registration drops to near-single-threaded regardless of how many Tornado workers are running.

**Risk 3: Lock Accumulation / Memory Leak (Severity: Low-Medium)**

Every agent registration creates a per-agent `Lock` object in the Manager process:

```python
agent_locks[agent_id] = shared_mem.manager.Lock()
```

These locks are cleaned up on `DELETE` and on failed `activate`, but can leak due to the two-phase registration protocol:

Agent registration is a two-phase handshake:
1. **Phase 1 — `POST /agents/:agent_id`**: Agent sends TPM identity (EK/AIK). Registrar encrypts a challenge with the EK, saves the agent record with `active = False`, and returns the challenge blob. A per-agent lock is created in the Manager at this point.
2. **Phase 2 — `POST /agents/:agent_id/activate`**: Agent decrypts the challenge via its TPM, computes an HMAC, sends it back. Registrar verifies and sets `active = True`. On verification failure, the agent record is deleted and the lock is cleaned up.

An agent that completes Phase 1 but never reaches Phase 2 (crash, network loss, TPM issue) leaves behind both a DB record with `active = False` and a per-agent lock in the Manager process. The `show` endpoint rejects these (`if not agent.active: respond(404)`), so they're invisible to the verifier/tenant, but the lock persists. There is **no cleanup job** for stale inactive agents or their associated locks in the codebase.

With 50,000 agents, that's up to 50,000 `Lock` proxy objects, each consuming memory for lock state + socket connection metadata in the Manager process.

**Risk 4: Fork Inheritance Fragility (Severity: Medium)**

The proxy connections (Unix sockets to the Manager) are inherited by child processes via `fork()`. This works for the initial fork, but is fragile:

- If a Tornado worker process crashes and is respawned, the new process gets a fresh `fork()` from the original parent. The Manager's internal connection tracking may be stale for the old connection, and the new process inherits the parent's socket file descriptors which may or may not still be valid depending on the Manager's connection cleanup.
- The code comment in `SharedDataManager.__init__` explicitly warns: *"The Manager must be started BEFORE any fork() calls"* — but there is no runtime enforcement of this constraint.

**Risks Summary:**

| Risk | Impact | Likelihood |
|---|---|---|
| Manager process dies | All registrations fail with unhandled IPC errors; no self-recovery | Low (but unrecoverable without pod restart) |
| Manager becomes serialization bottleneck | Registration throughput degrades to near-single-threaded under load | Medium (100+ simultaneous registrations) |
| Per-agent lock accumulation | Manager process memory grows linearly with agents that registered but never cleaned up | Low-Medium (depends on agent lifecycle) |
| Fork-inherited socket connections become stale | Workers silently fail to synchronize after worker crash/respawn | Medium (depends on restart sequence) |

#### 7.4.4. Crash Recovery Behavior

**What happens when the Manager process dies during agent registration:**

The `create()` method accesses the SharedDataManager *before* touching the database:

```python
shared_mem = get_shared_memory()                       # Returns the global singleton
agent_locks = shared_mem.get_or_create_dict(...)       # IPC call → fails here
```

If the Manager process is dead, the IPC call throws `ConnectionRefusedError` or `BrokenPipeError`. This is **unhandled** — there is no try/except around the SharedDataManager calls in `create()`. Tornado catches it at the request handler level and returns a **500 Internal Server Error** to the agent. The DB is never touched, so there are no partial writes.

**There is no automatic recovery.** The `get_shared_memory()` function returns the global singleton `_global_shared_manager`. Once the Manager process behind it is dead, the singleton is permanently broken:

```python
def get_shared_memory() -> SharedDataManager:
    global _global_shared_manager
    if _global_shared_manager is None:      # NOT None — the Python object still exists
        ...                                  # This block never runs
    return _global_shared_manager            # Returns the broken instance every time
```

Every subsequent registration request hits the same dead proxy objects and gets the same error. **All agent registrations fail until the entire registrar pod is restarted.**

**Agent-side recovery after pod restart:** The Rust-based keylime agent retries registration on failure. Since the DB was never written to during the failed attempt, the retry is a clean first-time registration. If an agent had completed Phase 1 (DB record with `active = False`) before the crash, the `create()` code handles re-registration: it loads the existing record, validates the TPM identity hasn't changed, generates a new challenge, and overwrites the record. So agents self-heal on retry — the problem is the downtime window until the pod restarts.

#### 7.4.5. Detecting Manager Process Death

The `multiprocessing.SyncManager` exposes its child process via `_manager._process`, which provides both the PID and an `is_alive()` check. A health probe can use this to detect Manager death.

**Option A: Kubernetes liveness probe with a health endpoint (recommended)**

Add a `/health` endpoint to the registrar that probes the Manager process:

```python
# keylime/web/registrar/health_controller.py
class HealthController(Controller):
    # GET /health
    def check(self, **_params):
        shared_mem = get_shared_memory()
        try:
            # Probe 1: Is the Manager process alive?
            if not shared_mem.manager._process.is_alive():
                self.respond(503, "SharedDataManager process is dead")
                return

            # Probe 2: Can we actually communicate with it? (IPC round-trip)
            shared_mem.has_key("__health_check__")

            self.respond(200, "Healthy")
        except (ConnectionRefusedError, BrokenPipeError, EOFError, OSError):
            self.respond(503, "SharedDataManager IPC failed")
```

Kubernetes probe configuration:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8891
    scheme: HTTP          # /health can be insecure — it exposes no secrets
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 2     # Restart pod after 2 consecutive failures (20s)
```

This is the cleanest approach because it tests the actual IPC path, not just whether a process exists.

**Option B: Sidecar process monitor (no keylime code changes)**

If modifying keylime code is not feasible, a sidecar container or init script can monitor the Manager process from outside:

```bash
#!/bin/bash
# manager_health_check.sh — run as liveness probe exec command
# The registrar pod should have: 1 parent + N workers + 1 Manager process
# If the Manager dies, the process count drops below expected

REGISTRAR_PID=$(pgrep -f "keylime.cmd.registrar" | head -1)
if [ -z "$REGISTRAR_PID" ]; then
    exit 1  # Registrar not running at all
fi

# Count child processes of the registrar parent
CHILD_COUNT=$(pgrep -P "$REGISTRAR_PID" | wc -l)
EXPECTED_WORKERS=$(python3 -c "from keylime import config; print(config.getint('registrar', 'num_workers', fallback=0))")

# Expected children = num_workers + 1 (Manager process)
EXPECTED_CHILDREN=$((EXPECTED_WORKERS + 1))

if [ "$CHILD_COUNT" -lt "$EXPECTED_CHILDREN" ]; then
    echo "Expected $EXPECTED_CHILDREN children, found $CHILD_COUNT — Manager may be dead"
    exit 1
fi

exit 0
```

```yaml
livenessProbe:
  exec:
    command: ["/bin/bash", "/opt/keylime/manager_health_check.sh"]
  initialDelaySeconds: 30
  periodSeconds: 15
  failureThreshold: 2
```

This is less precise (it counts processes rather than testing IPC), but requires no keylime code changes.

#### 7.4.6. Mitigation Summary

| Priority | Action | Type | Effort |
|---|---|---|---|
| P0 | Add `/health` endpoint that probes Manager process liveness + IPC (Option A above) | Keylime PR or OMC wrapper | 1 day |
| P0 | Configure Kubernetes `livenessProbe` against `/health` to auto-restart pod on Manager death | K8s config | Minutes |
| P0 | Upstream: add `num_workers` config option to registrar (currently defaults to `cpu_count()` with no override) | Keylime PR | Hours |
| P0 | Size registrar pod CPU allocation to desired worker count (1–2 cores per pod); scale horizontally via replicas | K8s config | Minutes |
| P1 | If no code changes possible: deploy sidecar/exec liveness probe that checks child process count (Option B above) | K8s config | Hours |
| P1 | Add cleanup job for stale `active = False` agent records and their associated Manager locks | Keylime PR | 1 day |
| P2 | Upstream: replace `multiprocessing.Manager` with database-level advisory locks (e.g., PostgreSQL `pg_advisory_lock(hash(agent_id))`) | Keylime PR | 3 days |

The database advisory lock approach is the cleanest long-term fix: it eliminates the Manager process entirely, removes the IPC overhead, and uses infrastructure (the database) that already has its own HA, monitoring, and connection pooling. The DB is already a hard dependency for the registrar, so this adds no new dependencies.

---

### 7.5. No Health Check or Readiness Endpoint

**Source:** Neither verifier nor registrar exposes a `/health` or `/ready` endpoint.

The `/version` endpoint exists but:
- Verifier: returns 400 for `/versions` (confirmed by testing). Only `/version` works, and it only proves the HTTP server is listening — not that the DB is reachable or that polling is functional.
- Registrar: has `/version` but same limitation — no DB connectivity check, no Manager health check.

**Impact in Kubernetes:**
- Without a proper `readinessProbe`, a pod with a dead DB connection continues receiving traffic from the Service
- Without a proper `livenessProbe`, a pod with a stuck IOLoop or dead Manager process is never restarted
- During rolling updates, traffic is routed to new pods before they've finished activating agents

**Mitigation:**

| Priority | Action | Type | Effort |
|---|---|---|---|
| P0 | Use `/version` as a basic `livenessProbe` (confirms process is alive) | K8s config | Minutes |
| P1 | OMC: implement a health-check wrapper that tests `/version` + a lightweight DB query | OMC code | Hours |
| P0 | Upstream: add `/health` endpoint that checks DB connectivity, worker status, and active agent count (aligns with registrar `/health` in section 7.4.5) | Keylime PR | 2 days |

**Kubernetes probe configuration (immediate):**

```yaml
livenessProbe:
  httpGet:
    path: /version
    port: 8881
    scheme: HTTPS
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /version
    port: 8881
    scheme: HTTPS
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 2
```

Note: This only confirms the HTTP server is listening. It does NOT verify DB connectivity or polling health. A proper `/health` endpoint would be needed for full readiness checking.

---

## 8. Consolidated Risk Summary

| # | Risk | Component | Severity | Likelihood | Mitigation Available Without Keylime Changes |
|---|---|---|---|---|---|
| 1 | Memory bloat from slow agents | Verifier | High | High | Partial — reduce timeout, cap agents per verifier |
| 2 | No concurrency limit on polling | Verifier | High | High | No — requires upstream semaphore |
| 3 | Uncapped retry hold time (`max_retries` × `retry_interval` exponential interaction) | Verifier | Medium-High | Medium (misconfiguration or network partition) | Yes — validate `retry_interval` ≤ 2, reduce `max_retries` to 3, reduce `request_timeout`. Upstream `max_retry_delay` clamp needed for full fix. |
| 4 | Startup thundering herd | Verifier | Medium | High (every restart) | Partial — K8s rolling update config |
| 5 | Static worker load distribution | Verifier | Medium | Medium | Yes — use `num_workers=1`, scale via pods |
| 6 | Registrar full table scan on list | Registrar | Medium | High (every OMC list call) | Yes — OMC-side caching and rate limiting |
| 7 | SharedDataManager SPOF | Registrar | High | Low (but unrecoverable) | Partial — K8s liveness probe (exec-based or `/health` endpoint) |
| 8 | No health/readiness endpoints | Both | High | Certain | Partial — use `/version` as basic probe |
| 9 | Registrar worker count defaults to `cpu_count()` with no config override | Registrar | Medium | Certain (every deployment) | Partial — size pod CPU allocation to desired worker count (1–2 cores per pod); upstream config option needed for explicit control |

---

## 9. Scalability & HA Fitness Assessment

This section rates the keylime verifier and registrar on their readiness for scalable, highly available deployment — both as-is (raw keylime) and with OMC integration (wrappers, config tuning, K8s infrastructure).

### 9.1. Rating Methodology — Defaults vs Architecture

The scores below distinguish between two categories of issues:

- **Bad defaults (configurable):** Issues that exist with out-of-the-box settings but can be fixed by changing config values. These are not architectural problems — they're deployment choices. Example: `request_timeout = 60s` is too high, but setting it to `10s` is a one-line config change.
- **Architectural limitations (not configurable):** Issues baked into the code that no config change can fix. These require upstream code changes. Example: no concurrency semaphore — every agent gets an unbounded concurrent coroutine regardless of config.

The "Raw" column rates keylime with defaults. The "Tuned" column rates it with optimized config (no code changes). The difference between Raw and Tuned shows how much is just bad defaults vs real architectural gaps.

**Deployment context:** IMA (Integrity Measurement Architecture) is **not enabled** in the current deployment. This eliminates the largest per-agent memory variable (IMA policies can be 1-10MB each). Without IMA, per-agent memory during a poll cycle is ~57KB (coroutine ~2KB + TCP/TLS connection ~50KB + agent dict ~5KB), not megabytes.

### 9.2. Concurrency Control — What It Means

In pull mode, the verifier polls every agent by firing off HTTP requests without waiting for responses:

```
Agent 1 → fire off request (don't wait)     ← in flight
Agent 2 → fire off request (don't wait)     ← in flight
Agent 3 → fire off request (don't wait)     ← in flight
...all agents launched simultaneously...
Agent N → fire off request (don't wait)     ← in flight

All N requests are in flight at the same time.
Each holds: 1 coroutine (~2KB) + 1 TCP/TLS connection (~50KB) + agent dict (~5KB)
```

"No concurrency control" means there's no limit on N. With 14 agents, all 14 are in flight — trivial. With 5,000 agents, all 5,000 are in flight — 250MB just in connections.

A concurrency semaphore (the missing upstream fix) would cap in-flight requests:

```
Semaphore limit = 20

Agents 1-20  → fire off requests (20 slots used)
Agent 21     → WAIT (all slots full)
              ...Agent 3 responds, frees a slot...
Agent 21     → fire off request (reuses freed slot)
```

This bounds memory to `20 × ~57KB = ~1.1MB` regardless of total agent count.

**At 14 agents, this is irrelevant** — 14 concurrent requests use ~800KB total. The concurrency problem only matters at hundreds+ of agents. At the current scale, it's a non-issue.

### 9.3. Verifier — Scalability (Pull Mode)

| Factor | Raw (defaults) | Tuned (optimized config) | Architectural Limit | Notes |
|---|---|---|---|---|
| Concurrency control | 1/10 | 1/10 | Yes | No semaphore. Not configurable. But irrelevant below ~200 agents. |
| Memory per agent (no IMA) | 7/10 | 8/10 | No | ~50KB per agent without IMA. 100 agents = ~5MB. Manageable. |
| Timeout behavior | 2/10 | 7/10 | No | Default 60s is bad. Set to 10s → 6x improvement. Fully configurable. |
| Retry hold time | 3/10 | 7/10 | Partial | Default `max_retries=5` + `retry_interval=2` + `timeout=60` = ~362s hold per unreachable agent. Tuned (`max_retries=3`, `timeout=10`) = ~44s. No `max_delay` clamp on exponential backoff — architectural gap (section 2.6.2). |
| Worker count | 3/10 | 7/10 | No | Default = cpu_count (wasteful). Set `num_workers=1` for small scale. Configurable. |
| Horizontal scaling | 6/10 | 6/10 | No | `verifier_id` partition key works. No built-in orchestration, but OMC hash ring fills the gap. |
| Startup behavior | 2/10 | 2/10 | Yes | Thundering herd on restart. Not configurable. Tolerable below ~200 agents. |
| Observability | 3/10 | 3/10 | Yes | No per-agent latency. Not configurable. `last_received_quote` staleness is the only indirect signal. |

### 9.4. Verifier — HA (Pull Mode)

| Factor | Rating | Configurable? | Notes |
|---|---|---|---|
| State externalization | 9/10 | N/A | All state in PostgreSQL. Strongest HA property. |
| Partition key design | 8/10 | Yes | `verifier_id` cleanly partitions agents. Config: `uuid = v_01` in verifier.conf. |
| Native HA support | 1/10 | No | None. Requires external wrapper (K8s Leases). |
| Failover feasibility | 6/10 | N/A | Feasible via K8s Lease wrapper. Requires custom code. |
| Health checking | 2/10 | No | Only `/version`. Not configurable — needs code change for `/health`. |

### 9.5. Verifier — With Optimized Config (No Code Changes)

Recommended config for pull mode deployment without IMA:

```ini
[verifier]
num_workers = 1          # 14 agents don't need multiple workers
request_timeout = 10     # Agents respond in 700ms; 10s is generous
quote_interval = 180     # 3 minutes is fine for current scale
max_retries = 3          # Fast transition to FAILED for unreachable agents
```

What this achieves:

| Problem | Default Behavior | With Tuned Config |
|---|---|---|
| Memory footprint | 8 workers × ~250MB each = up to ~2GB | 1 worker × ~250MB = ~250MB |
| Connection hold time | Up to 60s per agent | Up to 10s per agent |
| Unreachable agent memory hold | Minutes (many retries with backoff) | ~30s (3 retries then FAILED) |
| DB connections (default pool) | 8 × 15 = 120 max | 1 × 15 = 15 max |

What this does NOT fix (architectural):

- No concurrency semaphore (irrelevant at 14-100 agents)
- No startup staggering (tolerable at 14-100 agents)
- No per-agent latency tracking
- No `/health` endpoint

### 9.6. Registrar — Scalability

| Factor | Raw (defaults) | Tuned (optimized config) | Architectural Limit | Notes |
|---|---|---|---|---|
| Registration throughput | 3/10 | 3/10 | Yes | Manager serialization bottleneck. Not configurable. Only matters during mass rollout. |
| Worker count | 2/10 | 6/10 | No | Defaults to cpu_count. Control via pod CPU allocation (1-2 cores). |
| List endpoint | 2/10 | 2/10 | Yes | Full table scan, no pagination. Not configurable. OMC caching mitigates. |
| Horizontal scaling | 6/10 | 6/10 | No | Active-active behind load balancer works. |

### 9.7. Registrar — HA

| Factor | Rating | Configurable? | Notes |
|---|---|---|---|
| Active-active capability | 8/10 | Yes | Multiple pods behind load balancer. DB unique constraint is cross-pod safety. |
| State externalization | 9/10 | N/A | All data in PostgreSQL. |
| Manager SPOF | 3/10 | No | Per-pod. Other pods continue in active-active. Not configurable — needs code change or exec probe. |
| Health checking | 2/10 | No | Only `/version`. Needs code change for `/health`. |
| Recovery behavior | 7/10 | N/A | Agents retry. DB state clean after crash. |

### 9.8. Consolidated Scorecard

**Important:** "Raw" = keylime defaults. "Tuned" = optimized config, no code changes. "OMC" = tuned config + wrappers + K8s infra.

| Dimension | Verifier Raw | Verifier Tuned | Verifier OMC | Registrar Raw | Registrar Tuned | Registrar OMC |
|---|---|---|---|---|---|---|
| Scalability | 3/10 | 5/10 | 6/10 | 4/10 | 5/10 | 7/10 |
| HA | 5/10 | 5/10 | 7/10 | 7/10 | 7/10 | 8/10 |
| Observability | 3/10 | 3/10 | 5/10 | 2/10 | 2/10 | 4/10 |
| Operational Safety | 2/10 | 5/10 | 6/10 | 3/10 | 5/10 | 6/10 |
| **Overall** | **3/10** | **5/10** | **6/10** | **4/10** | **5/10** | **7/10** |

The jump from Raw→Tuned (config only) is significant for the verifier: 3→5 overall. Most of the "poor" rating is bad defaults, not architectural flaws — at least at the current scale of 14-100 agents without IMA.

The jump from Tuned→OMC adds HA (K8s Lease wrapper), agent distribution (hash ring), and monitoring (staleness detection).

### 9.9. Practical Assessment at 100-Agent Scale (No IMA)

**Verifier at 100 agents (tuned config: timeout=10s, num_workers=1, max_retries=3, quote_interval=180s, no IMA):**

| Metric | Worst Case | Typical Case | Acceptable? |
|---|---|---|---|
| Concurrent coroutines | 100 (all at once) | ~10-20 (staggered by quote_interval) | Yes — 100 × 57KB = 5.7MB, trivial |
| Memory (no IMA) | 100 × 50KB = 5MB connections | ~1-2MB | Yes |
| Worker memory (1 worker) | ~250MB baseline + per-agent overhead | ~250-300MB steady | Yes — 512Mi limit is sufficient |
| Total pod memory | ~350MB peak | ~300MB steady | Yes |
| Startup thundering herd | 100 concurrent requests | 100 concurrent requests | Tolerable — burst, not sustained |
| Failover (K8s Lease wrapper) | ~20-30s gap | ~20-30s gap | Acceptable |

**Verdict at 100 agents without IMA: Comfortable.** With 1 worker, the memory footprint is predictable and bounded. The verifier's architectural limitations (no semaphore, no startup staggering) are irrelevant at this scale. Total pod memory stays well under 512Mi.

**If IMA were enabled:** The picture changes dramatically. Each agent's IMA policy (1-10MB) is loaded per poll cycle. At 100 agents with 1MB policies, worst case jumps to ~100MB per cycle. With 10MB policies, ~1GB. This is where the concurrency semaphore becomes critical — it would cap how many policies are loaded simultaneously.

### 9.10. Score Improvement with Upstream Changes

If the upstream keylime changes from section 4.3 and section 7 mitigations are implemented:

**Verifier upstream changes and their impact:**

| Change | Effort | Score Impact | Matters Without IMA? |
|---|---|---|---|
| Concurrency semaphore (`max_concurrent_polls`) | 2 days | Scalability: +2 at 500+ agents | No (at current scale). Yes (at 500+ or with IMA). |
| Cap exponential backoff with `max_retry_delay` | Hours | Operational Safety: +1 | Yes — prevents misconfiguration from causing hour-long memory holds at any scale. |
| Startup rate limiting (activate N agents/second) | 1 day | Operational Safety: +2 | Marginal at 100 agents. Critical at 500+. |
| Per-agent quote latency (`last_quote_latency`) | 1 day | Observability: +3 | Yes — useful at any scale for identifying slow agents. |
| Response size limit | 1 day | Operational Safety: +1 | No (without IMA, responses are small). |
| `/health` endpoint (DB + polling status) | 2 days | HA: +2 | Yes — needed for proper K8s probes at any scale. |

**Registrar upstream changes and their impact:**

| Change | Effort | Score Impact |
|---|---|---|
| `num_workers` config option | Hours | Scalability: +1 |
| Pagination on list endpoint | 2 days | Scalability: +1 at 1000+ agents |
| `/health` endpoint (DB + Manager health) | 1 day | HA: +1 |
| Replace Manager with DB advisory locks | 3 days | Scalability: +3, HA: +2. Eliminates SPOF and serialization bottleneck. |
| Stale agent cleanup job | 1 day | Operational Safety: +1 |

**Projected scores with upstream changes:**

| Dimension | Verifier (OMC only) | Verifier (OMC + Upstream) | Registrar (OMC only) | Registrar (OMC + Upstream) |
|---|---|---|---|---|
| Scalability | 6/10 | 8/10 | 7/10 | 8/10 |
| HA | 7/10 | 8/10 | 8/10 | 9/10 |
| Observability | 5/10 | 7/10 | 4/10 | 5/10 |
| Operational Safety | 6/10 | 7/10 | 6/10 | 8/10 |
| **Overall** | **6/10** | **8/10** | **7/10** | **8/10** |

**Total upstream effort: ~12 days of development.**

### 9.11. Scale Ceilings by Integration Level (No IMA)

Without IMA, per-agent memory is ~50KB instead of 1-10MB. This dramatically raises the ceilings:

| Integration Level | Verifier Ceiling (No IMA) | Verifier Ceiling (With IMA) | Registrar Ceiling | Limiting Factor |
|---|---|---|---|---|
| Raw keylime (defaults) | ~200 agents | ~50 agents | ~200 agents | Verifier: 60s timeout wastes connections. With IMA: OOM from policy loading. |
| Tuned config only | ~500 agents | ~100 agents | ~500 agents | Verifier: no semaphore, but 500 × 50KB = 25MB is fine without IMA. With IMA: 500 × 1MB = 500MB. |
| OMC + wrappers + K8s | ~1,000 agents (partitioned) | ~200 agents (partitioned) | ~1,000 agents | Verifier: partitioning distributes load. Without IMA, each partition handles 300-500 comfortably. |
| OMC + upstream changes | ~5,000+ agents | ~2,000+ agents | ~5,000+ agents | Verifier: semaphore bounds memory per partition. |

### 9.12. Key Takeaway

The registrar is in better shape than the verifier for OMC integration because:

1. It naturally supports active-active (the verifier needs active-standby with a custom K8s Lease wrapper)
2. Registration is a short-lived, infrequent operation (the verifier runs continuous long-lived polling loops)
3. Its worst failure mode (Manager death) is recoverable by pod restart and only affects one pod in an active-active setup

The verifier is the harder problem because:

1. The continuous polling model means every scalability issue compounds over time (memory bloat, connection accumulation)
2. HA requires a custom K8s Lease wrapper with self-fencing — significantly more complex than the registrar's load-balancer approach
3. The concurrency semaphore is the only architectural limitation that matters at scale — but it's irrelevant below ~200 agents without IMA

**At 14 agents (current deployment, no IMA):** The 3/10 raw score is misleading. With config tuning (`num_workers=1`, `request_timeout=10`), the verifier is comfortable at 5/10. The observed memory growth (see section 10 for details) is addressable through config tuning alone.

**At 100 agents (no IMA): Comfortable with config tuning alone.** Total pod memory under 512Mi. No upstream changes needed.

**At 200 agents: Requires partitioning (2 verifier partitions via OMC hash ring).** Workable but operationally complex.

**Beyond 500 agents or with IMA enabled: Upstream changes become mandatory.** The concurrency semaphore is the gate.

---

## 10. Observed Memory Growth — 14 Agents Over 40 Hours (Pull Mode)

### 10.1. Environment

| Parameter | Value |
|---|---|
| Agents | 14 |
| Agent latency | ~700ms |
| `num_workers` | 8 |
| `db_pool_sz_ovfl` | 20,30 (pool_size=20, max_overflow=30) |
| `request_timeout` | 30s |
| `quote_interval` | 180s |
| CPU Request / Limit | 800m / 1000m |
| Memory Request / Limit | 4Gi / 8Gi |

**Observation:** Continuous memory growth over 40 hours with only 14 agents.

### 10.2. Why 14 Agents Shouldn't Cause Memory Pressure — But Do

With 14 agents and `quote_interval = 180s`, at any given moment only a handful of agents are being polled. Active connection memory is tiny (~14 × 50KB = 700KB). The `request_timeout = 30s` is irrelevant since agents respond in 700ms. This is not a concurrency or connection problem.

Over 40 hours, the verifier executes:

```
40 hours × 3600s/hour ÷ 180s interval = 800 poll cycles per agent
800 × 14 agents = ~11,200 total poll cycles
```

### 10.3. Root Causes of Continuous Growth

**Observed:** Pod memory grew from ~250MB to ~2000MB over 40 hours (~1750MB growth).

This growth pattern is significant: if the 8-worker baseline were the primary cause, the pod would have started at ~2GB (8 × 250MB), not 250MB. The ~250MB starting point indicates that Linux's copy-on-write (COW) mechanism is at play, and the growth represents gradual COW page dirtying combined with per-cycle memory accumulation.

**Cause 1: Copy-on-Write page dirtying across 8 workers (primary driver of the growth curve)**

When `tornado.process.fork_processes(8)` creates 8 workers, they initially share the parent's memory pages via Linux's copy-on-write mechanism. The OS reports RSS as ~250MB (the shared parent footprint), not 8 × 250MB. This is why the pod starts at ~250MB despite having 8 workers.

As each worker processes requests and modifies memory (SQLAlchemy sessions, agent dicts, quote response parsing, Tornado IOLoop state), the shared pages get copied into each worker's private memory — this is called a "COW fault." Over 40 hours and ~11,200 poll cycles, each worker gradually dirties its own pages, and the pod RSS grows toward the theoretical maximum of 8 × 250MB = 2GB.

The observed growth from 250MB to ~2000MB over 40 hours is almost exactly this trajectory: 8 workers gradually diverging from shared to private memory.

**Why `num_workers = 1` is the fix:** With 1 worker, there's no fork, no COW, no page dirtying. The pod starts at ~250MB and stays near that level (plus any per-cycle leak, which is small).

**Cause 2: SQLAlchemy session/object accumulation**

With `db_pool_sz_ovfl = 20,30`, each worker can hold up to 50 DB connections (400 total across 8 workers). Each poll cycle loads the agent via `session.query(VerfierMain)` with joinedload for `mb_policy` and `ima_policy`, updates fields, and commits. SQLAlchemy's identity map and session cache can hold references to ORM objects longer than expected. Over 11,200 cycles, this accumulates and accelerates the COW page dirtying — each new ORM object allocation dirties a previously-shared page.

**Cause 3: Tornado IOLoop callback references (minor contributor)**

After each successful attestation, the verifier schedules the next poll via `call_later(quote_interval, invoke_get_quote, agent, mb_policy, runtime_policy, ...)`. This callback sits in the IOLoop's timer queue for `quote_interval` seconds (180s), holding references to the agent dict, mb_policy, and runtime_policy objects. These objects can't be garbage collected until the callback fires.

Note: This is the **normal happy path**, not the retry path. The `request_timeout` controls how long the HTTP request waits; the `quote_interval` controls how long the callback holds objects between polls. With 14 agents, this means 14 pending callbacks each holding a few KB — negligible on its own. However, the repeated allocation and deallocation of these callback closures across 11,200 cycles contributes to memory fragmentation and COW page dirtying.

**Cause 4: Python's pymalloc allocator never returns memory to the OS**

Python's `pymalloc` allocator requests memory from the OS in arenas but **rarely returns it** — even after objects are garbage collected, the RSS stays high because arenas aren't released back to the OS. This means the COW growth is one-directional: once a page is dirtied, it stays private even if the objects on it are freed. Over 11,200 cycles, this ratchet effect drives RSS steadily upward.

Note: IMA is not enabled in this deployment, so IMA runtime policy loading (which can be 1-10MB per agent per cycle) is not a factor here. If IMA were enabled, it would dramatically accelerate the growth.

### 10.4. The Core Problem: 8 Workers for 14 Agents

14 agents distributed across 8 workers via static round-robin means most workers handle 1-2 agents each. The workers are nearly idle, yet each gradually consumes ~250MB as COW pages are dirtied. This deployment uses `db_pool_sz_ovfl = 20,30` (50 connections per worker; keylime default is 15 per worker).

| Resource | 8 Workers (after COW divergence) | 1 Worker | Savings |
|---|---|---|---|
| Pod RSS (observed over 40h) | ~2000 MB | ~250-350 MB (estimated) | ~1.6-1.7 GB |
| DB connections (max) | 400 | 50 | 350 connections |
| IOLoop instances | 8 | 1 | 7 idle event loops |
| COW page dirtying | 8 workers × per-cycle allocations = rapid divergence | No fork = no COW = no divergence | Eliminates primary growth mechanism |

### 10.5. Recommended Config Changes

| Parameter | Current | Recommended | Impact |
|---|---|---|---|
| `num_workers` | 8 | 1 | Eliminates ~1.75 GB baseline RSS. Single biggest win. 14 agents don't need 8 workers. |
| `request_timeout` | 30 | 10 | Agents respond in 700ms. 10s is generous. Reduces connection hold time by 3x. |
| `quote_interval` | 180 | 180 | Fine — 3 minutes is reasonable for 14 agents. |
| CPU Request / Limit | 800m / 1000m | 200m / 500m | With 1 worker, far less CPU needed. |
| Memory Request / Limit | 4Gi / 8Gi | 512Mi / 1Gi | With 1 worker and 14 agents, 1Gi is generous. If growth continues past this, confirms a genuine leak. |
| `db_pool_sz_ovfl` | 20,30 | 5,10 | 14 agents need at most a few concurrent DB queries. |

### 10.6. Diagnostic Commands

To confirm the root cause on a running verifier pod:

```bash
# Check RSS per worker process
ps aux | grep keylime | grep -v grep | awk '{print $2, $6/1024 "MB", $11}'

# Monitor RSS growth over time (run every 10 minutes)
while true; do
    echo "$(date): $(ps -o pid,rss,vsz,comm -C python3 --no-headers | awk '{printf "%s %dMB ", $1, $2/1024}')"
    sleep 600
done
```

If RSS still grows past 500MB with 1 worker over 40 hours, that confirms a genuine memory leak in the per-cycle code path (policy loading or SQLAlchemy session handling) that needs upstream investigation.

### 10.7. Python Memory Allocator Behavior

As noted in Cause 4 above, Python's `pymalloc` allocator almost never returns memory to the OS. Once RSS grows, it stays — even after garbage collection frees the Python objects. The OS-level RSS is a high-water mark, not a reflection of live object usage.

This means:
- Periodic RSS growth is expected in any long-running Python process
- The rate of growth depends on peak allocation per cycle × fragmentation
- The only ways to reclaim OS memory are: restart the process, or reduce peak allocation per cycle

For production deployments, a K8s `livenessProbe` with a memory threshold or a periodic pod restart schedule (e.g., every 24 hours during a maintenance window) is a pragmatic mitigation.

---

## 11. Push Mode — Comparative Assessment

### 11.1. Architectural Differences

In push mode, the attestation flow is inverted: agents push evidence to the verifier instead of the verifier polling agents. This changes almost every scalability and HA characteristic.

| Pull Mode Characteristic | Push Mode Equivalent |
|---|---|
| Verifier creates unbounded concurrent outbound coroutines | Agents send inbound HTTP requests — Tornado's worker model naturally handles concurrency |
| 60s default timeout holds outbound connections open | Verifier responds immediately (202 Accepted), verifies asynchronously. No long-held outbound connections |
| Thundering herd on startup (verifier polls all agents at once) | No startup burst — agents push at their own pace |
| Memory bloat from slow agents holding coroutines | No outbound connections to hold. Memory bounded by inbound request handling |
| Retry loop keeps agent dict + policy in memory | No retry loop — if an agent doesn't push, the verifier does nothing (event-driven timeout via `push_agent_monitor`) |
| No backpressure mechanism | Built-in backpressure: 429 Too Many Requests (rate limiting per agent), 503 Service Unavailable with Retry-After (all workers busy) |
| Per-agent TLS context management (mTLS to each agent) | Agents authenticate via PoP bearer tokens. No per-agent TLS context |
| No per-agent latency tracking | Attestation records track stage transitions and timing. Latency implicitly visible |

### 11.2. Push Mode Built-In Safety Mechanisms

Push mode has several safety mechanisms that pull mode completely lacks:

**Dedicated web workers:** The `dedicated_web_workers` config (default 25%) reserves a fraction of workers for request handling while others do CPU-bound verification. This prevents verification load from blocking new requests.

**Per-agent rate limiting:** `quote_interval` enforces minimum time between attestations per agent. If an agent pushes too soon, the verifier returns 429 with a `Retry-After` header.

**Async verification:** The verifier sends 202 Accepted immediately after receiving evidence, then verifies in a background task. The agent doesn't wait for verification to complete.

**Event-driven timeout detection:** `push_agent_monitor` schedules a per-agent `call_later` callback. If no attestation arrives within `quote_interval × 5`, the agent is marked failed. No continuous polling loop, no DB scanning.

**Verification timeout:** A configurable cutoff prevents runaway CPU from malicious or oversized evidence. Default: 3× average verification time.

### 11.3. Push Mode Fitness Scores

| Dimension | Pull (Raw) | Push (Raw) | Delta | Why |
|---|---|---|---|---|
| Scalability | 3/10 | 7/10 | +4 | No unbounded coroutines. Built-in rate limiting. Tornado handles inbound concurrency naturally. Dedicated worker reservation. |
| HA | 5/10 | 6/10 | +1 | State still in DB (good). But agents must know the verifier endpoint — if verifier fails, agents can't push until failover completes. No built-in redirect. |
| Observability | 3/10 | 5/10 | +2 | Attestation records track stage, timing, and evaluation. `last_received_quote` is set. But still no aggregated latency metrics. |
| Operational Safety | 2/10 | 6/10 | +4 | Built-in backpressure (429, 503 with Retry-After). Verification timeout prevents runaway CPU. No thundering herd. Event-driven timeout detection. |
| **Overall** | **3/10** | **6/10** | **+3** | Push mode is architecturally better suited for scale |

### 11.4. Push Mode with OMC Integration

| Dimension | Pull (OMC) | Push (OMC) | Why Push is Better |
|---|---|---|---|
| Scalability | 6/10 | 8/10 | OMC hash ring for agent distribution + push mode's natural concurrency control = strong combination |
| HA | 7/10 | 7/10 | Same K8s Lease wrapper needed. Push adds a wrinkle: agents need to discover the new verifier endpoint after failover. K8s Service (stable VIP) is the natural solution. |
| Observability | 5/10 | 6/10 | Attestation records give OMC more data to work with |
| Operational Safety | 5/10 | 7/10 | Built-in backpressure means OMC doesn't need to compensate for missing safety nets |
| **Overall** | **6/10** | **7/10** | Push mode's built-in safety nets reduce the OMC wrapper burden |

### 11.5. Push Mode with Upstream Changes

| Dimension | Pull (OMC+Upstream) | Push (OMC+Upstream) |
|---|---|---|
| Scalability | 8/10 | 9/10 |
| HA | 8/10 | 8/10 |
| Observability | 7/10 | 7/10 |
| Operational Safety | 7/10 | 8/10 |
| **Overall** | **8/10** | **8/10** |

Scores narrow significantly at the top because upstream changes (semaphore, health endpoint, latency tracking) close the gaps that pull mode has. Push mode still leads in Scalability (9 vs 8) and Operational Safety (8 vs 7), but the gap shrinks from 3 points overall to less than 1.

### 11.6. Scale Ceilings — Push vs Pull (No IMA)

These ceilings assume IMA is not enabled. With IMA enabled, pull mode ceilings drop significantly (see section 9.11 for IMA-specific numbers).

| Integration Level | Pull Ceiling (No IMA) | Push Ceiling (No IMA) | Why |
|---|---|---|---|
| Raw keylime | ~200 agents | ~500 agents | Push has no unbounded coroutines, built-in rate limiting |
| OMC config + wrappers | ~1,000 agents (partitioned) | ~2,000 agents (partitioned) | Push's backpressure means each partition handles more agents safely |
| OMC + upstream changes | ~5,000+ agents | ~8,000+ agents | Push's CPU-bound verification is the bottleneck, not memory/connections |

### 11.7. Push Mode HA Consideration

In pull mode, the verifier initiates contact — agents don't need to know which verifier pod is active. In push mode, agents must know where to push. After a failover, agents need to discover the new verifier endpoint.

Options:

| Approach | Complexity | Recommended |
|---|---|---|
| K8s Service (stable VIP) that routes to whichever pod holds the lease | Low | Yes — natural K8s approach, transparent to agents |
| OMC updates agent config on failover | High | No — slow, complex, error-prone |
| Agent retries against a known endpoint | Low | Yes — works if K8s Service handles routing |

Using a K8s Service as a stable VIP makes push mode HA equivalent to pull mode HA from the agent's perspective.

### 11.8. The 14-Agent Memory Problem Would Not Exist in Push Mode

The observed memory growth in pull mode (section 10) is driven by the continuous polling loop across multiple forked workers, each dirtying memory through per-cycle allocations over thousands of poll cycles. In push mode, this entire mechanism is absent:

- No outbound polling loop — no per-cycle allocations by the verifier
- No `call_later` callbacks holding agent dicts and policies for 180s
- No need for many workers — push mode's Tornado server handles 14 inbound requests trivially with 1-2 workers
- Verification is triggered by inbound requests, not by a continuous loop — memory is allocated on-demand and freed after each request

The same 14 agents in push mode with 1-2 workers would likely stabilize at ~250-350MB with no continuous growth.

---

## 12. `num_workers` Config Ignored — 32× Memory Multiplier Bug

### 12.1. Discovery

During live investigation of the `eric-omc-ra-verifier` pod (14 agents, 20 hours uptime), `kubectl top` reported **1,767 MiB** memory usage. Process inspection inside the container revealed **35 keylime_verifier processes** (1 entry wrapper + 1 parent + 1 Manager + 32 workers) despite `num_workers = 1` in the config file.

```
# omc_verifier.conf
num_workers = 1

# Actual process tree inside the pod
PID 13 (PPID=1)  — entry wrapper           RSS:     2 MB
PID 14 (PPID=13) — main parent             RSS:   117 MB
PID 16 (PPID=14) — multiprocessing.Manager RSS:    99 MB  (8 threads)
PIDs 24-55        — 32 tornado workers      RSS: 97-134 MB each
Total keylime RSS: 3,781 MB
```

### 12.2. Root Cause

The new `Server` base class (`keylime/web/base/server.py`) provides a `_set_option()` DSL for wiring config values to server attributes. The `__worker_count` attribute is initialized to `0` at line 210, and the `worker_count` property falls back to `multiprocessing.cpu_count()` when it's `0` or `None`:

```python
# keylime/web/base/server.py, line 210
self.__worker_count: Optional[int] = 0

# keylime/web/base/server.py, lines 605-611
@property
def worker_count(self) -> int:
    if self.__worker_count == 0 or self.__worker_count is None:
        return multiprocessing.cpu_count()  # ← fallback: returns 32 on this node
    else:
        return self.__worker_count
```

`VerifierServer._setup()` (`keylime/web/verifier_server.py`, line 164) **never calls `_set_option("worker_count", ...)`** to wire the `num_workers` config value:

```python
# keylime/web/verifier_server.py, lines 164-172
def _setup(self) -> None:
    self._set_component("verifier")
    self._use_config("verifier")
    self._set_operating_mode(from_config="mode", fallback="pull")
    self._set_bind_interface(from_config="ip")
    self._set_http_port(value=None)
    self._set_https_port(from_config="port")
    self._set_max_upload_size(from_config="max_upload_size")
    self._set_default_ssl_ctx()
    # MISSING: self._set_option("worker_count", from_config=("num_workers", int))
```

The old tornado code path (`cloud_verifier_tornado.py`, line 2700) correctly reads `config.getint("verifier", "num_workers")` and only falls back to `cpu_count()` when the value is `<= 0`. The new `Server` base class migration lost this wiring.

`RegistrarServer._setup()` has the same gap — no `worker_count` is set, so the registrar also spawns `cpu_count()` workers. The registrar pod confirmed this: 32+ worker processes, 594 MB total.

### 12.3. Why `cpu: 1` Kubernetes Limit Doesn't Help

Kubernetes CPU limits set CFS bandwidth throttling (`cpu.max`), which limits CPU *time* but does **not** restrict CPU *visibility*:

```
# Inside the container
CPUs visible in /proc/cpuinfo: 32
cpuset.cpus.effective: 0-31        ← all 32 host CPUs visible
cpu.max: 100000 100000             ← 1 CPU bandwidth (throttling only)
nproc: 32
```

Python's `multiprocessing.cpu_count()` calls `os.sched_getaffinity(0)`, which returns all 32 CPUs because the cpuset is unrestricted. The CFS quota is invisible to this syscall.

### 12.4. Impact

| Metric | Expected (`num_workers=1`) | Actual (32 workers) | Multiplier |
|---|---|---|---|
| Worker processes | 1 | 32 | 32× |
| Baseline RSS | ~250-350 MB | ~3,781 MB | ~11-15× |
| DB connection pool (max) | 50 | 1,600 | 32× |
| COW page dirtying rate | None (no fork) | 32 workers diverging | N/A |

With 14 agents distributed round-robin across 32 workers, most workers are idle (~97 MB each) but still consume memory for the Python runtime, loaded modules (SQLAlchemy, Tornado, cryptography), and their DB connection pool. The active workers (handling 1-2 agents each) grow to 120-134 MB.

### 12.5. Workarounds Without Code Changes

| Option | Mechanism | Requires | Complexity |
|---|---|---|---|
| `PYTHON_CPU_COUNT=1` env var | Overrides `os.cpu_count()` | Python ≥ 3.13 (container has 3.14 ✅) | **Lowest** |
| `taskset -c 0 keylime_verifier` | Restricts CPU affinity mask | `taskset` binary in container ✅ | Low |
| Guaranteed QoS cpuset pinning | K8s assigns exclusive cpuset | kubelet `cpu-manager-policy=static` + requests==limits | Medium |

**Recommended:** Add `PYTHON_CPU_COUNT=1` as an environment variable in the deployment spec. This requires only a pod restart — no image rebuild, no kubelet changes, no command modification.

```yaml
env:
  - name: PYTHON_CPU_COUNT
    value: "1"
```

### 12.6. Upstream Fix

One line in `VerifierServer._setup()`:

```python
self._set_option("worker_count", from_config=("num_workers", int))
```

The same fix is needed in `RegistrarServer._setup()`. The `_set_option()` DSL and the `__worker_count` attribute already exist — only the wiring is missing.

### 12.7. Relationship to Other Findings

This bug is the **primary driver** of the memory growth observed in Section 10. The 40-hour growth from ~250 MB to ~2,000 MB is almost entirely explained by 32 forked workers gradually dirtying their copy-on-write pages (Section 10.3, Cause 1). With `num_workers=1`, the COW mechanism is eliminated entirely (no fork), and the expected steady-state memory drops to ~250-350 MB.

The policy cache DictProxy leak (discovered during this investigation) and the missing `scoped_session.remove()` are secondary contributors that would cause slower growth even with 1 worker, but the 32× worker multiplier is what made the memory consumption visible at 1.7 GB in 20 hours.

---

## Glossary

| Acronym | Full Form |
|---|---|
| AIK | Attestation Identity Key — a TPM key used to sign attestation quotes |
| AK | Attestation Key — alias for AIK in newer TPM 2.0 terminology |
| API | Application Programming Interface |
| AST | Abstract Syntax Tree |
| CPU | Central Processing Unit |
| DB | Database |
| EK | Endorsement Key — a TPM's unique, manufacturer-provisioned identity key |
| FIFO | First In, First Out — a queue ordering strategy |
| HA | High Availability |
| HMAC | Hash-based Message Authentication Code |
| HTTP | Hypertext Transfer Protocol |
| HTTPS | Hypertext Transfer Protocol Secure (HTTP over TLS) |
| IAK | Initial Attestation Key — a device identity key (DevID) |
| IDevID | Initial Device Identifier — an IEEE 802.1AR device identity certificate |
| IMA | Integrity Measurement Architecture — a Linux kernel subsystem that measures file integrity |
| IOLoop | Input/Output Loop — Tornado's asynchronous event loop |
| IPC | Inter-Process Communication |
| JSON | JavaScript Object Notation |
| K8s | Kubernetes — container orchestration platform |
| MB | Measured Boot — a boot process where each stage is measured into TPM PCRs |
| mTLS | Mutual TLS — TLS where both client and server authenticate with certificates |
| OMC | Operations Management Controller — the orchestration layer managing keylime components |
| OOM | Out of Memory — a condition where a process exceeds available memory and is killed by the kernel |
| p95 | 95th Percentile — a statistical measure indicating the value below which 95% of observations fall |
| PCR | Platform Configuration Register — a TPM register that stores integrity measurements |
| PID | Process Identifier |
| PR | Pull Request |
| REST | Representational State Transfer — an architectural style for web APIs |
| RSS | Resident Set Size — the portion of a process's memory held in RAM |
| SPOF | Single Point of Failure — a component whose failure causes the entire system to stop functioning |
| SQL | Structured Query Language |
| SSL | Secure Sockets Layer (predecessor to TLS, term still used in code) |
| TLS | Transport Layer Security — cryptographic protocol for secure communication |
| TPM | Trusted Platform Module — a hardware security chip for cryptographic operations and secure key storage |
| TTL | Time to Live — a duration after which cached data expires |
| UUID | Universally Unique Identifier |
| VIP | Virtual IP — a stable IP address that routes to whichever backend is active |
| ORM | Object-Relational Mapping — a technique for querying databases using programming language objects (e.g., SQLAlchemy) |
| PoP | Proof of Possession — an authentication mechanism where the client proves it holds a secret token |
