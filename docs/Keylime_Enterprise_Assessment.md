# Keylime — Enterprise Adoption Assessment

## 1. License

Keylime uses the **Apache License 2.0**.

### What You Can Do

- Use keylime in a commercial product
- Modify the source code
- Distribute modified versions (including as part of a proprietary product)
- Sublicense
- Use without paying royalties

### What You Must Do

- **Include the license and NOTICE file** — ship a copy of the Apache 2.0 license with your product
- **State changes** — if you modify keylime files, note that you changed them (comment or changelog). You don't have to publish the changes, just acknowledge they were made.
- **Preserve copyright notices** — don't remove existing copyright headers from files

### What You Cannot Do

- Use the "Keylime" trademark or CNCF branding to imply endorsement of your product
- Hold the original authors liable

### Key Point

Apache 2.0 does **not** require you to open-source your modifications or your proprietary code that integrates with keylime. You can fork, modify, ship inside a commercial product, and keep changes proprietary — as long as you include the license, preserve copyright notices, and note changes.

**Note:** Keylime was originally BSD Clause-2 and was relicensed to Apache 2.0. The original BSD-licensed code is archived at `github.com/mit-ll/MIT-keylime`. Only the Apache 2.0 version is relevant.

**Disclaimer:** This is a technical summary, not legal advice. Have your legal team review the full LICENSE file for your specific commercial use case.

---

## 2. CNCF Maturity Status

Keylime was accepted into the CNCF Sandbox in September 2020. As of April 2026 — nearly 5.5 years later — it remains at Sandbox level. It has not progressed to Incubating or Graduated.

For context, CNCF Incubating requires demonstrating adoption by multiple organizations, a healthy contributor base, and conformance to CNCF governance standards. Graduated requires broad production adoption and a completed security audit.

The project is actively maintained (v7.14.1, regular releases, active Slack), but the lack of maturity progression signals that enterprise-scale production adoption has not reached the threshold CNCF requires for advancement.

### What the Codebase Reveals About Enterprise Readiness

Scalability gaps:
- No concurrency control on agent polling — unbounded coroutines scale linearly with agent count
- Exponential backoff with no delay cap (`base^ntries` with no ceiling) — misconfiguration can pin memory for 31 hours
- No pagination on registrar list endpoint — full table scan on every call
- Default `request_timeout` of 60s is 10-100x higher than needed
- `num_workers` config ignored in new Server base class — spawns `cpu_count()` workers regardless of config

HA gaps:
- No native HA support — requires custom K8s Lease wrappers with self-fencing logic
- No health or readiness endpoints on either verifier or registrar
- SharedDataManager (Python `multiprocessing.Manager`) is a single point of failure per registrar pod with no recovery mechanism
- Startup thundering herd on failover — all agents polled simultaneously

Operational gaps:
- No per-agent latency tracking
- Worker count defaults to CPU count with no config override for the registrar
- Python's pymalloc never returns memory to the OS, causing monotonic RSS growth

### Why Alternatives Don't Fully Replace Keylime

| Capability | Keylime | SPIFFE/SPIRE | Cloud Provider Attestation (Azure MAA, AWS Nitro) | Intel Trust Authority | Confidential Computing (SEV-SNP, TDX) |
|---|---|---|---|---|---|
| TPM 2.0 hardware root of trust | Yes — core design | No — software identity only | Partial — platform-specific | Yes | No — uses CPU TEE, not TPM |
| Continuous runtime attestation (IMA) | Yes — unique strength | No | No | No | No |
| Measured boot validation | Yes | No | Yes (platform-specific) | Yes | Yes (launch measurement) |
| Open source, vendor-neutral | Yes (Apache 2.0) | Yes (Apache 2.0) | No — proprietary per cloud | No — Intel proprietary | Partial — specs open, implementations vary |
| Multi-cloud / on-prem / edge | Yes | Yes | No — single cloud only | Cross-platform but Intel-centric | Hardware-dependent |
| Enterprise HA / scalability | Weak (as documented) | Strong (built-in federation, OIDC) | Managed by cloud provider | Managed service | N/A |
| Encrypted payload provisioning | Yes — built-in | No | No | No | No |

### Summary

Keylime remains the only open-source, vendor-neutral framework that combines TPM 2.0 hardware-rooted trust, continuous IMA runtime attestation, measured boot validation, and encrypted payload provisioning in a single system. Alternative solutions address adjacent concerns — SPIFFE/SPIRE provides workload identity without hardware trust anchors, cloud provider attestation services are proprietary and cloud-locked, and confidential computing protects workload isolation via CPU enclaves but does not perform continuous filesystem integrity monitoring.

For enterprise adoption, keylime should be treated as a capable attestation engine that requires significant operational scaffolding — not a turnkey HA platform. The investment in that scaffolding is justified when the requirement is continuous, hardware-rooted, vendor-neutral runtime attestation — a capability no alternative currently provides at any maturity level.

---

## 3. HA Option Assessment by Agent Scale (Pull Mode, No IMA)

### The Options

| # | Option | What It Is | Dev Effort | Operational Complexity |
|---|---|---|---|---|
| 1 | K8s Lease Wrapper | Go sidecar manages verifier lifecycle via K8s Leases. Active-standby per partition. | ~2-3 weeks | Medium |
| 2 | PostgreSQL Lock Wrapper | Same as Option 1 but uses a custom DB table instead of K8s Leases | ~3-4 weeks | High |
| 3 | Manual Switchover | Wrapper monitors and alerts, human triggers failover | ~1 week | Low dev, high ops |
| 4 | K8s Operator (CRD) | Full operator that auto-manages verifier fleet from a declarative spec | ~2-3 months | Low ops once built |

### Assessment by Scale

#### 100 Agents

- **Partitions:** 1
- **HA model:** 1:1 (1 active + 1 standby)
- **Recommended:** Option 3 (Manual) or Option 1 (Lease Wrapper)
- **Upstream changes:** None — config tuning sufficient
- **Thundering herd:** 100 concurrent requests — tolerable

#### 500 Agents

- **Partitions:** 2-3 (170-250 agents each)
- **HA model:** N+1 (2-3 active + 1 standby)
- **Recommended:** Option 1 (K8s Lease Wrapper)
- **Upstream changes:** Recommended (concurrency semaphore, backoff cap)
- **Critical:** Self-fencing mandatory. Startup staggering recommended.

#### 1,000 Agents

- **Partitions:** 3-5 (200-330 agents each)
- **HA model:** N+1 (3-5 active + 1 standby)
- **Recommended:** Option 1 (K8s Lease Wrapper)
- **Upstream changes:** Strongly recommended (semaphore, backoff cap, `/health` endpoint)
- **Critical:** Startup staggering required. Registrar caching needed. Push mode worth evaluating.

#### 5,000 Agents

- **Partitions:** 10-20 (250-500 agents each)
- **HA model:** N+1 or N+2 (10-20 active + 1-2 standby)
- **Recommended:** Option 4 (K8s Operator)
- **Upstream changes:** Mandatory (all: semaphore, backoff cap, health endpoint, startup rate limit, registrar pagination, response size limit)
- **Critical:** Push mode recommended.

#### 10,000 Agents

- **Partitions:** 20-40 (250-500 agents each)
- **HA model:** N+2 (20-40 active + 2 standby)
- **Recommended:** Option 4 (K8s Operator)
- **Upstream changes:** All mandatory. Push mode strongly recommended.
- **Note:** At this scale, evaluate whether keylime is the right tool — operational scaffolding dwarfs keylime itself.

### Summary Matrix

| Scale | Partitions | HA Option | Upstream Changes | Push Mode? | Complexity |
|---|---|---|---|---|---|
| 100 | 1 | Manual or Lease Wrapper | None | Not needed | Low |
| 500 | 2-3 | Lease Wrapper | Recommended | Not needed | Medium |
| 1,000 | 3-5 | Lease Wrapper | Strongly recommended | Worth evaluating | Medium-High |
| 5,000 | 10-20 | K8s Operator | Mandatory | Recommended | High |
| 10,000 | 20-40 | K8s Operator | Mandatory | Strongly recommended | Very High |

Option 2 (PostgreSQL Locks) is not recommended at any scale — K8s Leases provide the same semantics with less code and native tooling support.

The inflection point is ~1,000-5,000 agents — below that, the Lease wrapper is practical. Above that, the operator's upfront cost pays for itself in operational reliability.

---

## 4. Contributing to Keylime — Ways of Working

### Bug Fixes and Small Changes

1. Open a GitHub issue at [keylime/keylime/issues](https://github.com/keylime/keylime/issues)
2. Fork → clone → code → PR
3. Format code with **Black** and **isort** (enforced by pre-commit hooks and CI)
4. Squash to a single commit (subject ≤50 chars, body wrapped at 72, include `Resolves: #<issue>`)
5. CI must pass
6. A **core keylime team** member must review and approve before merge

### Significant Features or Architectural Changes

Keylime uses a **Kubernetes-style enhancement proposal process**:

1. Submit an enhancement at [keylime/enhancements](https://github.com/keylime/enhancements) — a design document describing the problem, proposed solution, and impact
2. Get community feedback (via the enhancement PR, mailing list, or Slack)
3. Once accepted, implement via PRs against the main repo

This applies to upstream changes identified in the scalability analysis (concurrency semaphore, backoff cap, health endpoints, registrar pagination) — each would likely need an enhancement proposal first.

### Communication Channels

| Channel | Use For |
|---|---|
| [CNCF Slack #keylime](https://cloud-native.slack.com/archives/C01ARE2QUTZ) | Day-to-day discussion, quick questions, coordination |
| [keylime@groups.io](mailto:keylime@groups.io) | Mailing list for proposals, decisions, maintainer discussions |
| [GitHub Issues](https://github.com/keylime/keylime/issues) | Bug reports, feature tracking |
| [GitHub Enhancements](https://github.com/keylime/enhancements) | Design proposals for significant changes |
| Monthly meeting (4th Wednesday, 16:00 UK time) | Community sync, agenda in [keylime/meetings](https://github.com/keylime/meetings) |

### Governance

- Review required from the core maintainer team for every PR — no self-merging
- Decisions by consensus among maintainers; project lead has final say on disputes
- No organization can dominate — voting is capped at 1/5 of total maintainers per organization
- Code must be Apache 2.0 licensed

### Practical Tips

- **Start with the bugs already found.** The `num_workers` config wiring bug and the missing backoff cap in `retry_time()` are clean, small PRs that build credibility with maintainers before proposing larger changes.
- **The enhancement repo is the gate for bigger items.** The concurrency semaphore, health endpoints, and registrar pagination would each need an enhancement proposal. Reference analysis findings — maintainers appreciate data-backed proposals.
- **There's already a keylime operator effort** at [keylime/attestation-operator](https://github.com/keylime/attestation-operator) — check its current state before building a separate one. Contributing to the existing operator may be more productive than building a proprietary one.

---

## 5. Testing Prerequisites for Upstream Contributions

Keylime has three layers of testing that all must pass on every PR.

### Layer 1: Style & Static Analysis (Automated)

Runs via GitHub Actions on `ubuntu-latest`:

| Check | Tool | What It Catches |
|---|---|---|
| Code formatting | **Black** + **isort** | Inconsistent formatting, import ordering |
| Linting | **pylint** | Code smells, unused imports, naming violations |
| Type checking | **mypy** + **pyright** | Type annotation errors, incompatible types |
| Pre-commit hooks | **pre-commit** | All of the above in one pass |

Run locally before pushing:
```bash
# Install pre-commit hooks (one-time)
pip install pre-commit
pre-commit install

# Run all style checks
pre-commit run --all-files
```

### Layer 2: Unit Tests (Automated)

Tests in the `test/` directory run inside a `keylime-ci` container image (includes a TPM emulator). Pure Python unit tests using `unittest` with `unittest.mock`.

Run locally:
```bash
# Via Docker (recommended — matches CI exactly)
.ci/run_local.sh

# Or directly (requires TPM emulator and dependencies)
python -m pytest test/
```

**What's expected for your PR:**
- Existing tests must pass. If your change breaks an existing test, fix it.
- New tests are expected for new behavior.

Example — testing a `retry_time()` backoff cap fix in `test/test_retry_algo.py`:
```python
def test_exponential_with_max_delay(self):
    # Without cap: 10^5 = 100,000. With cap of 60: should return 60
    self.assertEqual(retry.retry_time(True, 10, 5, None, max_delay=60), 60)

def test_exponential_below_max_delay(self):
    # 2^3 = 8, below cap of 60
    self.assertEqual(retry.retry_time(True, 2, 3, None, max_delay=60), 8)
```

Example — testing a `num_workers` wiring fix in `test/test_verifier_server.py`:
```python
@patch("keylime.web.verifier_server.config")
def test_setup_reads_num_workers(self, mock_config):
    mock_config.getint.return_value = 4
    server = VerifierServer.__new__(VerifierServer)
    server._setup()
    self.assertEqual(server.worker_count, 4)
```

### Layer 3: End-to-End Tests (Automated)

E2E tests from [keylime-tests](https://github.com/RedHat-SP-Security/keylime-tests) run via **Packit-as-a-Service** on Fedora and CentOS Stream. These spin up actual keylime services (verifier, registrar, agent with TPM emulator) and test real attestation flows.

These are maintained by the Red Hat security team. You don't write them for most PRs, but they must pass. If your change breaks an E2E test, you'll see it in the PR checks.

Run locally (requires Fedora/CentOS):
```bash
pip install tmt
tmt run
```

See [keylime-tests TESTING.md](https://github.com/RedHat-SP-Security/keylime-tests/blob/main/TESTING.md) for detailed setup.

### Code Coverage (Informational)

Coverage is measured via **codecov.io** on Fedora. It reports:
- Overall coverage (currently ~55%)
- **Patch coverage** — what percentage of your new/changed lines are exercised by tests

Patch coverage of 100% is expected. The codecov bot comments on your PR showing which lines are covered and which aren't.

### Checklist Before Submitting a PR

| Step | How | Required? |
|---|---|---|
| Run `pre-commit run --all-files` | Local | Yes — CI rejects formatting violations |
| Run unit tests via `.ci/run_local.sh` | Local (Docker) | Yes — catches test failures before CI |
| Write unit tests for new behavior | In `test/` directory | Yes — reviewers will ask for them |
| Run E2E tests | Local (Fedora) or rely on Packit CI | Optional locally — CI runs them automatically |
| Check codecov patch coverage | After PR is opened | Informational but reviewers check it |

---

## Related Documents

| Document | Content |
|---|---|
| `Verifier_Memory_Bloat_Analysis.md` | Detailed scalability and HA risk analysis of verifier and registrar, including the `num_workers` bug, retry backoff analysis, memory growth investigation, push vs pull mode comparison, and upstream fix recommendations |
| `RAS-HA-Review.md` | Review of the RAS HA design study — validates verifier ID concept, analyzes K8s Lease wrapper, identifies split-brain and thundering herd gaps |
| `OMC_RAS_Feature_Study.md` | OMC RAS feature study covering REST API design, agent state derivation, staleness detection, and phased implementation plan |
