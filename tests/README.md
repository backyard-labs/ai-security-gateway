# AI Security Gateway Validation Tests

This directory contains reproducible tests used to validate security controls and expected behavior of the AI Security Gateway.

The tests are intended to verify deployed behavior, not merely the presence of configuration settings.

## Test Environment

The Git repository is the source of truth for the project configuration, test scripts, and documentation.

The current validation environment uses:

- **Windows workstation** — Git working copy and project source
- **Ubuntu gateway VM (`secai-gw-01`)** — deployed Docker Compose runtime and validation host
- **Ollama host** — local inference backend
- **Representative LAN client** — used for network trust-boundary validation
- **OPNsense** — enforces the tested client-to-inference network policy

`validate_gateway.sh` is executed on the Ubuntu gateway VM against the deployed LiteLLM gateway.

A cloned copy of this repository does not, by itself, provide a runnable validation environment. The gateway and its supporting services must first be deployed and configured.

## Test Principles

- Use synthetic test data only.
- Never store API keys, passwords, `.env` contents, or other secrets in test output.
- Do not use real personally identifiable information (PII).
- A configured control is not considered validated until its expected behavior is observed.
- Tests should produce a clear PASS or FAIL result where practical.
- Tests should avoid modifying persistent application data unless the test explicitly requires it.
- Rate-limit policy values are supplied to the test as inputs rather than hard-coded into the validation logic.
- Test results apply to the specific controls, models, configurations, and network paths exercised during validation.

## Validation Script

The primary automated validation script is:

```text
tests/validate_gateway.sh
```

The script supports two modes:

- `normal`
- `rate-limit`

The scoped LiteLLM client key must be loaded into the shell environment as:

```text
LITELLM_API_KEY
```

The script does not print the key.

---

## Normal Validation Mode

Run this test on the Ubuntu gateway VM (`secai-gw-01`) from:

```text
~/ai-security-gateway
```

First load the scoped client key without displaying it:

```bash
set -a
source .env.client
set +a
```

Then run:

```bash
./tests/validate_gateway.sh
```

Normal mode validates the following controls.

### 1. Gateway Availability

**Objective:** Confirm that the LiteLLM service is reachable.

**PASS:** The gateway returns HTTP 200.

### 2. Authenticated Inference

**Objective:** Confirm that a valid scoped client key can invoke the authorized model through LiteLLM.

**PASS:** The request returns HTTP 200 and the expected model response.

### 3. Reasoning Suppression

**Objective:** Confirm that gateway policy suppresses model reasoning output even when the client explicitly requests elevated reasoning.

The test deliberately requests:

```text
reasoning_effort: high
```

**PASS:** The request succeeds and `reasoning_content` remains null.

This validates the tested LiteLLM gateway policy and configured model path. It should not be interpreted as a universal guarantee for every model or provider.

### 4. Synthetic PII Redaction

**Objective:** Confirm that Presidio transforms the tested synthetic PII before the request reaches the model.

Synthetic test values:

```text
alice.testing@example.com
212-555-0198
```

**PASS:** The response contains redaction placeholders:

```text
<EMAIL_ADDRESS>
<PHONE_NUMBER>
```

and does not contain the original synthetic values.

This test demonstrates the tested email and phone-number entity types only. It does not establish that every possible form of PII will be detected or redacted.

### 5. Prompt Keyword Guardrail

**Objective:** Confirm that a configured blocked prompt pattern is rejected before inference.

The validation uses the configured test phrase:

```text
SYSTEM OVERRIDE
```

**PASS:** The request is rejected with HTTP 400.

This validates enforcement of the configured keyword rule. It should not be interpreted as general prompt-injection detection.

### 5a. Benign Prompt Control

**Objective:** Confirm that the keyword guardrail does not block an unrelated benign test prompt.

**PASS:** The benign request returns HTTP 200 and the expected response.

The blocked and benign tests are evaluated together to distinguish basic keyword enforcement from a general inference failure.

### 6. Model Scope Restriction

**Objective:** Confirm that the scoped client key cannot invoke a model outside its authorized model list.

The test attempts to invoke:

```text
unauthorized-test-model
```

**PASS:** The unauthorized model request is rejected with HTTP 403.

Successful authenticated inference through `local-llama` is tested separately during the same normal validation suite.

### 7. Rate Limiting

Rate limiting is intentionally not exercised during normal mode.

Normal mode reports the rate-limit test as:

```text
SKIP
```

Deliberately exhausting the client's request quota during the normal suite could interfere with validation of the other controls.

Rate limiting is therefore validated independently using dedicated rate-limit mode.

---

## Dedicated Rate-Limit Mode

Run this test on the Ubuntu gateway VM (`secai-gw-01`) from:

```text
~/ai-security-gateway
```

Ensure the scoped client key has been loaded into the shell environment.

Allow the previous rate-limit window to clear before beginning the dedicated test.

Example for the current interactive-client policy:

```bash
sleep 65

VALIDATION_MODE=rate-limit \
EXPECTED_RPM_LIMIT=10 \
./tests/validate_gateway.sh
```

`EXPECTED_RPM_LIMIT` is supplied as a policy input so the validation logic is not tied to a fixed RPM value.

The script sends:

```text
EXPECTED_RPM_LIMIT + 1
```

concurrent authenticated inference requests.

For a 10 RPM policy, the script therefore sends 11 concurrent requests.

Expected behavior:

```text
HTTP 200: 10
HTTP 429: 1
Other:    0
```

**PASS:** Exactly the expected number of requests are accepted and at least one request exceeding the configured threshold is rejected with HTTP 429.

Concurrent requests are used because sequential requests can cross rate-limit timing boundaries and produce an inconclusive result.

This test demonstrates behavioral enforcement of the configured per-key RPM threshold under the tested conditions. It is not a performance, throughput, concurrency, or capacity benchmark.

---

## Current Validated Interactive-Key Policy

The current lab policy for the scoped interactive client key is:

```text
Key alias:       portal-client-key
Models:          local-llama
Allowed routes:  llm_api_routes
RPM limit:       10
Max budget:      0.5
```

The stored policy was independently verified through the LiteLLM key-management API.

Behavioral validation separately confirmed that a concurrent burst against the 10 RPM policy allowed 10 requests and rejected the additional request with HTTP 429.

The 10 RPM value is an initial lab operating threshold for an interactive client. It is not presented as a production benchmark or universally optimal rate.

Different workload classes should use separate scoped keys and workload-appropriate limits.

---

## Network Trust-Boundary Validation

Network-path controls are not tested by `validate_gateway.sh`.

They require testing from a representative client network because testing only from the gateway host would not demonstrate enforcement of the client trust boundary.

The validated IPv4 path is:

```text
Representative client
        |
        | TCP/4000 allowed
        v
LiteLLM Gateway
        |
        | TCP/11434 allowed
        v
Ollama Backend
```

Direct client access to the Ollama inference endpoint is blocked by network policy:

```text
Representative client
        |
        | TCP/11434 blocked
        X
Ollama Backend
```

The network validation procedure confirms:

1. The designated client can reach LiteLLM on TCP/4000.
2. The same client cannot directly reach Ollama on TCP/11434.
3. The gateway host can reach the Ollama backend on TCP/11434.

### IPv4 Scope

For the tested client trust zone, OPNsense policy prevents direct IPv4 client access to the Ollama backend on TCP/11434 while retaining client access to LiteLLM and gateway access to Ollama.

This demonstrates the tested network path. It does not prove that every possible network path or interface is restricted.

### IPv6 Limitation

The representative LAN client used during validation had no routable IPv6 address or IPv6 route.

Therefore, no active IPv6 bypass path existed from that tested client during validation.

However, the Ollama host was observed listening on IPv6 as well as IPv4.

IPv6 firewall enforcement has **not** been demonstrated and should not be assumed if routable IPv6 networking is enabled later.

---

## Service Health Validation

Docker service health is monitored separately from the functional security-control tests.

The deployment includes health checks for:

- LiteLLM
- PostgreSQL
- Presidio Analyzer
- Presidio Anonymizer

A healthy container state demonstrates that the configured service-level health probe succeeds.

It does **not** by itself prove:

- successful end-to-end inference
- Presidio redaction behavior
- model authorization
- rate-limit enforcement
- prompt guardrail enforcement
- Ollama backend reachability from every path

Those behaviors are validated separately.

---

## Reproducibility

The deployment uses container images pinned to validated image digests rather than moving `latest` or `main-latest` tags.

This improves reproducibility by preventing an upstream image tag from silently changing the tested runtime version.

Digest pinning does not eliminate the need for future upgrade testing. Updating a pinned dependency should be treated as a deliberate change followed by regression validation.

---

## Evidence

Sanitized validation results may be stored under:

```text
evidence/
```

Evidence must not contain:

- API keys
- passwords
- `.env` contents
- real PII
- sensitive authentication material

Evidence should identify:

- what was tested
- expected behavior
- observed behavior
- PASS, FAIL, or limitation
- relevant scope or qualification

Raw authentication material should never be committed to the repository.

---

## Current Validation Status

The current deployed lab has demonstrated the following tested behavior:

| Control | Status | Scope |
|---|---|---|
| Gateway availability | PASS | LiteLLM HTTP endpoint |
| Scoped-key authenticated inference | PASS | `local-llama` |
| Reasoning suppression | PASS | Client override attempt tested |
| Synthetic email redaction | PASS | Presidio email entity |
| Synthetic phone redaction | PASS | Presidio phone entity |
| Prompt keyword blocking | PASS | Configured blocked phrase |
| Benign prompt control | PASS | Unrelated benign prompt |
| Model scope restriction | PASS | Unauthorized model request |
| Per-key rate limiting | PASS | 10 RPM concurrent test |
| Client direct Ollama restriction | PASS | Tested IPv4 trust zone |
| Gateway-to-Ollama connectivity | PASS | Tested IPv4 backend path |
| IPv6 client bypass review | LIMITED | No routable IPv6 on tested client |
| Service health checks | PASS | Deployed Docker services |

A PASS indicates that the described behavior was observed under the tested lab conditions. It should not be interpreted as a universal security guarantee or production certification.