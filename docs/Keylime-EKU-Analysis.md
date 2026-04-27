# Keylime Verifier — EKU (Extended Key Usage) Analysis

Investigation into whether the keylime verifier has an EKU enable/disable option for server certificate validation.

---

## Finding: No EKU Config Option Exists

There is no EKU enable/disable configuration option in the verifier (or any keylime component).

---

## How TLS Certificate Validation Works in Keylime

### Layer 1: Keylime's Own CA Does Not Set EKU

`mk_signed_cert()` in `keylime/ca_impl_openssl.py` generates server/client certificates but never adds an `ExtendedKeyUsage` extension. The extensions it adds are:

- Netscape Comment
- Subject Alternative Name (SAN)
- CRL Distribution Points
- Authority Key Identifier

No `x509.ExtendedKeyUsage` anywhere in the certificate generation code.

### Layer 2: Python's SSL Context Does EKU Checking

When the verifier connects to an agent, `generate_tls_context()` in `keylime/web_util.py` calls:

```python
context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
```

`ssl.Purpose.SERVER_AUTH` maps to OID `1.3.6.1.5.5.7.3.1` (TLS Web Server Authentication). Under the hood, this tells OpenSSL to verify that the server certificate has the Server Authentication EKU — **but only if the certificate has an EKU extension at all**. If the certificate has no EKU extension (which is the case with keylime's self-generated certs), OpenSSL treats it as "any purpose" and the check passes.

In practice, EKU validation is a no-op for keylime's own certificates.

### Layer 3: The Only Indirect Control — `trusted_server_ca`

The closest thing to an EKU toggle is the `trusted_server_ca` config option:

```ini
[verifier]
trusted_server_ca = default          # Verify agent cert against keylime's CA
trusted_server_ca = all              # Disable ALL server cert verification (including EKU)
trusted_server_ca = /path/to/ca.crt  # Verify against a custom CA
```

When set to `all`, `get_tls_options()` in `keylime/web_util.py` sets `verify_peer_certificate = False`, which skips `context.verify_mode = ssl.CERT_REQUIRED` entirely — no cert chain validation, no EKU check, nothing. The code warns about this:

```python
if not verify_server:
    logger.warning(
        "'enable_agent_mtls' is 'True', but 'trusted_server_ca' is set as 'all', "
        "which disables server certificate verification"
    )
```

### Layer 4: Hostname Checking is Disabled

```python
context.check_hostname = False  # "We do not use hostnames as part of our authentication"
```

This is intentional — keylime's trust model is based on TPM identity, not DNS/hostname binding.

---

## EKU Requirements by Role (from Authorization Provider Documentation)

The `SimpleAuthProvider` in `keylime/authorization/providers/simple.py` documents the expected EKU per role:

| Role | Certificate Requirement |
|---|---|
| Pull mode agents | Self-signed server certs are acceptable (trust comes from TPM quote). If CA-issued, must have Server Authentication EKU only |
| Push mode agents | No client certs from trusted CA. Authentication is via PoP (Proof-of-Possession) bearer tokens only |
| Admins | Client certs signed by trusted CA with Client Authentication EKU |

These are **documented expectations**, not enforced by code. The authorization provider checks identity type (agent vs admin) based on whether a PoP token or mTLS certificate is presented, but does not inspect the EKU extension on the certificate itself.

---

## Summary

| What | Status |
|---|---|
| Explicit EKU enable/disable config option | Does not exist |
| EKU extension on keylime-generated certs | Not set (no `ExtendedKeyUsage` in `mk_signed_cert`) |
| OpenSSL EKU enforcement | Only triggers if the cert has an EKU extension; keylime's certs don't, so it's effectively a no-op |
| Way to disable all cert validation (including EKU) | `trusted_server_ca = all` — but this disables all verification, not just EKU |

---

## Practical Impact

If you are using **keylime's self-generated certificates** (the default), EKU is irrelevant — the certs don't have the extension, so OpenSSL skips the check.

If you are using **externally-issued certificates** (e.g., from an enterprise CA) that have an EKU extension set to something other than Server Authentication, you will hit EKU validation failures. The only current workaround is `trusted_server_ca = all`, which disables all verification — there is no way to selectively disable just EKU checking.

---

## Source Files Referenced

| File | Relevance |
|---|---|
| `keylime/ca_impl_openssl.py` | Certificate generation — no EKU extension added |
| `keylime/web_util.py` | TLS context creation (`generate_tls_context`, `generate_agent_tls_context`, `get_tls_options`) |
| `keylime/authorization/providers/simple.py` | Documents EKU expectations per role |
| `keylime/web/base/action_handler.py` | Documents certificate requirements in authentication logic |
