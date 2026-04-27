# Keylime Registrar & Verifier Benchmarking Analysis

## 1. Executive Summary

This document reviews the Keylime codebase for existing test cases, benchmarking capabilities, and means of obtaining performance metrics for the **Registrar** and **Verifier** components — with a focus on policy-related methods (IMA policy, MB policy, attestation evidence verification).

**Key Finding:** Keylime has extensive unit and functional tests but **no dedicated benchmarking or performance testing infrastructure**. There are no synthetic payload generators, load testing harnesses, or throughput measurement tools in the repository. The `configTune.txt` file documents scaling theory and deployment profiles but provides no tooling to validate them.

---

## 2. Existing Test Infrastructure

### 2.1 Unit Tests (in `test/`)

| Test File | Component | What It Tests |
|---|---|---|
| `test_registrar_server.py` | Registrar | Route configuration for v2/v3 APIs |
| `test_registrar_db.py` | Registrar | Agent CRUD in registrar database |
| `test_registrar_tpm_identity.py` | Registrar | TPM identity immutability checks |
| `test_registrar_agent_cert_compliance.py` | Registrar | Certificate compliance validation |
| `test_agents_controller.py` | Registrar | Agent registration controller logic, concurrency |
| `test_verifier_server.py` | Verifier | Route configuration, engine disposal, fork safety |
| `test_verifier_db.py` | Verifier | Agent/allowlist/mbpolicy CRUD in verifier DB |
| `test_cloud_verifier_common.py` | Verifier | `process_get_status`, `_from_db_obj`, session management |
| `test_attestation_controller.py` | Verifier | Push attestation create/update, exponential backoff |
| `test_attestation_model.py` | Verifier | Attestation model lifecycle, state transitions |
| `test_evidence_model.py` | Verifier | Evidence item model (certification, log types) |
| `test_tpm_engine.py` | Verifier | TPM verification engine, policy reload, token extension |
| `test_session_controller.py` | Verifier | Session creation/update, rate limiting |
| `test_auth_session.py` | Verifier | Auth session lifecycle, stale cleanup |
| `test_ima_verification.py` | Verifier | IMA measurement list verification |
| `test_create_mb_policy.py` | Verifier | Measured boot policy creation |
| `test_create_runtime_policy.py` | Verifier | IMA runtime policy creation |
| `test_push_agent_monitor.py` | Verifier | Push agent timeout monitoring |
| `test_rate_limiter.py` | Verifier | Rate limiting for session creation |

### 2.2 Test Execution Methods

| Method | Command | Environment |
|---|---|---|
| Local (Docker) | `.ci/run_local.sh` | `quay.io/keylime/keylime-ci` container with swtpm |
| CI (GitHub Actions) | `.ci/test_wrapper.sh` | Same container, triggered on PR |
| Manual | `test/run_tests.sh` | Requires TPM (hw or swtpm), installs deps |
| E2E (Packit) | `tmt` via `packit-ci.fmf` | Fedora/CentOS Stream VMs |

### 2.3 Test Runner

Tests use `unittest` (discovered by `green` runner) and `coverage`. There is **no pytest-benchmark, locust, wrk, or any load testing framework** in the dependencies.

```
# test/test-requirements.txt
coverage==4.5.2
green==4.0.2
pytest-asyncio==0.10.0
```

---

## 3. Policy-Related Endpoints (the "pol" Methods)

### 3.1 Verifier Policy Endpoints

**IMA Policy (Runtime Policy):**
| API Version | Method | Path | Controller | Action |
|---|---|---|---|---|
| v2 | GET | `/v2/allowlists` | `IMAPolicyController` | `index` |
| v2 | GET | `/v2/allowlists/:name` | `IMAPolicyController` | `show` |
| v2 | POST | `/v2/allowlists/:name` | `IMAPolicyController` | `create` |
| v2 | PUT | `/v2/allowlists/:name` | `IMAPolicyController` | `overwrite` |
| v2 | DELETE | `/v2/allowlists/:name` | `IMAPolicyController` | `delete` |
| v3 | GET | `/v3/policies/ima` | `IMAPolicyController` | `index` |
| v3 | POST | `/v3/policies/ima` | `IMAPolicyController` | `create` |
| v3 | PATCH | `/v3/policies/ima/:name` | `IMAPolicyController` | `update` |
| v3 | DELETE | `/v3/policies/ima/:name` | `IMAPolicyController` | `delete` |

**MB Policy (Measured Boot Reference State):**
| API Version | Method | Path | Controller | Action |
|---|---|---|---|---|
| v2 | GET | `/v2/mbpolicies` | `MBRefStateController` | `index` |
| v2 | POST | `/v2/mbpolicies/:name` | `MBRefStateController` | `create` |
| v2 | PUT | `/v2/mbpolicies/:name` | `MBRefStateController` | `overwrite` |
| v2 | DELETE | `/v2/mbpolicies/:name` | `MBRefStateController` | `delete` |
| v3 | GET | `/v3/refstates/uefi` | `MBRefStateController` | `index` |
| v3 | POST | `/v3/refstates/uefi` | `MBRefStateController` | `create` |
| v3 | PATCH | `/v3/refstates/uefi/:name` | `MBRefStateController` | `update` |
| v3 | DELETE | `/v3/refstates/uefi/:name` | `MBRefStateController` | `delete` |

**Evidence Verification:**
| API Version | Method | Path | Controller | Action |
|---|---|---|---|---|
| v2/v3 | POST | `/v{2,3}/verify/evidence` | `EvidenceController` | `process` |

**Attestation (Push Mode):**
| API Version | Method | Path | Controller | Action |
|---|---|---|---|---|
| v3 | POST | `/v3/agents/:id/attestations` | `AttestationController` | `create` |
| v3 | PATCH | `/v3/agents/:id/attestations/latest` | `AttestationController` | `update_latest` |
| v3 | GET | `/v3/agents/:id/attestations` | `AttestationController` | `index` |

### 3.2 Registrar Endpoints

| API Version | Method | Path | Controller | Action |
|---|---|---|---|---|
| v2/v3 | POST | `/v{2,3}/agents` | `AgentsController` | `create` |
| v2/v3 | POST | `/v{2,3}/agents/:id/activate` | `AgentsController` | `activate` |
| v2/v3 | GET | `/v{2,3}/agents` | `AgentsController` | `index` |
| v2/v3 | GET | `/v{2,3}/agents/:id` | `AgentsController` | `show` |
| v2/v3 | DELETE | `/v{2,3}/agents/:id` | `AgentsController` | `delete` |

### 3.3 Core Verification Functions

The actual attestation processing happens in:

- `cloud_verifier_common.process_quote_response()` — validates agent quote, IMA list, MB log
- `cloud_verifier_common.process_verify_attestation()` — on-demand evidence verification
- `verification.tpm_engine.TPMEngine.verify_evidence()` — push mode evidence evaluation
- `verification.base.engine_driver.EngineDriver.verify_evidence()` — orchestrates verification engines

---

## 4. What's Missing: Benchmarking Gaps

### 4.1 No Synthetic Payload Generators

There are no tools to generate:
- Fake TPM quotes
- Synthetic IMA measurement lists
- Mock MB/UEFI event logs
- Simulated agent registration payloads

The existing tests use `unittest.mock.MagicMock` for all TPM/agent interactions, which is sufficient for correctness but not for performance measurement.

### 4.2 No Load Testing Infrastructure

- No `locust`, `wrk`, `ab`, `k6`, or `vegeta` configurations
- No concurrent request generators
- No throughput/latency measurement scripts
- No `pytest-benchmark` fixtures

### 4.3 No Performance Baselines

- No recorded baseline metrics for any endpoint
- No CI job that tracks performance regressions
- The `configTune.txt` file provides theoretical scaling formulas but no empirical validation:
  ```
  attestation_rate ≈ agents / quote_interval
  ```

### 4.4 No Database Benchmark Harness

Despite `configTune.txt` documenting that DB throughput is a bottleneck at 200-400 attestations/sec, there is no tool to measure actual DB performance under load.

---

## 5. Existing Approximations to Benchmarking

### 5.1 Rate Limiter Tests (`test_rate_limiter.py`)

The `RateLimiter` class and its tests provide a foundation for understanding request throttling behavior, but they test correctness, not throughput:

```python
# Tests sliding window, per-identifier limits, exponential backoff
test_rate_limit_allows_within_limit
test_rate_limit_blocks_when_exceeded
test_rate_limit_sliding_window
test_exponential_backoff
```

### 5.2 Attestation Controller Backoff Tests (`test_attestation_controller.py`)

Tests for exponential backoff after failed attestations approximate load behavior:

```python
test_create_returns_503_after_failed_attestation
test_create_uses_consecutive_failures_for_backoff
test_create_caps_retry_after_at_quote_interval
```

### 5.3 Push Agent Monitor Tests (`test_push_agent_monitor.py`)

Tests timeout handling for multiple agents, which is relevant to scale:

```python
test_schedule_timeout_multiple_agents
test_check_push_agent_timeouts_multiple_agents
test_handles_isolated_between_agents
```

### 5.4 Verifier DB Tests (`test_verifier_db.py`)

Tests CRUD operations for agents, allowlists, and MB policies against a real SQLite database — the closest thing to a DB performance test:

```python
test_01_add_allowlist
test_02_add_agent
test_07_delete_agent
test_09_add_mbpolicy
test_10_delete_mbpolicy
```

### 5.5 configTune.txt Scaling Guidance

The `configTune.txt` file provides deployment profiles but no automation:

| Profile | Agents | quote_interval | num_workers | DB pool |
|---|---|---|---|---|
| Small | <100 | 30s | 2 | 2,1 |
| Medium | 100-500 | 60s | 4 | 4,2 |
| Large | 500-2000 | 120s | 8 | 8,4 |

---

## 6. Recommended Benchmarking Approach

### 6.1 Synthetic Payload Generation

Create synthetic payloads that bypass TPM hardware requirements:

**IMA Policy Payload:**
```python
import json, hashlib, os

def generate_ima_policy(num_entries=1000):
    """Generate a synthetic IMA runtime policy."""
    digests = {}
    for i in range(num_entries):
        path = f"/usr/bin/synthetic_binary_{i}"
        digest = hashlib.sha256(os.urandom(32)).hexdigest()
        digests[path] = [f"sha256:{digest}"]
    return json.dumps({"meta": {"version": 5, "generator": "synthetic", "timestamp": "2026-01-01"},
                        "digests": digests})
```

**MB Policy Payload:**
```python
def generate_mb_policy():
    """Generate a synthetic measured boot reference state."""
    return json.dumps({"mb_refstate": [
        {"pcr": i, "sha256": [hashlib.sha256(os.urandom(32)).hexdigest()]}
        for i in range(24)
    ]})
```

**Agent Registration Payload:**
```python
from cryptography.hazmat.primitives.asymmetric import rsa, ec
from cryptography.hazmat.primitives import serialization
import base64

def generate_registration_payload(agent_id):
    """Generate a synthetic agent registration payload."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub_pem = key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    return {
        "ek_tpm": base64.b64encode(os.urandom(256)).decode(),
        "ekcert": None,
        "aik_tpm": base64.b64encode(pub_pem).decode(),
        "mtls_cert": None,
    }
```

### 6.2 Locust-Based Load Testing

```python
# bench/locustfile.py
from locust import HttpUser, task, between
import json, uuid

class RegistrarUser(HttpUser):
    wait_time = between(0.1, 0.5)

    @task(3)
    def list_agents(self):
        self.client.get("/v3/agents", verify=False)

    @task(1)
    def register_agent(self):
        agent_id = str(uuid.uuid4())
        self.client.post(f"/v2/agents/{agent_id}",
                         json=generate_registration_payload(agent_id),
                         verify=False)

class VerifierPolicyUser(HttpUser):
    wait_time = between(0.1, 0.5)

    @task(2)
    def list_ima_policies(self):
        self.client.get("/v2/allowlists", verify=False, cert=CLIENT_CERT)

    @task(1)
    def create_ima_policy(self):
        name = f"policy-{uuid.uuid4().hex[:8]}"
        self.client.post(f"/v2/allowlists/{name}",
                         json={"tpm_policy": "{}", "runtime_policy": generate_ima_policy(100)},
                         verify=False, cert=CLIENT_CERT)

    @task(1)
    def create_mb_policy(self):
        name = f"mbpol-{uuid.uuid4().hex[:8]}"
        self.client.post(f"/v2/mbpolicies/{name}",
                         json={"mb_refstate": generate_mb_policy()},
                         verify=False, cert=CLIENT_CERT)
```

Run with:
```bash
locust -f bench/locustfile.py --host=https://localhost:8881 --users 50 --spawn-rate 10
```

### 6.3 pytest-benchmark Integration

```python
# bench/test_bench_registrar_db.py
import pytest
from keylime.db.keylime_db import SessionManager, make_engine
from keylime.db.registrar_db import RegistrarMain

@pytest.fixture(scope="module")
def db_session():
    engine = make_engine("registrar")
    sm = SessionManager()
    with sm.session_context(engine) as session:
        yield session

def test_bench_add_agent(benchmark, db_session):
    def add_agent():
        agent = RegistrarMain(agent_id=str(uuid.uuid4()), ek_tpm="fake", aik_tpm="fake")
        db_session.add(agent)
        db_session.flush()
    benchmark(add_agent)

def test_bench_query_agents(benchmark, db_session):
    benchmark(lambda: db_session.query(RegistrarMain).all())
```

### 6.4 Standalone Throughput Script

```python
# bench/throughput_test.py
"""Measure raw attestation processing throughput without network overhead."""
import time
from unittest.mock import MagicMock, patch
from keylime.cloud_verifier_common import process_quote_response
from keylime.failure import Failure

def bench_process_quote(iterations=1000):
    agent = {"agent_id": "test-agent", "ima_sign_verification_keys": "",
             "mb_refstate": None, "runtime_policy": "{}",
             "hash_alg": "sha256", "enc_alg": "rsa", "sign_alg": "rsassa"}
    mock_response = {"pubkey": None, "quote": "AAAA", "ima_measurement_list": None,
                     "ima_measurement_list_entry": 0, "mb_measurement_list": None, "boottime": 0}
    attest_state = MagicMock()

    start = time.perf_counter()
    for _ in range(iterations):
        try:
            process_quote_response(agent, None, None, mock_response, attest_state)
        except Exception:
            pass  # Expected with mock data
    elapsed = time.perf_counter() - start
    print(f"Processed {iterations} quotes in {elapsed:.3f}s ({iterations/elapsed:.1f} ops/sec)")

if __name__ == "__main__":
    bench_process_quote()
```

### 6.5 Database Throughput Benchmark

```python
# bench/db_throughput.py
"""Validate configTune.txt claim of 200-400 attestations/sec DB bottleneck."""
import time, uuid, os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from keylime.db.verifier_db import VerfierMain, Base

def bench_db_writes(n=5000, db_url="sqlite:///bench_verifier.db"):
    engine = create_engine(db_url)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine)
    session = Session()

    agents = []
    for i in range(n):
        agents.append(VerfierMain(agent_id=str(uuid.uuid4()), operational_state=0,
                                   v="", ip="127.0.0.1", port=9002, verifier_id="default",
                                   verifier_ip="127.0.0.1", verifier_port=8881))

    start = time.perf_counter()
    for agent in agents:
        session.add(agent)
        if len(session.new) >= 100:
            session.commit()
    session.commit()
    elapsed = time.perf_counter() - start

    print(f"Inserted {n} agents in {elapsed:.3f}s ({n/elapsed:.1f} writes/sec)")
    os.unlink("bench_verifier.db")

if __name__ == "__main__":
    bench_db_writes()
```

---

## 7. Metrics to Capture

| Metric | Target Component | Method |
|---|---|---|
| Agent registration throughput (ops/sec) | Registrar | Locust / pytest-benchmark |
| Agent activation latency (p50/p95/p99) | Registrar | Locust |
| IMA policy CRUD throughput | Verifier | Locust |
| MB policy CRUD throughput | Verifier | Locust |
| Quote processing rate (ops/sec) | Verifier | Standalone script |
| Evidence verification latency | Verifier | Locust against `/verify/evidence` |
| Attestation create/update cycle time | Verifier (push) | Locust against `/v3/agents/:id/attestations` |
| DB write throughput (agents/sec) | Both | DB benchmark script |
| DB read throughput (queries/sec) | Both | DB benchmark script |
| Memory usage under load | Both | `psutil` / container metrics |
| Connection pool saturation | Both | SQLAlchemy pool events |

---

## 8. Mapping to configTune.txt Deployment Profiles

The benchmarks should validate the theoretical profiles from `configTune.txt`:

```
attestation_rate ≈ agents / quote_interval
```

| Profile | Expected Rate | Benchmark Validation |
|---|---|---|
| Small (100 agents, 30s interval) | ~3 att/sec | Run Locust with 100 simulated agents |
| Medium (500 agents, 60s interval) | ~8 att/sec | Run Locust with 500 simulated agents |
| Large (2000 agents, 120s interval) | ~16 att/sec | Run Locust with 2000 simulated agents |

Key questions the benchmarks should answer:
1. At what attestation rate does the verifier start dropping requests?
2. Does `num_workers` scaling match the linear assumption?
3. At what point does `database_pool_sz_ovfl` become the bottleneck?
4. What is the actual DB write ceiling (claimed 200-400 att/sec)?

---

## 9. Prerequisites for Running Benchmarks

### Software Dependencies
```bash
pip install locust pytest-benchmark psutil
```

### Infrastructure Requirements
- **Registrar benchmarks:** Can run against real registrar (no TPM needed for route-level tests)
- **Verifier policy benchmarks:** Can run against real verifier with mTLS certs
- **Quote processing benchmarks:** Require swtpm or mock TPM (use `quay.io/keylime/keylime-ci` container)
- **DB benchmarks:** Can run standalone with SQLite or PostgreSQL

### TLS Certificate Setup
Verifier endpoints require mTLS. Use the auto-generated certs from `/var/lib/keylime/cv_ca/` or generate test certs:
```bash
keylime_ca -c init
keylime_ca -c create --name bench-client
```

---

## 10. Summary

| Aspect | Current State | Gap |
|---|---|---|
| Unit tests for registrar | ✅ Route config, DB CRUD, controller logic | No performance tests |
| Unit tests for verifier policies | ✅ DB CRUD, model lifecycle, attestation flow | No policy endpoint load tests |
| Unit tests for attestation | ✅ Push mode, backoff, timeout monitoring | No throughput measurement |
| Synthetic payload generators | ❌ None | Need IMA, MB, quote, registration generators |
| Load testing framework | ❌ None | Need Locust/k6 configs |
| Performance baselines | ❌ None | Need CI-integrated benchmarks |
| DB throughput validation | ❌ None (only theoretical in configTune.txt) | Need empirical measurement |
| Scaling profile validation | ❌ None | Need multi-agent simulation |

The codebase has strong correctness testing but zero performance/benchmarking infrastructure. The recommended approach is to layer synthetic payload generators on top of the existing test patterns, then use Locust for HTTP-level load testing and pytest-benchmark for function-level microbenchmarks.
