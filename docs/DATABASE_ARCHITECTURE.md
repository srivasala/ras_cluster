# Keylime Database Architecture

## Overview

Keylime uses **SQLAlchemy** as its ORM and **Alembic** for schema migrations. The codebase has two layers of database models:

1. **Legacy ORM layer** (`keylime/db/registrar_db.py`, `keylime/db/verifier_db.py`) — direct SQLAlchemy declarative models
2. **New model layer** (`keylime/models/`) — a custom `PersistableModel` framework that dynamically generates SQLAlchemy mappings, adds validation, change tracking, and association management

Both layers target the same underlying database tables. The `DBManager` class (`keylime/models/base/db.py`) manages engine creation, session scoping, and connection pooling.

### Database Backend

Configured via the `database_url` setting per service:

- **Registrar**: defaults to `reg_data.sqlite` in the working directory
- **Verifier** (called `cloud_verifier` internally): defaults to `cv_data.sqlite`
- Supports **SQLite** (dev/test) and **MySQL/PostgreSQL** (production) with configurable pool size and max overflow

The registrar and verifier each have their own separate database file/instance. They share no tables. The `agent_id` is the logical link — an agent must register with the registrar before the verifier can attest it.

---

## Entity Relationship Diagram

```
                    ┌──────────────┐
                    │  allowlists  │
                    │  (IMAPolicy) │
                    │──────────────│
                    │ PK: id       │
                    │ UQ: name     │
                    └──────┬───────┘
                           │ 1
                           │
                           │ N
┌──────────────┐    ┌──────┴───────┐    ┌──────────────┐
│  mbpolicies  │    │ verifiermain │    │   sessions   │
│  (MBPolicy)  │    │(VerifierAgent│    │ (AuthSession)│
│──────────────│    │──────────────│    │──────────────│
│ PK: id       │◄───│FK:mb_policy_ │    │PK:session_id │
│ UQ: name     │ 1  │   id         │───►│FK:agent_id   │
└──────────────┘    │FK:ima_policy_│ 1  └──────────────┘
                    │   id         │ N
                    │PK: agent_id  │
                    └──────┬───────┘
                           │ 1
                           │
                           │ N
                    ┌──────┴───────┐
                    │ attestations │
                    │(Attestation) │
                    │──────────────│
                    │PK: agent_id  │
                    │PK: index     │
                    │FK: agent_id  │
                    └──────┬───────┘
                           │ 1
                           │
                           │ N
                    ┌──────┴───────┐
                    │evidence_items│
                    │(EvidenceItem)│
                    │──────────────│
                    │FK: agent_id  │
                    │FK: attest_idx│
                    └──────────────┘


    ┌──────────────────┐
    │  registrarmain   │  (Separate database)
    │ (RegistrarAgent) │
    │──────────────────│
    │ PK: agent_id     │
    └──────────────────┘
```

---

## Registrar Database

The registrar database contains a single table.

### Table: `registrarmain`

- **Source files**: `keylime/db/registrar_db.py` (legacy), `keylime/models/registrar/registrar_agent.py` (new model)
- **Purpose**: Stores TPM agent registration records. Each row represents one agent that has registered its TPM identity with the registrar.

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `agent_id` | `String(80)` | ✅ | No | Unique agent identifier (UUID) |
| `key` | `String(45)` | | Yes | HMAC key used to verify the `TPM2_ActivateCredential` response, binding the AK to the EK |
| `aik_tpm` | `String(500)` | | Yes | Attestation Identity Key (AK) — `TPM2B_PUBLIC` structure, base64-encoded |
| `ekcert` | `String(2048)` | | Yes | Endorsement Key certificate (DER, base64-encoded or PEM) |
| `ek_tpm` | `String(500)` | | Yes | Endorsement Key (EK) — `TPM2B_PUBLIC` structure, base64-encoded |
| `iak_tpm` | `String(500)` | | Yes | Initial Attestation Key (IAK) for DevID-based registration |
| `idevid_tpm` | `String(500)` | | Yes | Initial Device Identity (IDevID) key |
| `iak_cert` | `String(2048)` | | Yes | IAK certificate |
| `idevid_cert` | `String(2048)` | | Yes | IDevID certificate |
| `mtls_cert` | `String(2048)` | | Yes | Agent's mTLS certificate (or `"disabled"`) |
| `virtual` | `Integer` | | Yes | Legacy flag: indicates agent runs in a cloud VM (deprecated) |
| `ip` | `String(15)` | | Yes | Agent IP address (for pull-mode connections) |
| `port` | `Integer` | | Yes | Agent port |
| `active` | `Integer` | | Yes | Whether the AK has been successfully bound to the EK via challenge-response |
| `provider_keys` | `JSONPickleType` (Text) | | Yes | Legacy: cloud provider key info including out-of-band EK cert (deprecated) |
| `regcount` | `Integer` | | Yes | Number of times the agent has registered |

#### Primary Key

- **`agent_id`** — single-column primary key, a string UUID uniquely identifying each agent

#### Design Notes

- The `JSONPickleType` is a custom SQLAlchemy type that stores Python objects as JSON text (using `JSONPickler` which wraps `json.dumps`/`json.loads`), backed by a `Text` column.
- The new model layer (`RegistrarAgent`) adds extensive validation logic:
  - **TPM identity immutability**: `ek_tpm`, `ekcert`, and `aik_tpm` are immutable once set for an existing agent. Changing them is rejected as a potential UUID spoofing attack.
  - **EK/IAK/IDevID certificate verification** against trust stores
  - **AK-IAK binding** via `TPM2_Certify`
  - **ASN.1 DER compliance** checking for certificates
- The `active` flag is set to `False` whenever `ek_tpm` or `aik_tpm` changes, requiring a new challenge-response cycle.
- The `regcount` field is incremented each time any TPM identity field is updated.
- On commit, records are optionally written to a **Durable Attestation (DA)** backend for audit/compliance purposes.

#### `regcount` In Detail

`regcount` is a per-agent monotonic counter incremented each time the agent re-registers with updated TPM identity fields. The logic lives in `RegistrarAgent._prepare_regcount()` (`keylime/models/registrar/registrar_agent.py`):

```python
def _prepare_regcount(self):
    reg_fields = ("ek_tpm", "ekcert", "aik_tpm", "iak_tpm", "iak_cert", "idevid_tpm", "idevid_cert")

    if self.regcount is None:
        self.regcount = 0

    if any(field in reg_fields for field in self.changes) and self.changes_valid:
        self.regcount += 1
```

An agent re-registers when:
- The agent service restarts (e.g., after a system reboot)
- The agent's Attestation Key (AK) is regenerated
- The agent is re-provisioned with new TPM keys

`regcount` serves as a diagnostic/audit signal — a high value may indicate instability or suspicious activity. However, it has important limitations:

- It is **per-agent**, not a global sequence — it cannot be used for cross-agent ordering
- It records **how many times** an agent registered, but not **when**
- There is **no `created_at` or `updated_at` timestamp** in the registrar database, which means there is no deterministic way to paginate agents chronologically (UUIDs are random and provide no ordering guarantee)

#### Registration Flow

1. Agent sends TPM identity data (EK, AK, optionally IAK/IDevID) to the registrar
2. Registrar validates the data and stores it in `registrarmain`
3. Registrar produces an AK challenge (`TPM2_MakeCredential`) using the EK and AK
4. Agent responds with the decrypted challenge (`TPM2_ActivateCredential`)
5. Registrar verifies the response via HMAC comparison and sets `active = True`

---

## Verifier Database

The verifier database is more complex, with 5 tables and foreign key relationships.

### Table: `verifiermain`

- **Source files**: `keylime/db/verifier_db.py` (legacy `VerfierMain`), `keylime/models/verifier/verifier_agent.py` (new model)
- **Purpose**: The central table tracking agents under continuous attestation.

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `agent_id` | `String(80)` | ✅ | No | Unique agent identifier |
| `v` | `String(45)` | | Yes | Shared secret (pull mode) |
| `ip` | `String(15)` | | Yes | Agent IP |
| `verifier_id` | `String(80)` | | Yes | ID of the verifier instance handling this agent |
| `verifier_ip` | `String(15)` | | Yes | Verifier instance IP |
| `verifier_port` | `Integer` | | Yes | Verifier instance port |
| `port` | `Integer` | | Yes | Agent port |
| `operational_state` | `Integer` | | Yes | Agent state machine value (pull mode) |
| `public_key` | `String(500)` | | Yes | Agent's public key |
| `tpm_policy` | `JSONPickleType` (Text) | | Yes | Expected PCR values as JSON |
| `meta_data` | `Text` (MySQL: 429MB) | | Yes | Arbitrary agent metadata |
| `ima_policy_id` | `Integer` | | Yes | FK → `allowlists.id` |
| `ima_sign_verification_keys` | `Text` (MySQL: 429MB) | | Yes | IMA file signing verification keys |
| `mb_policy_id` | `Integer` | | Yes | FK → `mbpolicies.id` |
| `revocation_key` | `String(2800)` | | Yes | Key used for revocation notifications |
| `accept_tpm_hash_algs` | `JSONPickleType` | | Yes | Acceptable TPM hash algorithms (JSON list) |
| `accept_tpm_encryption_algs` | `JSONPickleType` | | Yes | Acceptable TPM encryption algorithms |
| `accept_tpm_signing_algs` | `JSONPickleType` | | Yes | Acceptable TPM signing algorithms |
| `hash_alg` | `String(10)` | | Yes | Chosen hash algorithm |
| `enc_alg` | `String(10)` | | Yes | Chosen encryption algorithm |
| `sign_alg` | `String(10)` | | Yes | Chosen signing algorithm |
| `boottime` | `Integer` | | Yes | Agent boot timestamp |
| `ima_pcrs` | `JSONPickleType` | | Yes | PCR indices used for IMA |
| `pcr10` | `LargeBinary` | | Yes | Current PCR10 value (IMA aggregate) |
| `next_ima_ml_entry` | `Integer` | | Yes | Next IMA measurement list entry to process |
| `severity_level` | `Integer` | | Yes | Current severity level |
| `last_event_id` | `String(200)` | | Yes | Last processed event ID |
| `learned_ima_keyrings` | `JSONPickleType` | | Yes | IMA keyrings learned from the log |
| `supported_version` | `String(20)` | | Yes | Agent API version |
| `ak_tpm` | `String(500)` | | Yes | Attestation key (copied from registrar) |
| `mtls_cert` | `String(2048)` | | Yes | Agent mTLS certificate |
| `attestation_count` | `Integer` | | Yes | Total attestations performed |
| `last_received_quote` | `Integer` | | Yes | Timestamp of last received quote |
| `last_successful_attestation` | `Integer` | | Yes | Timestamp of last successful attestation |
| `tpm_clockinfo` | `JSONPickleType` | | Yes | TPM clock info for detecting resets |
| `accept_attestations` | `Boolean` | | Yes | Whether push-mode attestations are accepted |
| `consecutive_attestation_failures` | `Integer` | | Yes | Failure count for exponential backoff |

#### Primary Key

- **`agent_id`** — single-column primary key

#### Foreign Keys

- `ima_policy_id` → `allowlists.id`
- `mb_policy_id` → `mbpolicies.id`

#### Relationships (SQLAlchemy)

- `ima_policy` — one-to-one with `VerifierAllowlist` (back_populates `agent`)
- `mb_policy` — one-to-one with `VerifierMbpolicy` (back_populates `agent`)
- `attestations` — one-to-many with `Attestation` (via new model layer)

#### Column Categories

The columns serve distinct purposes depending on the attestation mode:

**Pull-mode only fields** (verifier polls the agent):
- `operational_state`, `severity_level`, `v`, `public_key`, `ip`, `port`
- `verifier_id`, `verifier_ip`, `verifier_port`
- `supported_version`, `hash_alg`, `enc_alg`, `sign_alg`
- `ima_pcrs`, `pcr10`, `next_ima_ml_entry`, `boottime`, `tpm_clockinfo`
- `last_received_quote`, `last_successful_attestation`

**Push-mode only fields** (agent initiates attestation):
- `accept_attestations`, `consecutive_attestation_failures`

**Shared fields**:
- `agent_id`, `ak_tpm`, `mtls_cert`, `tpm_policy`, `meta_data`
- `ima_policy_id`, `mb_policy_id`, `ima_sign_verification_keys`
- `revocation_key`, `attestation_count`
- `accept_tpm_hash_algs`, `accept_tpm_encryption_algs`, `accept_tpm_signing_algs`

#### `operational_state` In Detail

`operational_state` is an integer field that drives the **pull-mode state machine** for agent attestation. It is primarily a pull-mode concept, but has a nuanced relationship with push mode.

**State definitions** (from `keylime/common/states.py`):

| Value | Constant | Label | Description |
|---|---|---|---|
| 0 | `REGISTERED` | Registered | Agent is registered with registrar but not yet added to verifier |
| 1 | `START` | Start | Agent is added to verifier and will be moved to next state |
| 2 | `SAVED` | Saved | Agent was added to verifier and is waiting for requests |
| 3 | `GET_QUOTE` | Get Quote | Agent is under periodic integrity checking |
| 4 | `GET_QUOTE_RETRY` | Get Quote (retry) | Integrity checking in retry state due to connection issues |
| 5 | `PROVIDE_V` | Provide V | Agent is receiving the V key from the verifier |
| 6 | `PROVIDE_V_RETRY` | Provide V (retry) | V key delivery in retry state due to connection issues |
| 7 | `FAILED` | Failed | Agent host failed to prove integrity |
| 8 | `TERMINATED` | Terminated | Agent was terminated and will be removed from verifier |
| 9 | `INVALID_QUOTE` | Invalid Quote | Integrity report from agent is not trusted against policy |
| 10 | `TENANT_FAILED` | Tenant Quote Failed | Agent was terminated but failed to be removed from verifier |

**Pull-mode state machine transitions** (from `process_agent()` in `keylime/cloud_verifier_tornado.py`):

```
START → GET_QUOTE → PROVIDE_V → GET_QUOTE (steady-state loop)
                  ↘                ↗
              GET_QUOTE_RETRY    PROVIDE_V_RETRY
                  ↗                ↘
              (retry)            (retry)

Any state → FAILED         (integrity check failure)
Any state → INVALID_QUOTE  (untrusted quote)
Any state → TERMINATED     (tenant-initiated deletion)
Any state → TENANT_FAILED  (deletion failed)
```

**Behaviour in push mode**:

Push mode does **not** use the `operational_state` state machine for attestation flow. However, the field is still set and checked:

- On agent creation: set to `GET_QUOTE` in push mode vs `START` in pull mode (`cloud_verifier_tornado.py` line 699)
- On agent deletion: push mode skips the state check and deletes immediately, while pull mode checks `operational_state` to decide between deletion and termination (`cloud_verifier_tornado.py` lines 591-629)
- Push-mode agent detection: `is_push_mode_agent()` in `keylime/agent_util.py` identifies push agents by `operational_state IS NULL` or both `ip` and `port` being `NULL`
- Push agent timeout monitoring: `check_push_agent_timeouts()` in `keylime/push_agent_monitor.py` queries agents where `operational_state IS NULL` to find push-mode agents

**Reactivation**: agents in `APPROVED_REACTIVATE_STATES` (`START`, `GET_QUOTE`, `GET_QUOTE_RETRY`, `PROVIDE_V`, `PROVIDE_V_RETRY`) can be reactivated on verifier restart (`keylime/web/verifier_server.py` lines 132-133).

**Key code references**:

| File | What it does |
|---|---|
| `keylime/common/states.py` | Defines all state constants, valid states, and string representations |
| `keylime/cloud_verifier_tornado.py` `process_agent()` (line 2299) | Pull-mode state machine transition logic |
| `keylime/cloud_verifier_tornado.py` `post()` (line 699) | Initial state assignment on agent creation |
| `keylime/cloud_verifier_tornado.py` `delete()` (lines 591-629) | Mode-aware deletion logic |
| `keylime/agent_util.py` `is_push_mode_agent()` | Push-mode detection via `operational_state` |
| `keylime/push_agent_monitor.py` `check_push_agent_timeouts()` (line 174) | Push agent timeout monitoring |
| `keylime/web/verifier_server.py` `start_single()` (line 132) | Agent reactivation on verifier startup |

---

### Table: `allowlists`

- **Source files**: `keylime/db/verifier_db.py` (`VerifierAllowlist`), `keylime/models/verifier/ima_policy.py` (`IMAPolicy`)
- **Purpose**: Stores IMA (Integrity Measurement Architecture) runtime integrity policies.

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `id` | `Integer` | ✅ | No | Auto-increment ID |
| `name` | `String(255)` | | No | Policy name |
| `checksum` | `String(128)` | | Yes | Policy checksum |
| `generator` | `Integer` | | Yes | Generator version |
| `tpm_policy` | `Text` | | Yes | TPM PCR policy |
| `ima_policy` | `Text` (MySQL: 429MB) | | Yes | IMA allowlist/policy content |

#### Primary Key

- **`id`** — auto-increment integer

#### Constraints

- **Unique**: `name` (constraint name: `uniq_allowlists0name`)

#### Relationships

- One-to-many with `verifiermain` via `ima_policy_id` (one policy can be shared by multiple agents)

---

### Table: `mbpolicies`

- **Source files**: `keylime/db/verifier_db.py` (`VerifierMbpolicy`), `keylime/models/verifier/mb_policy.py` (`MBPolicy`)
- **Purpose**: Stores measured boot policies (UEFI Secure Boot / measured boot reference states).

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `id` | `Integer` | ✅ | No | Auto-increment ID |
| `name` | `String(255)` | | No | Policy name |
| `mb_policy` | `Text` (MySQL: 429MB) | | Yes | Measured boot policy content |

#### Primary Key

- **`id`** — auto-increment integer

#### Constraints

- **Unique**: `name` (constraint name: `uniq_mbpolicies_name`)

#### Relationships

- One-to-many with `verifiermain` via `mb_policy_id`

---

### Table: `attestations`

- **Source files**: `keylime/db/verifier_db.py` (`VerifierAttestations`), `keylime/models/verifier/attestation.py` (`Attestation`)
- **Purpose**: Stores individual attestation records for each agent, used in push-mode attestation.

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `agent_id` | `String(80)` | ✅ (composite) | No | FK → `verifiermain.agent_id` |
| `index` | `Integer` | ✅ (composite) | No | Sequential attestation number per agent |
| `status` | `String` | | No | Status (default: `"waiting"`) — legacy column |
| `failure_type` | `String` | | Yes | Type of failure if attestation failed |
| `boottime` | `String(32)` | | Yes | Boot time at attestation |
| `nonce` | `LargeBinary` | | Yes | Cryptographic nonce for freshness |
| `nonce_created_at` | `String(32)` | | Yes | When nonce was generated |
| `nonce_expires_at` | `String(32)` | | Yes | When nonce expires |
| `hash_algorithm` | `String(15)` | | Yes | Hash algorithm used |
| `signing_scheme` | `String(15)` | | Yes | Signing scheme used |
| `starting_ima_offset` | `Integer` | | Yes | Starting IMA log offset |
| `tpm_quote` | `Text` | | Yes | Raw TPM quote data |
| `ima_entries` | `Text` | | Yes | IMA measurement log entries |
| `mb_entries` | `LargeBinary` | | Yes | Measured boot log entries |
| `quoted_ima_entries_count` | `Integer` | | Yes | Number of IMA entries covered by quote |
| `evidence_received_at` | `String(32)` | | Yes | When evidence was received |

#### Primary Key

- **Composite**: (`agent_id`, `index`) — each agent has zero or more attestations numbered incrementally from 0

#### Foreign Keys

- `agent_id` → `verifiermain.agent_id`

#### New Model Layer Enhancements

The `Attestation` model in `keylime/models/verifier/attestation.py` adds richer semantics on top of the legacy schema:

- **Stage tracking**: `awaiting_evidence` → `evaluating_evidence` → `verification_complete`
- **Evaluation outcomes**: `pending`, `pass`, `fail`
- **Failure reasons**: `broken_evidence_chain`, `policy_violation`
- **Has-many relationship** to `EvidenceItem` records (table: `evidence_items`)
- **Embeds inline** `SystemInfo` data (system information about the attested machine)
- **Navigation properties**: `previous_attestation`, `previous_authenticated_attestation`, `previous_passed_attestation` for chain-of-trust verification
- **Timing properties**: `decision_expected_by`, `seconds_to_decision`, `next_attestation_expected_after`, `challenges_valid`

---

### Table: `sessions`

- **Source files**: `keylime/db/verifier_db.py` (`VerifierSessions`), `keylime/models/verifier/auth_session.py` (`AuthSession`)
- **Purpose**: Manages authentication sessions for push-mode attestation.

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `session_id` | `String(36)` | ✅ | No | UUID for clean URL routing |
| `token_salt` | `String(32)` | | No | Per-token PBKDF2 salt (32 hex chars = 16 bytes) |
| `token_hash` | `String(64)` | | No | PBKDF2 hash of the full token (64 hex chars) |
| `active` | `Boolean` | | No | Whether session is currently active |
| `agent_id` | `String(80)` | | No | FK → `verifiermain.agent_id` |
| `nonce` | `LargeBinary` | | No | Cryptographic nonce |
| `nonce_created_at` | `String(32)` | | No | Nonce creation timestamp |
| `nonce_expires_at` | `String(32)` | | No | Nonce expiry timestamp |
| `hash_algorithm` | `String(10)` | | No | Negotiated hash algorithm |
| `signing_scheme` | `String(10)` | | No | Negotiated signing scheme |
| `ak_attest` | `LargeBinary` | | Yes | AK attestation data (proof of possession) |
| `ak_sign` | `LargeBinary` | | Yes | AK signature data |
| `pop_received_at` | `String(32)` | | Yes | When proof-of-possession was received |
| `token_expires_at` | `String(32)` | | Yes | When the session token expires |

#### Primary Key

- **`session_id`** — UUID string (36 chars)

#### Foreign Keys

- `agent_id` → `verifiermain.agent_id`

#### Security Design

- The plaintext token (format: `{session_id}.{secret}`) is **never persisted** to the database — only the PBKDF2 hash is stored.
- The `session_id` is embedded in the token to allow **O(1) lookup** by parsing the token and querying by primary key.
- An **in-memory cache** (`shared_memory`) stores session data for fast token lookups without hitting the database on every authenticated request.
- Stale/expired sessions are cleaned up on startup and during normal operation.

#### Session Lifecycle

1. Agent initiates a session → verifier creates a session record with a nonce
2. Agent provides proof-of-possession (AK certify) → verifier verifies and issues a token
3. Agent uses the token to submit attestation evidence
4. Token expires or session is explicitly deactivated

---

### Table: `evidence_items` (New Model Layer Only)

- **Source file**: `keylime/models/verifier/evidence.py` (`EvidenceItem`)
- **Purpose**: Stores individual pieces of evidence collected during an attestation.

| Column | Type | PK | Nullable | Description |
|---|---|---|---|---|
| `agent_id` | `String(80)` | | No | FK → `attestations.agent_id` |
| `attestation_index` | `Integer` | | No | FK → `attestations.index` |
| `evidence_class` | `OneOf` | | No | `"certification"` or `"log"` |
| `evidence_type` | `OneOf` | | No | `"tpm_quote"`, `"uefi_log"`, `"ima_log"`, or custom string |

Additionally, the model **embeds inline** (flattened into the same row) the following sub-models:
- **`capabilities`** — what the agent supports for this evidence type
- **`chosen_parameters`** — parameters chosen by the verifier (e.g., nonce/challenge, PCR selection)
- **`data`** — the actual evidence data submitted by the agent
- **`results`** — verification results after evaluation

#### Foreign Keys

- (`agent_id`, `attestation_index`) → `attestations`(`agent_id`, `index`)

#### Evidence Classes

- **`certification`**: TPM quotes — the agent certifies PCR state with a signed quote. Includes challenge generation and verification.
- **`log`**: Event logs (IMA, UEFI measured boot) — supports partial access via `starting_offset` for incremental log verification.

---

## Key Architectural Patterns

### 1. Dual-Model Architecture

The legacy `keylime/db/` models define raw SQLAlchemy tables, while the `keylime/models/` layer provides a rich domain model with:
- **Change tracking**: `committed` (database state) vs `changes` (pending modifications)
- **Validation**: field-level error accumulation with `_add_error()` and `validate_*()` helpers
- **Association management**: `_has_many`, `_belongs_to`, `_has_one`, `_embeds_inline`, `_embeds_one`, `_embeds_many`
- **Rendering**: controlled serialization of records to API responses via `render()`

### 2. JSONPickleType

Complex Python objects (dicts, lists) are serialized to JSON text via a custom `PickleType` subclass:

```python
class JSONPickleType(PickleType):
    impl = Text
    cache_ok = True
```

Uses `JSONPickler` (wrapping `json.dumps`/`json.loads`) instead of Python's `pickle` module, avoiding pickle security issues while keeping transparent serialization.

### 3. Alembic Migrations

42 migration files track the schema evolution from the initial two-table design. Notable migrations include:
- `8a44a4364f5a` — Initial creation of `registrarmain` and `verifiermain`
- `eb869a77abd1` — Create `allowlists` table
- `32902c0a8d90` — Create `mbpolicies` table
- `21b5cb88fcdb` / `00766b7fd0c5` — Add IAK/IDevID support
- `460d7adda633` — Add `sessions` table
- `870c218abd9a` — Add push attestation support
- `5a8b2c3d4e6f` — Hash session tokens (security hardening)
- `517a2d6b5cd3` — Add consecutive attestation failures for backoff

### 4. Push vs Pull Mode

The schema supports both attestation modes:

| Aspect | Pull Mode | Push Mode |
|---|---|---|
| Initiator | Verifier polls agent | Agent submits evidence |
| Key fields | `operational_state`, `ip`, `port`, `v` | `accept_attestations`, `consecutive_attestation_failures` |
| Key tables | `verifiermain` only | `verifiermain` + `sessions` + `attestations` + `evidence_items` |
| Authentication | mTLS | Session tokens (PBKDF2-hashed) |

### 5. Durable Attestation (DA)

The `RegistrarAgent.commit_changes()` method optionally writes to a DA backend (configured separately) for audit/compliance purposes, in addition to the primary database. This is managed by `DAManager` in `keylime/models/base/da.py`.

### 6. Connection Management

`DBManager` provides:
- **Scoped sessions**: thread-local session management via `scoped_session`
- **Context managers**: `session_context()` for auto-commit/rollback, `session_context_for()` for multi-record transactions
- **Post-fork safety**: `dispose()` method to discard inherited connection pools after `fork()`
- **Connection pooling**: configurable `pool_size` and `max_overflow` for non-SQLite backends

---

## Glossary: Core Technologies

### What is an ORM?

An **ORM (Object-Relational Mapper)** is a programming technique that lets you interact with a relational database using objects in your programming language instead of writing raw SQL queries.

Without an ORM, you would write:

```sql
SELECT * FROM registrarmain WHERE agent_id = 'abc-123';
```

With an ORM, you write Python code instead:

```python
agent = session.query(RegistrarMain).filter_by(agent_id="abc-123").first()
print(agent.ek_tpm)  # Access columns as object attributes
```

The ORM handles:
- **Mapping** Python classes to database tables and Python objects to rows
- **Translating** attribute access and method calls into SQL queries
- **Managing** database connections, transactions, and result sets
- **Abstracting** away differences between database engines (SQLite, PostgreSQL, MySQL)

---

### What is SQLAlchemy?

**SQLAlchemy** is the most widely used ORM library for Python. It provides two main APIs:

1. **Core** — a low-level SQL expression language that generates SQL from Python expressions
2. **ORM** — a high-level object-relational mapper built on top of Core

Keylime uses SQLAlchemy's **declarative ORM** style, where each database table is represented by a Python class that inherits from a `Base` class:

```python
from sqlalchemy import Column, Integer, String
from sqlalchemy.ext.declarative import declarative_base

Base = declarative_base()

class RegistrarMain(Base):
    __tablename__ = "registrarmain"           # Maps to the "registrarmain" table
    agent_id = Column(String(80), primary_key=True)  # Maps to the "agent_id" column
    key = Column(String(45))
    active = Column(Integer)
```

Key SQLAlchemy concepts used in Keylime:

| Concept | What it does | Keylime usage |
|---|---|---|
| `Engine` | Manages the database connection pool | Created by `DBManager.make_engine()` per service |
| `Session` | A workspace for querying and persisting objects | Managed via `scoped_session` for thread safety |
| `Column` | Defines a table column with type and constraints | Every field in `registrarmain`, `verifiermain`, etc. |
| `relationship()` | Defines associations between tables | `ima_policy`, `mb_policy` on `VerfierMain` |
| `ForeignKey` | Declares a column that references another table's primary key | `ima_policy_id → allowlists.id` |
| `PickleType` | Serializes Python objects into a column | Extended as `JSONPickleType` in Keylime |

SQLAlchemy's dialect system allows the same Python code to work across SQLite (development), PostgreSQL, and MySQL (production) without changes.

---

### What is Alembic?

**Alembic** is a database migration tool built specifically for SQLAlchemy. It manages **schema changes** (adding/removing tables, columns, constraints) in a versioned, repeatable way.

#### Why migrations are needed

When the codebase evolves (e.g., adding IAK/IDevID support), the database schema must change too. You can't just modify the Python class — existing databases in production already have the old schema. Alembic solves this by:

1. **Generating migration scripts** that describe each schema change as Python code
2. **Tracking** which migrations have been applied via an `alembic_version` table in the database
3. **Applying** pending migrations in order when the service starts up
4. **Supporting rollback** via `downgrade()` functions

#### How Keylime uses Alembic

Keylime's migration environment (`keylime/migrations/env.py`) is configured for **multi-database** operation — a single Alembic setup manages both the registrar and verifier databases:

```python
target_metadata = {
    "registrar": RegistrarBase.metadata,
    "cloud_verifier": VerifierBase.metadata
}
```

Each migration file contains separate `upgrade_registrar()` / `upgrade_cloud_verifier()` functions so that changes to each database are applied independently. Version tracking uses separate tables (`alembic_version_registrar`, `alembic_version_cloud_verifier`).

Example migration (adding the `sessions` table):

```python
def upgrade_cloud_verifier():
    op.create_table(
        "sessions",
        sa.Column("token", sa.String(length=22), nullable=False),
        sa.Column("agent_id", sa.String(length=80), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=True),
        sa.Column("nonce", sa.LargeBinary(), nullable=True),
        ...
        sa.ForeignKeyConstraint(["agent_id"], ["verifiermain.agent_id"]),
        sa.PrimaryKeyConstraint("token"),
    )

def downgrade_cloud_verifier():
    op.drop_table("sessions")
```

Keylime has **42 migration files** tracking the schema evolution from the initial two-table design to the current multi-table structure.

---

### What is JSONPickleType?

`JSONPickleType` is a **custom SQLAlchemy column type** used in Keylime to store complex Python data structures (dictionaries, lists) as JSON text in the database.

#### The problem it solves

Relational databases store scalar values (strings, integers, booleans) in columns. But Keylime needs to store structured data like:

```python
# TPM policy — a dictionary of PCR index → expected hash value
{"16": "0000000000000000000000000000000000000000"}

# Accepted algorithms — a list of strings
["sha256", "sha384", "sha512"]
```

These don't map directly to a single database column type.

#### How it works

`JSONPickleType` extends SQLAlchemy's built-in `PickleType` but replaces Python's `pickle` serializer with a JSON-based one:

```python
# In keylime/db/verifier_db.py and keylime/db/registrar_db.py
class JSONPickleType(PickleType):
    impl = Text       # Stored as a TEXT column in the database
    cache_ok = True   # Safe for SQLAlchemy's query caching
```

It uses `JSONPickler` (defined in `keylime/json.py`) as the serializer:

```python
class JSONPickler:
    @classmethod
    def dumps(cls, value, *_args, **_kwargs):
        return json.dumps(value)   # Python dict/list → JSON string

    @classmethod
    def loads(cls, value):
        return json.loads(value)   # JSON string → Python dict/list
```

#### Usage in column definitions

```python
# Column declaration
tpm_policy = Column(JSONPickleType(pickler=JSONPickler))
accept_tpm_hash_algs = Column(JSONPickleType(pickler=JSONPickler))
```

#### Data flow

```
Python dict                    Database TEXT column
{"sha256": "abc123"}    →      '{"sha256": "abc123"}'      (on write: json.dumps)
{"sha256": "abc123"}    ←      '{"sha256": "abc123"}'      (on read:  json.loads)
```

#### Why JSON instead of pickle?

Python's `pickle` module can serialize arbitrary Python objects but has serious drawbacks:
- **Security risk**: unpickling untrusted data can execute arbitrary code
- **Not human-readable**: binary format that can't be inspected in the database
- **Not portable**: tied to specific Python versions and class definitions

JSON avoids all of these issues while being sufficient for the dictionary and list data Keylime needs to store.
