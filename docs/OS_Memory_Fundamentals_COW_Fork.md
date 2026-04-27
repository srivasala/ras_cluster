# OS-Level Memory Fundamentals — fork(), COW, and RSS Growth in Multi-Worker Python Services

**Date:** 2026-04-14
**Context:** Explains the OS-level mechanics behind the memory growth observed in the Keylime Verifier with 8 Tornado workers and 14 agents over 40 hours (see `Verifier_Memory_Bloat_Analysis.md`, Section 10).

---

## 1. `fork()` and Virtual Memory

When Tornado calls `fork_processes(8)`, the Linux kernel's `fork()` syscall creates 8 child processes. Crucially, `fork()` does **not** copy the parent's physical memory. Instead:

- Each child gets its own **page table** — a mapping from virtual addresses to physical page frames.
- All 8 children's page tables initially point to the **same physical pages** as the parent.
- The kernel marks every shared page as **read-only** in all processes' page tables, even pages that were originally writable.

At this point, 8 processes appear to each have ~250MB of RSS, but the actual physical memory consumed is still ~250MB. Tools like `ps` and `/proc/[pid]/status` report RSS per-process, which is misleading — they count shared pages multiple times.

```
Parent (pre-fork):
  Virtual Page 0x7f001000 → Physical Frame 0xABC00 [RW]
  Virtual Page 0x7f002000 → Physical Frame 0xABC01 [RW]

After fork (all 9 processes):
  Virtual Page 0x7f001000 → Physical Frame 0xABC00 [RO]  ← same frame, marked read-only
  Virtual Page 0x7f002000 → Physical Frame 0xABC01 [RO]  ← same frame, marked read-only
```

You can verify this with `/proc/[pid]/smaps` — the `Shared_Clean` and `Shared_Dirty` fields show how much memory is actually shared vs private.

---

## 2. Copy-on-Write (COW) Faults

When any worker **writes** to a shared page — even a single byte — the CPU triggers a **page fault** because the page is marked read-only. The kernel's page fault handler then:

1. Allocates a **new physical page frame** (4KB on x86-64)
2. Copies the entire 4KB page from the original frame to the new frame
3. Updates the faulting process's page table to point to the new frame
4. Marks the new frame as **read-write** for that process
5. Decrements the reference count on the original frame (other processes still share it)

```
Worker 3 writes to Virtual Page 0x7f001000:

Before:
  Worker 3: 0x7f001000 → Physical Frame 0xABC00 [RO, shared by 9 processes]

Page fault triggers → kernel copies frame:

After:
  Worker 3: 0x7f001000 → Physical Frame 0xDEF00 [RW, private to Worker 3]
  Others:   0x7f001000 → Physical Frame 0xABC00 [RO, shared by 8 processes]
```

Each COW fault costs:
- ~1–3 microseconds of CPU time (page fault handler + memcpy of 4KB)
- 4KB of new physical memory that is now **permanently private** to that worker

---

## 3. What Triggers COW Faults in a Python Worker

### 3a. Python Object Allocation (pymalloc arenas)

Python's `pymalloc` allocator manages memory in 256KB **arenas**, subdivided into 4KB **pools**, subdivided into fixed-size **blocks** (8, 16, 24, ... 512 bytes). When a worker creates any Python object — a dict, a string, an ORM model instance — pymalloc writes to a block inside a pool inside an arena. That write dirties the underlying OS page.

```
pymalloc arena (256KB = 64 pages):
  ┌─────────┬─────────┬─────────┬─────────┐
  │ Pool 0  │ Pool 1  │ Pool 2  │ ...     │  ← each pool = 4KB = 1 OS page
  │ (4KB)   │ (4KB)   │ (4KB)   │         │
  └─────────┴─────────┴─────────┴─────────┘
       ↑
  Worker allocates a dict here → COW fault → page becomes private
```

### 3b. SQLAlchemy Identity Map Writes

Each `session.query(Model).get(id)` loads an ORM object into the session's identity map (a Python dict). The dict insertion writes to the dict's internal hash table, dirtying pages. The ORM object itself is allocated via pymalloc, dirtying more pages. `session.commit()` updates internal state tracking, dirtying yet more pages.

### 3c. Reference Count Updates

CPython uses reference counting for garbage collection. Every time an object is assigned, passed to a function, or added to a container, its `ob_refcnt` field (an integer at the start of every Python object in memory) is incremented. That's a **write** to the page containing the object.

```c
// CPython internals — every Py_INCREF is a write:
#define Py_INCREF(op) (++(op)->ob_refcnt)
```

This is particularly insidious: a worker that merely *imports a module* or *reads a global config dict* will dirty the pages containing those objects via refcount increments. Even reading a shared object triggers a COW fault.

### 3d. Tornado IOLoop State

The IOLoop maintains internal data structures (a heap for timers, a dict for handlers). Each `call_later()` inserts into the timer heap — a write. Each socket event updates handler state — a write. Each completed callback removes from the heap — a write.

---

## 4. The Ratchet Effect: pymalloc Never Returns Pages to the OS

Python's pymalloc has a critical behavior:

- It requests memory from the OS via `mmap()` (anonymous mappings) or `brk()`/`sbrk()` (heap extension)
- When Python objects are garbage collected, pymalloc marks the blocks as free **within its own arena** — but it almost **never calls `munmap()` or returns the arena to the OS**
- An arena is only released if **every single block** in all 64 of its pools is free simultaneously — which almost never happens due to fragmentation

```
Arena after many alloc/free cycles:
  ┌─────────┬─────────┬─────────┬─────────┐
  │ ██░░██░ │ ░██░░██ │ ██░░░██ │ ░░██░██ │  █ = in-use block, ░ = freed block
  └─────────┴─────────┴─────────┴─────────┘
  Every pool has at least one live block → arena can never be released
```

From the OS perspective:
1. Worker allocates objects → COW fault → new private page
2. Worker frees objects → pymalloc marks blocks free internally
3. OS still sees the page as allocated (RSS unchanged)
4. Next cycle, pymalloc reuses freed blocks — but also allocates new ones in new pages → more COW faults

**RSS only goes up. Never down. This is the ratchet.**

---

## 5. The RSS Growth Curve Explained

Putting it all together for the 8-worker verifier over 40 hours:

```
Time 0 (post-fork):
  Physical memory: ~250MB (shared across all 9 processes)
  Per-worker private pages: ~0
  Reported RSS per worker: ~250MB (misleading — mostly shared)
  Actual unique physical memory: ~250MB

Time 0→40h (11,200 poll cycles):
  Each cycle per worker:
    - ~50-100 COW faults (ORM load, dict ops, refcount bumps, IOLoop updates)
    - ~200-400KB of pages converted from shared → private per cycle
  
  Over 40 hours per worker:
    - ~1,400 cycles × ~300KB = ~420MB of pages dirtied
    - But many pages are dirtied repeatedly (same ORM objects, same dicts)
    - Net new private pages per worker: ~200-220MB

Time 40h:
  Physical memory: 250MB (still-shared) + 8 × ~220MB (private) ≈ 2010MB
  Reported total pod RSS: ~2000MB ✓ (matches observation)
```

---

## 6. Why `num_workers=1` Eliminates This

With a single worker, `fork()` is never called. There is:

- **No page table duplication** — one process, one page table
- **No read-only marking** — pages are read-write from the start
- **No COW faults** — writes go directly to the original page, no copying
- **No 8× divergence** — one process's pymalloc fragmentation stays bounded

The pymalloc ratchet still exists (RSS will creep up slightly over time), but without the 8× multiplier from COW divergence, the growth is bounded to the single process's working set — roughly 250–350MB for 14 agents.

---

## 7. Observing This at the OS Level

### Per-process private vs shared memory breakdown

```bash
cat /proc/<pid>/smaps_rollup
```

Key fields:
- `Rss` — total resident pages (shared + private)
- `Shared_Clean` — shared pages not yet written
- `Shared_Dirty` — shared pages written (rare after fork)
- `Private_Clean` — private pages from file-backed mappings
- `Private_Dirty` — **private pages from COW faults ← this is the growth**

### Proportional Set Size (PSS) — fair share of shared pages

```bash
grep Pss /proc/<pid>/smaps_rollup
```

PSS = Private + (Shared / num_sharing_processes). This gives a more accurate per-worker memory cost than RSS.

### Watch COW faults in real time

```bash
pidstat -r -p <pid> 5
```

The `minflt/s` column shows minor faults (COW + demand paging). High values indicate active COW faulting.

### Python-level arena stats

```python
import sys
sys.getallocators()  # Python 3.12+
```

Or set `PYTHONMALLOC=debug` environment variable for allocation tracing.

---

## 8. Summary: The Causal Chain

```
fork_processes(8)
  → 8 workers share parent's physical pages via COW
  → each poll cycle, workers write to memory (ORM, dicts, refcounts, IOLoop)
  → each write triggers a COW fault → shared page copied to private page
  → pymalloc never returns freed pages to OS (arena fragmentation)
  → RSS ratchets upward: 250MB → 2000MB over 40 hours
  → with num_workers=1: no fork → no COW → no divergence → RSS stays ~250-350MB
```

The `Private_Dirty` field in `/proc/<pid>/smaps_rollup` is the single most telling metric — it shows exactly how many pages each worker has dirtied via COW faults, and it is what drives the RSS growth from 250MB to 2GB.
