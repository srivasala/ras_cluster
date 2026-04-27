# Keylime Agent Registration Behavior

Validated against `rust-keylime` (Rust agent) and `keylime` 7.14.1 (Python verifier/registrar).

---

## 1. When Does the Agent Initiate Registration?

**At startup, unconditionally.** Both agent variants call `register_agent()` as the first meaningful action:

- **Pull-model agent** (`keylime-agent/src/main.rs`): Registration runs in `main()` before the HTTP server starts. It's a hard prerequisite — the agent won't serve quotes until registration succeeds.
- **Push-model agent** (`keylime-push-model-agent/src/state_machine.rs`): The state machine always initializes to `State::Unregistered`, which triggers registration as the first state transition.

Both call the same core function: `keylime/src/agent_registration.rs::register_agent()`, which executes the two-phase TPM handshake:

1. **Phase 1** — `POST /agents/:agent_id`: Agent sends TPM identity (EK/AIK). Registrar encrypts a challenge with the EK, returns the challenge blob.
2. **Phase 2** — `POST /agents/:agent_id/activate`: Agent decrypts the challenge via TPM `activate_credential`, computes an HMAC auth_tag, sends it back. Registrar verifies and sets `active = True`.

---

## 2. Is Registration Interval-Based? When Does It Stop?

**Not interval-based — it's a one-shot attempt with transport-level retries.** The two agent variants differ significantly:

| Behavior | Pull-model agent | Push-model agent |
|---|---|---|
| Registration attempts | Once | Indefinitely until success |
| Transport retries per attempt | 5 retries, exponential backoff (10s initial, 5min max) | Same, plus application-level retry loop |
| On failure | **Exits the process** | Sleeps `measurement_interval` (default 60s), retries |
| "I'm registered" signal | `register_agent()` returns `Ok(())` | State transitions to `State::Registered` |

**Retry defaults** (from `keylime/src/config/base.rs`):
- `max_retries`: 5
- `initial_delay`: 10,000ms (10 seconds)
- `max_delay`: 300,000ms (5 minutes)

The agent knows it's registered when both Phase 1 and Phase 2 complete successfully. There's no persistent state — if the agent process restarts, it re-registers from scratch.

---

## 3. If Already Attested, Will It Stop Registration?

**No.** There is no check for prior attestation status. Every time the agent process starts, it registers unconditionally. There's no local state file tracking "I was previously registered/attested."

The **registrar handles this gracefully** — on the Python side (`keylime/web/registrar/agents_controller.py`), if the agent UUID already exists with the same TPM identity, the registrar accepts the re-registration (overwrites the record, generates a new challenge). If the TPM identity changed (different EK/AK), it returns 403 Forbidden.

A restart cycle looks like: agent starts → registers (registrar accepts re-registration) → verifier resumes polling → attestation continues. The agent doesn't need to know it was previously attested.

---

## 4. If Both Verifier and Registrar Are Down, What Does the Agent Do?

### Pull-model agent: crashes after retries

The agent tries to register (registrar is down) → `ResilientClient` retries 5 times with exponential backoff (10s, 20s, 40s, 80s, 160s — capped at 300s) → all retries fail → `register_agent()` returns error → agent logs "Exiting due to registration failure" → **process exits**.

If running under systemd or K8s, the process manager restarts it, and the cycle repeats.

Note: the verifier being down has **zero impact** on the pull-model agent's startup. The agent never contacts the verifier — the verifier contacts the agent. If the verifier is down, the agent just sits idle serving its HTTP endpoint, waiting to be polled.

### Push-model agent: retries forever, never crashes

Registration fails → `State::RegistrationFailed` → sleeps 60s → back to `State::Unregistered` → retries. This loops indefinitely. The agent stays alive, consuming minimal resources, waiting for the registrar to come back.

If the registrar comes back but the verifier is still down, the push agent registers successfully, then enters `State::Negotiating` (session establishment with verifier) → fails → `State::AttestationFailed` → sleeps 60s → retries negotiation. Again, indefinitely.

---

## Summary

| Scenario | Pull-model | Push-model |
|---|---|---|
| Normal startup | Register → serve HTTP → wait for verifier | Register → negotiate → push attestations |
| Registrar down | Crash after ~5 retries (~5 min) | Retry forever (60s intervals) |
| Verifier down | No impact (agent doesn't contact verifier) | Retry negotiation forever (60s intervals) |
| Both down | Crash after ~5 min (registrar unreachable) | Retry registration forever |
| Agent restart after attestation | Re-registers from scratch (no local state) | Re-registers from scratch |

---

## Key Source Files

| Component | File | Key Function |
|---|---|---|
| Core registration | `keylime/src/agent_registration.rs` | `register_agent()` |
| Registrar client | `keylime/src/registrar_client.rs` | `try_register_agent()`, `try_activate_agent()` |
| Pull-model main | `keylime-agent/src/main.rs` | `main()` |
| Pull-model retry config | `keylime-agent/src/main.rs` | `get_retry_config()` |
| Push-model state machine | `keylime-push-model-agent/src/state_machine.rs` | `StateMachine::run()` |
| Push-model registration | `keylime-push-model-agent/src/registration.rs` | `check_registration()`, `register_agent()` |
| Resilient client | `keylime/src/resilient_client.rs` | `ResilientClient::new()` |
| Retry defaults | `keylime/src/config/base.rs` | `DEFAULT_EXP_BACKOFF_*` constants |
