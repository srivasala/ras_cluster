# Verifier Pod Memory Leak Investigation

**Date:** 2026-04-15  
**Namespace:** `lcmlicense-ci`  
**Pod:** `eric-omc-ra-verifier-586bbfc794-b8j8b`  
**Image:** `eric-omc-ra-verifier:2.12.0-14`  
**Pod Age:** ~20 hours (restarted 2026-04-14T11:59:18Z)

---

## Executive Summary

The verifier pod is consuming **1.82 GB** (cgroup: 1.91 GB) and growing, with only **14 agents** in `GET_QUOTE` state. Three root causes were identified, ranked by impact:

| # | Issue | Severity | Impact |
|---|-------|----------|--------|
| 1 | `num_workers` config ignored — 32 workers spawned instead of 1 | **CRITICAL** | 32× memory multiplier |
| 2 | Policy cache leaks `DictProxy` objects via `multiprocessing.Manager` | **HIGH** | Unbounded growth per attestation cycle |
| 3 | `db_manager.session_context()` missing `scoped_session.remove()` | **MEDIUM** | SQLAlchemy identity map accumulation |

---

## Evidence

### 1. CRITICAL: Worker Count Misconfiguration (32 workers instead of 1)

**Config says `num_workers = 1`, but 32 worker processes are running.**

```
# From omc_verifier.conf
num_workers = 1
```

```
# Actual process count inside the pod
keylime_verifier processes: 35
  PID 13 (PPID=1)  — entry point wrapper          RSS:     2 MB
  PID 14 (PPID=13) — main verifier parent          RSS:   117 MB
  PID 16 (PPID=14) — multiprocessing.Manager       RSS:    98 MB  (8 threads)
  PIDs 24-55        — 32 tornado worker processes   RSS: 97-131 MB each
```

```
# Total RSS across all keylime_verifier processes
Total keylime RSS: 3,781 MB
```

```
# Container cgroup memory
Current:  1,906,606,080 bytes (1.78 GiB)
Limit:    8,589,934,592 bytes (8.00 GiB)
```

**Root cause in code:** `VerifierServer._setup()` (`keylime/web/verifier_server.py:164`) never calls a method to set `__worker_count` from the `num_workers` config value. The base class `Server` initializes `__worker_count = 0`, and the `worker_count` property falls back to `multiprocessing.cpu_count()`:

```python
# keylime/web/base/server.py:605-611
@property
def worker_count(self) -> int:
    if self.__worker_count == 0 or self.__worker_count is None:
        return multiprocessing.cpu_count()  # Returns 32 on this node
    else:
        return self.__worker_count
```

The node has **32 CPUs** visible to the container (no CPU cgroup cpuset restriction):
```
$ cat /proc/cpuinfo | grep processor | wc -l
32
```

**Impact:** Each worker process consumes ~100-134 MB RSS. With `num_workers=1`, only 1 worker should exist, reducing total memory from ~3.8 GB to ~330 MB (parent + Manager + 1 worker).

**Confirmation:** The registrar pod exhibits the same pattern — 32+ worker processes despite `num_workers` config, consuming 594 MB total.

### 2. HIGH: Policy Cache DictProxy Leak

**File:** `keylime/shared_data.py`

The policy cache functions create nested `manager.manager.dict()` proxy objects that are never garbage collected by the Manager server process:

```python
# shared_data.py:396 — cache_policy()
policy_cache[agent_id] = manager.manager.dict()  # New DictProxy every time

# shared_data.py:454 — cleanup_agent_policy_cache()
policy_cache[agent_id] = manager.manager.dict()  # Another new DictProxy on cleanup

# shared_data.py:479 — initialize_agent_policy_cache()
policy_cache[agent_id] = manager.manager.dict()  # Yet another on init
```

These are called on every attestation cycle via `verifier_read_policy_from_cache()` → `initialize_agent_policy_cache()` → `cleanup_agent_policy_cache()` → `cache_policy()`.

**Leak rate calculation:**
- `quote_interval = 180` seconds
- 14 agents × 1 cycle per 180s = ~4.7 attestation cycles/minute
- Each cycle can create 1-3 orphaned `DictProxy` objects
- Over 20 hours: ~5,600 cycles × ~1-3 DictProxy objects = 5,600-16,800 leaked proxies

**Evidence:** PID 16 (Manager server, 8 threads) has RSS of **101 MB** and VmSize of **887 MB** — disproportionately large for a Manager that should only hold small policy strings (217 bytes each per DB query).

**Irony:** The codebase already has a `FlatDictView` class specifically designed to avoid nested `DictProxy` issues, and `get_or_create_dict()` correctly returns a `FlatDictView`. But the policy cache functions bypass this by directly calling `manager.manager.dict()`.

### 3. MEDIUM: Missing `scoped_session.remove()` in ORM Session Context

**File:** `keylime/models/base/db.py:167-179`

```python
# db_manager.session_context() — MISSING finally block
def session_context(self, session=None):
    if session:
        yield session
        return
    session = self.session()
    try:
        yield session
        session.commit()
    except:
        session.rollback()
        raise
    # No finally: self._scoped_session.remove()
```

Compare with the older `keylime_db.SessionManager.session_context()` which properly cleans up:

```python
# keylime/db/keylime_db.py:119-140 — HAS finally block
def session_context(self, engine):
    session = self.make_session(engine)
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        if self._scoped_session is not None:
            self._scoped_session.remove()  # ← Proper cleanup
```

The web request handler (`action_handler.py`) does call `db_manager.remove_session()` after each HTTP request, which mitigates this for HTTP-triggered code paths. However, background code paths (e.g., `tpm_engine.py` calling `AuthSession` methods) accumulate objects in the SQLAlchemy identity map without cleanup.

---

## Deployment Snapshot

### Pod Resources
| Resource | Request | Limit | Current |
|----------|---------|-------|---------|
| CPU | 800m | 1 | 67m |
| Memory | 4Gi | 8Gi | 1,767 Mi (and growing) |

### Database State
| Table | Rows | Size |
|-------|------|------|
| verifiermain | 14 | 504 kB |
| allowlists | 26 | 104 kB |
| sessions | 0 | 24 kB |
| attestations | 0 | 8 kB |

- All 14 agents in `GET_QUOTE` (state 3) with `verifier_id = default`
- IMA policies are tiny: 217 bytes each
- 15 active DB connections (1 active, 14 idle)
- `database_pool_sz_ovfl = 20,30` (pool size 20, overflow 30)

### Verifier Configuration
| Setting | Value | Notes |
|---------|-------|-------|
| `num_workers` | 1 | **Ignored** — 32 workers spawned |
| `quote_interval` | 180 | Seconds between attestation cycles |
| `mode` | *(empty)* | Falls back to `pull` |
| `database_pool_sz_ovfl` | 20,30 | Per-worker pool; 32 workers × 20 = 640 potential connections |
| `max_retries` | 3 | |
| `retry_interval` | 8 | |

### Process Memory Distribution (Top 10 by RSS)
| PID | PPID | RSS (MB) | VmSize (MB) | Threads | Role |
|-----|------|----------|-------------|---------|------|
| 55 | 14 | 131 | 309 | 3 | Worker (active, handling agents) |
| 52 | 14 | 130 | 381 | 4 | Worker (active, handling agents) |
| 48 | 14 | 130 | 237 | 2 | Worker (active, handling agents) |
| 51 | 14 | 128 | 235 | 2 | Worker (active, handling agents) |
| 49 | 14 | 127 | 236 | 2 | Worker (active, handling agents) |
| 53 | 14 | 126 | 235 | 2 | Worker (active, handling agents) |
| 50 | 14 | 121 | 163 | 1 | Worker (idle) |
| 43 | 14 | 119 | 162 | 1 | Worker (idle) |
| 14 | 13 | 117 | 147 | 1 | Main parent process |
| 16 | 14 | 99 | 866 | 8 | multiprocessing.Manager server |

Workers with >1 thread and higher RSS are actively handling agent attestation loops. Workers with 1 thread and ~97-99 MB RSS are idle (no agents assigned via round-robin).

---

## Recommendations

### Immediate Fix: Reduce Worker Count Without Code Changes

The bug: `VerifierServer._setup()` never wires the `num_workers` config value to the base class `__worker_count`. The fallback calls `multiprocessing.cpu_count()`, which returns 32 because the container sees all host CPUs.

**Why `cpu: 1` limit doesn't help:** Kubernetes CPU limits set CFS bandwidth throttling (`cpu.max = 100000/100000`), which limits CPU *time* but does NOT restrict CPU *visibility*. The container still sees all 32 host CPUs via `cpuset.cpus.effective = 0-31`, `/proc/cpuinfo`, and `sched_getaffinity()`.

Three workarounds are available, **without any Keylime code changes:**

#### Option 1: `PYTHON_CPU_COUNT` env var (Recommended — simplest)

Python 3.13+ supports the `PYTHON_CPU_COUNT` environment variable, which overrides `os.cpu_count()` and `os.process_cpu_count()`, both of which `multiprocessing.cpu_count()` delegates to. The container runs **Python 3.14** (`libpython3.14.so.1.0` found in the PyInstaller bundle), so this works.

**Apply immediately via kubectl:**
```bash
kubectl -n lcmlicense-ci set env deployment/eric-omc-ra-verifier PYTHON_CPU_COUNT=1
```

**Or via Helm values / deployment spec:**
```yaml
env:
  - name: PYTHON_CPU_COUNT
    value: "1"
```

This triggers a rolling restart. No image rebuild needed.

#### Option 2: `taskset` CPU affinity wrapper

Wrap the process launch with `taskset` to restrict the CPU affinity mask. All child processes inherit the restricted affinity, so `multiprocessing.cpu_count()` → `os.sched_getaffinity(0)` returns the pinned set.

**In the deployment spec, modify the command:**
```yaml
command:
  - /usr/bin/stdout-redirect
  - -container=eric-omc-ra-verifier
  - -service-id=eric-omc-ra-verifier
  - -redirect=stdout
  - -format=json
  - --
  - taskset
  - "-c"
  - "0"                # Pin to CPU 0 → cpu_count() returns 1
  - keylime_verifier
```

`taskset` is available in the container (verified: `taskset -p 1` works). For 2 workers, use `"0,1"` instead of `"0"`.

#### Option 3: Guaranteed QoS with static CPU manager

If the kubelet has `cpu-manager-policy=static`, setting CPU requests equal to limits (integer values) triggers exclusive cpuset assignment:

```yaml
resources:
  requests:
    cpu: "1"       # Must be integer, must equal limit
    memory: 4Gi
  limits:
    cpu: "1"       # Must be integer, must equal limit
    memory: 8Gi
```

**Caveat:** Requires `cpu-manager-policy=static` on the kubelet AND Guaranteed QoS (requests == limits for ALL containers in the pod, including init containers). The current pod has `cpu: 800m` request vs `cpu: 1` limit — these don't match.

**Check cluster support:**
```bash
kubectl get configmap kubelet-config -n kube-system -o yaml | grep cpuManager
```

#### Comparison

| Option | Requires | Image Rebuild? | Complexity |
|--------|----------|----------------|------------|
| `PYTHON_CPU_COUNT` env var | Python ≥ 3.13 ✅ | No | **Lowest** |
| `taskset` wrapper | `taskset` in container ✅ | No | Low |
| Guaranteed QoS cpuset | kubelet `static` policy | No | Medium |

#### Verification after applying

```bash
# After pod restarts, check process count (expect 4: entry + parent + Manager + 1 worker)
kubectl -n lcmlicense-ci exec -it <new-pod> -- sh -c '
count=0
for pid in /proc/[0-9]*/status; do
  name=$(grep "^Name:" $pid 2>/dev/null | awk "{print \$2}")
  if [ "$name" = "keylime_verifie" ]; then count=$((count + 1)); fi
done
echo "keylime_verifier processes: $count"
'

# Check memory (expect ~250-350 MB instead of 1,767 MB)
kubectl -n lcmlicense-ci top pods | grep verifier
```

---

### Code Fixes Required

1. **Wire `num_workers` config to `worker_count`** — Add to `VerifierServer._setup()`:
   ```python
   def _setup(self) -> None:
       ...
       self._set_option("worker_count", from_config="num_workers")
   ```

2. **Fix policy cache DictProxy leak** — Replace `manager.manager.dict()` calls in `cache_policy()`, `cleanup_agent_policy_cache()`, and `initialize_agent_policy_cache()` with the existing `FlatDictView` pattern using composite keys.

3. **Add `finally` block to `db_manager.session_context()`** — Add `self._scoped_session.remove()` in a `finally` block to match the pattern in `keylime_db.SessionManager.session_context()`.

### Projected Impact of Fixes

| Fix | Memory Saved | Stops Growth? |
|-----|-------------|---------------|
| Worker count (1 instead of 32) | ~3.1 GB immediately | Reduces growth rate 32× |
| Policy cache DictProxy fix | Stops Manager bloat | Yes |
| Session context fix | Prevents identity map growth | Yes |

With all three fixes, expected steady-state memory for 14 agents at `quote_interval=180` should be **~250-350 MB** total.
