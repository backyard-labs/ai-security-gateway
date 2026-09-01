# AI Security Gateway — Validation Evidence

This directory contains sanitized evidence from functional and security-control validation of the AI Security Gateway lab.

The purpose of this evidence is to document **observed behavior** of the deployed system without storing credentials, authentication material, real PII, or other sensitive data.

## Evidence Handling

The evidence in this repository follows these rules:

- Synthetic test data only.
- No API keys or key hashes.
- No passwords.
- No `.env` or `.env.client` contents.
- No real personally identifiable information.
- No sensitive authentication material.
- Results distinguish observed behavior from configuration intent.
- Limitations and untested conditions are documented rather than assumed.

---

## Validation Environment

Validation was performed against the deployed lab environment consisting of:

- LiteLLM security gateway
- Microsoft Presidio Analyzer
- Microsoft Presidio Anonymizer
- PostgreSQL
- Ollama inference backend
- Ubuntu gateway VM
- Representative LAN client
- OPNsense network enforcement

Container dependencies used by the gateway deployment were pinned to validated image digests before final regression testing.

---

## Automated Gateway Validation

Validation script:

```text
tests/validate_gateway.sh
```

### Normal Mode

Command:

```bash
./tests/validate_gateway.sh
```

Observed summary:

```text
AI Security Gateway Validation v3
Mode: normal

Gateway availability
PASS

Authenticated inference
PASS

Reasoning suppression
PASS

Synthetic PII redaction
PASS

Prompt keyword guardrail
PASS

Benign prompt control
PASS

Model scope restriction
PASS

Rate limiting
SKIP — validated separately

Validation Summary
PASS: 7
FAIL: 0
SKIP: 1
```

### Interpretation

The normal validation suite demonstrated that:

- the LiteLLM gateway was reachable;
- the scoped client key could invoke its authorized model;
- client attempts to request reasoning output were overridden by gateway policy;
- tested synthetic email and phone values were redacted;
- a configured blocked keyword was rejected;
- an unrelated benign prompt remained permitted; and
- the scoped client key could not invoke an unauthorized model.

These results apply to the tested configuration and model path.

---

## Synthetic PII Redaction

Synthetic values used during validation:

```text
alice.testing@example.com
212-555-0198
```

Observed transformed values:

```text
<EMAIL_ADDRESS>
<PHONE_NUMBER>
```

Result:

```text
PASS
```

The original synthetic email address and phone number were not present in the validated model response.

### Scope

This demonstrates detection/redaction behavior for the tested email and phone-number examples.

It does **not** establish detection coverage for every PII entity type, format, language, or adversarial input.

---

## Reasoning Suppression

The client deliberately attempted to request:

```text
reasoning_effort: high
```

Observed result:

```text
reasoning_content: null
```

Result:

```text
PASS
```

This demonstrates that the tested client override was suppressed by the deployed gateway policy.

The result applies to the tested LiteLLM configuration and model path and is not presented as a universal guarantee for other models or providers.

---

## Prompt Keyword Guardrail

Blocked test phrase:

```text
SYSTEM OVERRIDE
```

Observed result:

```text
HTTP 400
```

Result:

```text
PASS
```

A separate benign control prompt returned HTTP 200.

This demonstrates enforcement of the configured keyword rule while confirming that ordinary inference remained functional.

It is not evidence of comprehensive prompt-injection detection.

---

## Model Scope Restriction

The scoped client key was authorized for:

```text
local-llama
```

The validation suite attempted to invoke:

```text
unauthorized-test-model
```

Observed result:

```text
HTTP 403
```

Result:

```text
PASS
```

This demonstrates enforcement of the tested key-level model restriction.

---

## Interactive Client-Key Policy

Sanitized policy metadata:

```text
Key alias:       portal-client-key
Models:          local-llama
Allowed routes:  llm_api_routes
RPM limit:       10
Max budget:      0.5
```

The stored 10 RPM policy was independently verified through the LiteLLM key-management API.

No API key value or key hash is included in this evidence.

---

## Rate-Limit Enforcement

Dedicated rate-limit validation was performed separately from the normal test suite.

Test input:

```text
EXPECTED_RPM_LIMIT=10
```

The test generated 11 concurrent authenticated inference requests.

Observed result:

```text
HTTP 200: 10
HTTP 429: 1
Other:    0
```

Result:

```text
PASS
```

### Interpretation

The deployed gateway behaviorally enforced the tested 10 RPM scoped-key policy during the concurrent validation burst.

The 10 RPM value is an initial lab operating threshold for the interactive client key.

This test is **not** a throughput, concurrency, latency, capacity, or production-performance benchmark.

---

## Network Trust-Boundary Validation

The tested network policy was:

```text
Representative LAN client
        |
        | TCP/4000
        v
LiteLLM Gateway
        |
        | TCP/11434
        v
Ollama Backend
```

while direct client access to the backend was intended to be blocked:

```text
Representative LAN client
        |
        | TCP/11434
        X
Ollama Backend
```

### Observed IPv4 Results

```text
Client -> LiteLLM TCP/4000
PASS — reachable

Client -> Ollama TCP/11434
PASS — direct access blocked

Gateway -> Ollama TCP/11434
PASS — backend reachable
```

Result:

```text
PASS
```

### Scope

The result demonstrates the tested IPv4 trust boundary for the representative client network.

It does not establish that every possible interface, route, or network segment is restricted.

---

## IPv6 Review

The representative client used during network validation had:

```text
No routable IPv6 interface address
No IPv6 route
```

Therefore, no active IPv6 path to the Ollama backend existed from that client during testing.

The Ollama host was observed listening on IPv6.

Result:

```text
LIMITED
```

### Limitation

IPv6 firewall enforcement was not demonstrated.

If routable IPv6 is enabled later, the Ollama backend's IPv6 exposure must be reviewed and tested separately.

---

## Presidio Host Exposure

Presidio Analyzer and Presidio Anonymizer were initially exposed through host port mappings during development.

The unnecessary host mappings were removed.

Post-change validation demonstrated:

```text
VM host -> former Presidio host ports
UNREACHABLE

LiteLLM -> Presidio Analyzer internal service
HTTP 200

LiteLLM -> Presidio Anonymizer internal service
HTTP 200
```

Synthetic PII redaction was subsequently regression-tested successfully.

Result:

```text
PASS
```

This demonstrates that the unnecessary host exposure was removed while required internal service communication remained functional.

---

## Service Health

The deployed Docker services reported healthy after health checks were configured or verified for:

```text
LiteLLM
PostgreSQL
Presidio Analyzer
Presidio Anonymizer
```

Result:

```text
PASS
```

Container health is treated as operational evidence only.

A healthy container does not by itself demonstrate successful inference or enforcement of security controls; those behaviors are tested separately.

---

## Container Reproducibility

Moving container tags were replaced with the exact image digests used during validation.

Pinned components include:

- LiteLLM
- PostgreSQL
- Presidio Analyzer
- Presidio Anonymizer

After digest pinning, authenticated inference was regression-tested successfully.

Result:

```text
PASS
```

Digest pinning improves reproducibility but does not remove the need to test future dependency upgrades.

---

## Validation Summary

| Control | Result | Qualification |
|---|---|---|
| Gateway availability | PASS | Tested LiteLLM endpoint |
| Scoped-key authentication | PASS | Tested interactive client key |
| Authorized inference | PASS | `local-llama` |
| Reasoning suppression | PASS | Explicit client override tested |
| Synthetic email redaction | PASS | Tested synthetic example |
| Synthetic phone redaction | PASS | Tested synthetic example |
| Prompt keyword blocking | PASS | Configured test phrase |
| Benign prompt control | PASS | Tested benign request |
| Model scope restriction | PASS | Unauthorized model request |
| 10 RPM enforcement | PASS | Concurrent 11-request test |
| Client-to-LiteLLM network path | PASS | Tested IPv4 client |
| Direct client-to-Ollama restriction | PASS | Tested IPv4 client |
| Gateway-to-Ollama path | PASS | Tested backend path |
| IPv6 enforcement | LIMITED | No routable IPv6 on test client |
| Presidio host-port removal | PASS | Internal connectivity retained |
| Docker service health | PASS | Operational health probes |
| Pinned container runtime | PASS | Regression-tested deployment |

---

## Interpretation of Results

A `PASS` means the described behavior was observed under the documented lab conditions.

A `LIMITED` result means the condition was reviewed but the environment did not permit complete enforcement testing.

These results are validation evidence for a lab implementation. They are not a security certification, penetration-test attestation, production-readiness determination, or guarantee against untested attack paths.