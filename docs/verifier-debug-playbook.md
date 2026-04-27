# Keylime Verifier Memory Investigation Playbook

A step-by-step debug playbook for investigating RSS memory growth in the Keylime verifier pod. This documents the exact investigation path used to diagnose the `eric-omc-ra-verifier` pod in `lcmlicense-ci`.

---

## Phase 1: Establish the Baseline

### Step 1.1 — Identify the pod and its age

```bash
kubectl -n lcmlicense-ci get pods | grep -i verifier
```

**What to look for:** Pod age, restart count, status. A pod running for 20h with no restarts but growing memory suggests a slow leak, not a crash loop.

**Our finding:**
```
eric-omc-ra-verifier-586bbfc794-b8j8b   1/1   Running   0   20h
database-pg-verifier-0                   1/1   Running   0   4d21h
```

### Step 1.2 — Check current resource consumption

```bash
kubectl -n lcmlicense-ci top pods | grep -i verifier
```

**What to look for:** Compare memory usage against the number of agents. Is it proportional?

**Our finding:**
```
database-pg-verifier-0                   16m    124Mi
eric-omc-ra-verifier-586bbfc794-b8j8b    67m    1767Mi   ← 1.7 GB for 14 agents
```

### Step 1.3 — Get pod resource limits and configuration

```bash
kubectl -n lcmlicense-ci describe pod eric-omc-ra-verifier-586bbfc794-b8j8b
```

**What to look for:**
- Resource requests/limits (memory limit = OOMKill threshold)
- Container command and args (how the process is launched)
- Environment variables (config overrides)
- Restart count and events

**Our finding:**
```
Limits:   cpu: 1, memory: 8Gi
Requests: cpu: 800m, memory: 4Gi
Command:  /usr/bin/stdout-redirect ... -- keylime_verifier
Env:      KEYLIME_VERIFIER_CONFIG=/etc/keylime/omc_verifier.conf
```

### Step 1.4 — Read the application config

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- cat /etc/keylime/omc_verifier.conf
```

**What to look for:** Key settings that affect memory: `num_workers`, `quote_interval`, `database_pool_sz_ovfl`, `mode`, `max_upload_size`.

**Our finding:**
```ini
num_workers = 1
quote_interval = 180
database_pool_sz_ovfl = 20,30
mode =                          # empty → falls back to "pull"
```

---

## Phase 2: Map the Process Tree Inside the Container

This is the most critical phase. Containers often run multiple processes, and `kubectl top` shows the aggregate. You need to see what's *inside*.

### Step 2.1 — List all processes with RSS

Minimal containers often lack `ps`. Use `/proc` directly:

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c '
for pid in /proc/[0-9]*/status; do
  pidnum=$(echo $pid | grep -o "[0-9]*")
  name=$(grep "^Name:" $pid 2>/dev/null | awk "{print \$2}")
  ppid=$(grep "^PPid:" $pid 2>/dev/null | awk "{print \$2}")
  rss=$(grep "^VmRSS:" $pid 2>/dev/null | awk "{print \$2}")
  vmsize=$(grep "^VmSize:" $pid 2>/dev/null | awk "{print \$2}")
  threads=$(grep "^Threads:" $pid 2>/dev/null | awk "{print \$2}")
  if [ -n "$rss" ]; then
    echo "PID=$pidnum PPID=$ppid Name=$name RSS=${rss}kB VmSize=${vmsize}kB Threads=$threads"
  fi
done | sort -t= -k5 -n -r
'
```

**What to look for:**
- How many processes exist? Does it match `num_workers` config?
- Which process has the highest RSS?
- What is the parent-child relationship (PPID)?
- Multi-threaded processes (Threads > 1) — these are often Manager servers or DB connection pools

**Our finding:**
```
35 keylime_verifier processes total:
  PID 13 (PPID=1)  — entry wrapper         2 MB
  PID 14 (PPID=13) — main parent         117 MB
  PID 16 (PPID=14) — Manager server       99 MB, 8 threads
  PIDs 24-55        — 32 workers       97-134 MB each
Total: 3,781 MB
```

**Red flag:** Config says `num_workers=1` but there are **32 worker processes**.

### Step 2.2 — Identify process roles

```bash
# Check what a specific PID is running
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c 'cat /proc/<PID>/cmdline | tr "\0" " "'
```

### Step 2.3 — Calculate total RSS

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c '
total=0
for pid in /proc/[0-9]*/status; do
  name=$(grep "^Name:" $pid 2>/dev/null | awk "{print \$2}")
  if [ "$name" = "keylime_verifie" ]; then
    rss=$(grep VmRSS $pid 2>/dev/null | awk "{print \$2}")
    total=$((total + rss))
  fi
done
echo "Total RSS: ${total} kB ($((total / 1024)) MB)"
'
```

### Step 2.4 — Check cgroup memory (what Kubernetes actually sees)

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c '
echo "Current: $(cat /sys/fs/cgroup/memory.current) bytes"
echo "Limit:   $(cat /sys/fs/cgroup/memory.max) bytes"
'
```

---

## Phase 3: Understand Why Worker Count Is Wrong

### Step 3.1 — Check CPU visibility inside the container

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c '
echo "CPUs visible in /proc/cpuinfo: $(grep -c processor /proc/cpuinfo)"
echo "cpuset effective: $(cat /sys/fs/cgroup/cpuset.cpus.effective)"
echo "cpu.max (quota/period): $(cat /sys/fs/cgroup/cpu.max)"
echo "nproc: $(nproc 2>/dev/null || echo N/A)"
echo "Affinity mask: $(taskset -p 1 2>/dev/null || echo N/A)"
'
```

**What to look for:** The difference between CPU *bandwidth* limit (`cpu.max`) and CPU *count* visibility (`cpuset.cpus.effective`, `/proc/cpuinfo`).

**Our finding:**
```
CPUs visible: 32
cpuset effective: 0-31          ← all 32 CPUs visible
cpu.max: 100000 100000          ← 1 CPU bandwidth limit (throttling, not visibility)
nproc: 32
Affinity mask: ffffffff         ← all 32 bits set
```

**Key insight:** Kubernetes `resources.limits.cpu: 1` sets `cpu.max` (CFS bandwidth throttling) but does NOT restrict `cpuset`. Python's `multiprocessing.cpu_count()` reads `sched_getaffinity()` or `/proc/cpuinfo`, both of which see 32 CPUs. The code falls back to `cpu_count()` when `num_workers` config is not wired through, so it spawns 32 workers.

### Step 3.2 — Trace the code path (read the source)

Check how the server determines worker count:

```python
# keylime/web/base/server.py
@property
def worker_count(self) -> int:
    if self.__worker_count == 0 or self.__worker_count is None:
        return multiprocessing.cpu_count()  # ← Falls back to 32
    else:
        return self.__worker_count

# keylime/web/verifier_server.py
def _setup(self) -> None:
    self._set_component("verifier")
    self._use_config("verifier")
    # ... no call to set worker_count from num_workers config!
```

---

## Phase 4: Check for Memory Leaks Within Each Worker

Even after fixing worker count, you need to verify workers aren't individually leaking.

### Step 4.1 — Compare worker RSS values

From the Phase 2 output, look at the spread:
- Idle workers (1 thread): ~97-99 MB — this is the baseline after fork
- Active workers (2+ threads): ~120-134 MB — these are handling agents

If active workers are significantly larger than idle ones, they're accumulating state.

### Step 4.2 — Check the multiprocessing.Manager server

```bash
# PID 16 in our case (the one with 8 threads, child of main parent)
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c '
echo "Manager PID 16:"
echo "  RSS: $(grep VmRSS /proc/16/status | awk "{print \$2, \$3}")"
echo "  VmSize: $(grep VmSize /proc/16/status | awk "{print \$2, \$3}")"
echo "  FDs: $(ls /proc/16/fd | wc -l)"
echo "  Sockets: $(ls -la /proc/16/fd 2>/dev/null | grep socket | wc -l)"
'
```

**Our finding:** Manager has 99 MB RSS and **866 MB VmSize** — disproportionately large. This points to leaked `DictProxy` objects in the Manager's internal registry.

### Step 4.3 — Check file descriptor counts

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- sh -c '
for pid in /proc/[0-9]*/status; do
  pidnum=$(echo $pid | grep -o "[0-9]*")
  name=$(grep "^Name:" $pid 2>/dev/null | awk "{print \$2}")
  if [ "$name" = "keylime_verifie" ]; then
    fds=$(ls /proc/$pidnum/fd 2>/dev/null | wc -l)
    echo "PID=$pidnum FDs=$fds"
  fi
done
'
```

Growing FD counts indicate connection leaks or proxy object leaks.

### Step 4.4 — Check detailed memory breakdown per process

```bash
kubectl -n lcmlicense-ci exec -it <pod> -- cat /proc/<PID>/smaps_rollup
```

**What to look for:**
- `Private_Dirty` — memory unique to this process (the real per-process cost)
- `Shared_Dirty` — copy-on-write pages modified after fork
- `Anonymous` — heap allocations (Python objects, caches)
- `Pss` — proportional share (fair accounting of shared pages)

---

## Phase 5: Check the Database Side

### Step 5.1 — Agent count and state

```bash
kubectl -n lcmlicense-ci exec -it database-pg-verifier-0 -- \
  psql -U postgres -d omc_verifier -c \
  "SELECT agent_id, operational_state, verifier_id FROM verifiermain;"
```

### Step 5.2 — Table sizes

```bash
kubectl -n lcmlicense-ci exec -it database-pg-verifier-0 -- \
  psql -U postgres -d omc_verifier -c \
  "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)), n_live_tup
   FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"
```

### Step 5.3 — Connection count

```bash
kubectl -n lcmlicense-ci exec -it database-pg-verifier-0 -- \
  psql -U postgres -d omc_verifier -c \
  "SELECT state, count(*) FROM pg_stat_activity
   WHERE datname = 'omc_verifier' GROUP BY state;"
```

**What to look for:** With `database_pool_sz_ovfl = 20,30` and 32 workers, the theoretical max is 32 × 50 = 1,600 connections. If you see connection counts climbing, that's a separate problem.

---

## Phase 6: Cross-Reference with Source Code

### Step 6.1 — Trace the worker spawning path

1. `VerifierServer.__init__()` → `_setup()` → does NOT set `__worker_count`
2. `start_multi()` → `tornado.process.fork_processes(self.worker_count)`
3. `worker_count` property → `__worker_count == 0` → `multiprocessing.cpu_count()` → 32

### Step 6.2 — Trace the attestation loop for per-cycle leaks

For pull mode:
```
activate_agents() → process_agent() → invoke_get_quote() → process_agent() [loop]
                         ↓
                  verifier_read_policy_from_cache()
                         ↓
                  initialize_agent_policy_cache()  ← creates DictProxy
                  cleanup_agent_policy_cache()     ← creates DictProxy (replaces old)
                  cache_policy()                   ← creates DictProxy
```

### Step 6.3 — Check session cleanup patterns

Compare the two session context managers:
- `keylime_db.SessionManager.session_context()` — has `finally: scoped_session.remove()` ✅
- `db_manager.session_context()` — missing `finally` block ❌

---

## Phase 7: Compare with Another Component

Use the registrar as a control group — same codebase, different workload:

```bash
kubectl -n lcmlicense-ci exec -it eric-omc-ra-registrar-647b9c77f-2wnmd -- sh -c '
for pid in /proc/[0-9]*/status; do
  pidnum=$(echo $pid | grep -o "[0-9]*")
  name=$(grep "^Name:" $pid 2>/dev/null | awk "{print \$2}")
  rss=$(grep "^VmRSS:" $pid 2>/dev/null | awk "{print \$2}")
  if [ -n "$rss" ] && [ "$rss" -gt 1000 ] 2>/dev/null; then
    echo "PID=$pidnum Name=$name RSS=${rss}kB"
  fi
done
'
```

**Our finding:** Registrar also has 32+ workers — confirms the `num_workers` config is ignored across all components, not just the verifier.

---

## Reducing Worker Count Without Code Changes

The code path is:

```python
multiprocessing.cpu_count()  →  os.sched_getaffinity(0)  →  sees 32 CPUs
```

There are **three ways** to make this return a smaller number without touching Keylime code:

### Option A: Set `cpuset` via Kubernetes (Recommended)

Restrict the CPUs visible to the container using a `cpuset`-aware configuration. This requires the `static` CPU manager policy on the kubelet:

```yaml
# Check if your cluster supports this:
# kubelet must have --cpu-manager-policy=static

# In the pod spec, set both requests AND limits to the same integer value
# to trigger "Guaranteed" QoS and cpuset pinning:
resources:
  requests:
    cpu: "1"        # Must be integer, must equal limit
    memory: 4Gi
  limits:
    cpu: "1"        # Must be integer, must equal limit
    memory: 8Gi
```

When kubelet has `cpu-manager-policy=static` and the pod is Guaranteed QoS (requests == limits for all resources), Kubernetes assigns an exclusive cpuset. Then `nproc`, `sched_getaffinity`, and `multiprocessing.cpu_count()` all return 1.

**Check if your cluster supports this:**
```bash
# On a node
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.cpu}'
# Check kubelet config
kubectl get configmap kubelet-config -n kube-system -o yaml | grep cpuManager
```

**Caveat:** This requires Guaranteed QoS (requests == limits for ALL containers in the pod, including init containers). The current pod has `cpu: 800m` request vs `cpu: 1` limit — these must match.

### Option B: Use `taskset` in the container entrypoint (Most Portable)

Wrap the process launch with `taskset` to restrict CPU affinity. This works regardless of kubelet policy:

```yaml
# In the Helm values or deployment spec, override the command:
command:
  - /usr/bin/stdout-redirect
  - -container=eric-omc-ra-verifier
  - -service-id=eric-omc-ra-verifier
  - -redirect=stdout
  - -format=json
  - --
  - taskset
  - "-c"
  - "0"              # Pin to CPU 0 only → cpu_count() returns 1
  - keylime_verifier
```

`taskset -c 0 keylime_verifier` sets the CPU affinity mask to only CPU 0. All child processes inherit this. `multiprocessing.cpu_count()` → `os.sched_getaffinity(0)` → returns `{0}` → length 1.

**Verify `taskset` is available:**
```bash
kubectl -n lcmlicense-ci exec -it <pod> -- taskset -p 1
# If this works, taskset is available
```

**For 2 workers:** `taskset -c 0,1 keylime_verifier`

### Option C: Set the `_NPROCESSORS_ONLN` environment variable (Python 3.13+ only)

Python 3.13 added support for the `PYTHON_CPU_COUNT` environment variable:

```yaml
env:
  - name: PYTHON_CPU_COUNT
    value: "1"
```

This overrides `os.cpu_count()` and `os.process_cpu_count()`, which `multiprocessing.cpu_count()` delegates to.

**Verify Python version supports this:**
```bash
# We found: libpython3.14.so.1.0 → Python 3.14 ✅
```

This is the **simplest option** for this deployment since it's Python 3.14.

### Comparison

| Option | Requires | Restart? | Scope | Complexity |
|--------|----------|----------|-------|------------|
| A: cpuset (Guaranteed QoS) | kubelet `cpu-manager-policy=static`, requests==limits | Yes | Node-level | Medium |
| B: `taskset` wrapper | `taskset` binary in container | Yes | Pod-level | Low |
| C: `PYTHON_CPU_COUNT` env var | Python ≥ 3.13 | Yes | Pod-level | **Lowest** |

### Recommended: Option C

Add to the deployment or Helm values:

```yaml
env:
  - name: PYTHON_CPU_COUNT
    value: "1"
```

This is the least invasive change. It requires a pod restart but no image rebuild, no kubelet changes, and no command modification.

To apply immediately:

```bash
kubectl -n lcmlicense-ci set env deployment/eric-omc-ra-verifier PYTHON_CPU_COUNT=1
```

This triggers a rolling restart. After restart, verify:

```bash
# Should show only a few keylime_verifier processes instead of 35
kubectl -n lcmlicense-ci exec -it <new-pod> -- sh -c '
count=0
for pid in /proc/[0-9]*/status; do
  name=$(grep "^Name:" $pid 2>/dev/null | awk "{print \$2}")
  if [ "$name" = "keylime_verifie" ]; then count=$((count + 1)); fi
done
echo "keylime_verifier processes: $count"
'
# Expected: 4 (entry + parent + Manager + 1 worker)
```
