# AI Security Gateway

An AI-assisted hands-on security lab demonstrating how a gateway can place enforceable controls between client applications and a local LLM inference backend.

The current implementation uses **LiteLLM**, **Microsoft Presidio**, **PostgreSQL**, **Ollama**, Docker Compose, and network policy to demonstrate and validate:

- scoped API-key access;
- model-level authorization;
- per-key rate limiting;
- pre-inference PII redaction;
- deterministic prompt keyword blocking;
- gateway-enforced reasoning suppression;
- restricted client access to the inference backend;
- container health monitoring; and
- reproducible validation with sanitized evidence.

This repository is a **lab implementation and reference project**, not a production-ready security product or security certification.

---

## Project Context

This project was developed iteratively as an **AI-assisted lab**.

The work included deploying and configuring the component technologies, troubleshooting integration issues, testing control behavior, identifying configuration weaknesses, hardening the deployment, validating security assumptions, and documenting the resulting architecture.

The project does not claim that the underlying gateway, Presidio, database, or inference technologies were developed from scratch.

The emphasis is on the security-engineering process:

```text
deploy
  → configure
  → observe
  → test
  → identify gaps
  → harden
  → regression test
  → document evidence
```

---

## 1. Security Objective

Direct application access to an LLM runtime creates several security and governance problems.

Examples include:

- sensitive data reaching model context;
- shared or unrestricted credentials;
- clients invoking models they were not intended to use;
- unbounded request consumption;
- direct access to the inference backend that bypasses gateway controls;
- inconsistent security policy across applications; and
- security settings that exist in configuration but have never been behaviorally tested.

This lab places a security enforcement layer between clients and Ollama:

```text
Client
   |
   | authenticated OpenAI-compatible request
   v
LiteLLM Gateway
   |
   | authentication
   | model authorization
   | rate policy
   | reasoning policy
   | prompt guardrails
   v
Microsoft Presidio
   |
   | tested PII transformation
   v
Ollama
   |
   v
Model response
```

PostgreSQL provides persistent LiteLLM control-plane metadata such as virtual-key configuration and related gateway data.

The database is not represented here as an inline stage through which prompts must pass.

---

## 2. Current Lab Architecture

```text
                         CLIENT TRUST ZONE
                  Representative client system
                              |
                              | TCP/4000
                              | scoped virtual key
                              v
+------------------------------------------------------------------+
|                     LiteLLM Security Gateway                     |
|                                                                  |
|  Authentication                                                  |
|  Model scope enforcement                                         |
|  Per-key RPM policy                                              |
|  Prompt keyword guardrail                                        |
|  Reasoning-output policy                                         |
|  Presidio pre-call integration                                   |
+------------------------------------------------------------------+
             |                                |
             | internal Docker network        | control-plane data
             v                                v
+----------------------------+        +----------------------------+
| Microsoft Presidio         |        | PostgreSQL                 |
|                            |        |                            |
| Analyzer                   |        | LiteLLM persistent         |
| Anonymizer                 |        | metadata                   |
+----------------------------+        +----------------------------+
             |
             | sanitized request path
             v
+------------------------------------------------------------------+
|                       Ollama Backend                             |
|                                                                  |
|                  qwen3.5:9b inference model                      |
+------------------------------------------------------------------+
```

### Network Enforcement

For the representative IPv4 client trust zone, the intended path is:

```text
Client → LiteLLM:4000 → Ollama:11434
```

The bypass path is blocked:

```text
Client ──X──> Ollama:11434
```

The gateway retains backend access:

```text
Gateway → Ollama:11434
```

This network restriction was behaviorally tested from the representative client network.

See [Network Validation](#9-network-trust-boundary-validation) for scope and limitations.

---

## 3. Security Controls

### Scoped Virtual Keys

LiteLLM virtual keys provide an application-facing identity separate from the gateway master credential.

The validated interactive client policy currently includes:

```text
Key alias:       portal-client-key
Authorized model: local-llama
Allowed routes:   llm_api_routes
RPM limit:        10
Max budget:       0.5
```

The actual key value is not stored in this repository.

The scoped client credential was also tested against an administrative route and was not permitted to use that route.

---

### Model-Level Authorization

The interactive client key is restricted to:

```text
local-llama
```

A request using the same key for:

```text
unauthorized-test-model
```

was rejected with:

```text
HTTP 403
```

This verifies the tested key-level model restriction.

---

### Per-Key Rate Limiting

The current interactive-client lab policy uses:

```text
10 requests per minute
```

The policy value is not presented as a universal or production-optimal threshold.

It is an initial operating value for the interactive lab client and should be tuned according to:

- workload type;
- model latency;
- concurrency;
- backend capacity;
- cost constraints; and
- organizational policy.

Separate workload classes should use separate keys and appropriately tuned limits.

A dedicated concurrent validation test demonstrated:

```text
11 concurrent requests

HTTP 200: 10
HTTP 429: 1
Other:    0
```

This demonstrates behavioral enforcement of the tested 10-RPM policy.

It is not a performance or capacity benchmark.

---

### Pre-Inference PII Redaction

Microsoft Presidio is integrated as a LiteLLM pre-call guardrail.

The validation suite uses synthetic values only:

```text
alice.testing@example.com
212-555-0198
```

Observed transformed values:

```text
<EMAIL_ADDRESS>
<PHONE_NUMBER>
```

The tested model path did not receive the original synthetic values.

This result demonstrates the tested email-address and phone-number examples only.

It does **not** establish that Presidio will detect:

- every PII type;
- every representation of PII;
- every language;
- intentionally obfuscated data; or
- adversarially constructed sensitive information.

---

### Prompt Keyword Guardrail

A deterministic LiteLLM content-filter guardrail is configured for selected blocked phrases.

One validation phrase is:

```text
SYSTEM OVERRIDE
```

The configured test phrase was rejected with:

```text
HTTP 400
```

A separate benign control prompt continued to return HTTP 200.

This demonstrates enforcement of the configured keyword policy.

It is **not** presented as comprehensive prompt-injection detection.

---

### Reasoning Suppression

The configured Ollama model can return model reasoning data.

The gateway therefore applies a custom LiteLLM pre-call policy that forces:

```text
reasoning_effort = none
```

The validation suite deliberately attempts to override the policy with:

```text
reasoning_effort = high
```

Observed result:

```text
reasoning_content: null
```

This demonstrates resistance to the tested client-side override.

The result applies to the current LiteLLM configuration and tested model path and should not be generalized automatically to every model or provider.

---

## 4. Components

### LiteLLM

LiteLLM provides the OpenAI-compatible gateway layer used in this lab for:

- API authentication;
- virtual-key management;
- model authorization;
- request-rate policy;
- model routing;
- guardrail orchestration; and
- integration with persistent PostgreSQL metadata.

The gateway is exposed on:

```text
TCP/4000
```

---

### Microsoft Presidio

The lab uses:

- **Presidio Analyzer** for detecting supported sensitive entities; and
- **Presidio Anonymizer** for transforming detected entities.

Both components communicate with LiteLLM through the Docker network.

Their application ports are **not published to the VM host** in the hardened configuration.

This was regression-tested to confirm that internal LiteLLM-to-Presidio communication continued to function after the unnecessary host exposure was removed.

---

### PostgreSQL

PostgreSQL provides persistent storage required by LiteLLM for gateway metadata.

The database is not exposed through a host port in the current Compose configuration.

Persistent data is stored in a Docker volume.

---

### Ollama

Ollama provides the inference backend.

The current model path is based on:

```text
qwen3.5:9b
```

The Ollama endpoint is supplied to the gateway through the environment rather than hard-coded into the committed configuration.

This allows the same repository configuration to be adapted to a different authorized Ollama host without committing local network information.

---

## 5. Repository Structure

```text
ai-security-gateway/
│
├── config/
│   ├── litellm_config.yaml
│   └── reasoning_policy.py
│
├── evidence/
│   └── README.md
│
├── tests/
│   ├── README.md
│   └── validate_gateway.sh
│
├── .env.example
├── .gitignore
├── docker-compose.yml
└── README.md
```

### `config/litellm_config.yaml`

Contains the gateway model definition and security-control configuration, including:

- Ollama model routing;
- Presidio pre-call integration;
- keyword filtering;
- LiteLLM runtime settings; and
- the reasoning-policy callback.

### `config/reasoning_policy.py`

Implements the gateway-side policy that overrides client-supplied reasoning settings before the request is forwarded upstream.

### `tests/`

Contains the reproducible functional validation suite and testing documentation.

### `evidence/`

Contains sanitized descriptions of observed validation results.

No API keys, passwords, `.env` contents, real PII, or other sensitive authentication material should be committed there.

---

## 6. Secrets and Environment Configuration

Copy the example environment file:

```bash
cp .env.example .env
```

The environment template defines settings for:

```text
POSTGRES_USER
POSTGRES_PASSWORD
POSTGRES_DB

LITELLM_MASTER_KEY
UI_USERNAME
UI_PASSWORD

OLLAMA_API_BASE
```

Replace all placeholder values before deployment.

Example:

```dotenv
POSTGRES_USER=litellm
POSTGRES_PASSWORD=change_me
POSTGRES_DB=litellm

LITELLM_MASTER_KEY=change_me
UI_USERNAME=admin
UI_PASSWORD=change_me

OLLAMA_API_BASE=http://YOUR_OLLAMA_HOST:11434
```

Never commit the populated `.env` file.

The repository `.gitignore` excludes:

```text
.env
.env.client
```

The client key used for validation is maintained separately from the server environment.

---

## 7. Container Deployment

The hardened Compose configuration includes:

- LiteLLM;
- PostgreSQL;
- Presidio Analyzer; and
- Presidio Anonymizer.

Start the stack with:

```bash
docker compose up -d
```

Check container status with:

```bash
docker compose ps
```

### Reproducible Container Images

The deployment does not use moving `latest` or `main-latest` image references for the validated runtime.

The following components are pinned to the exact image digests tested in the lab:

- LiteLLM;
- PostgreSQL;
- Presidio Analyzer; and
- Presidio Anonymizer.

Digest pinning prevents an upstream moving tag from silently changing the runtime represented by this repository.

It does not mean dependencies should never be upgraded.

A future upgrade should intentionally change the digest and then rerun regression validation.

---

## 8. Service Health

The deployment uses service health checks for:

- LiteLLM;
- PostgreSQL;
- Presidio Analyzer; and
- Presidio Anonymizer.

LiteLLM is tested through an internal HTTP readiness probe.

PostgreSQL is tested with `pg_isready`.

The Presidio container images provide their service health behavior.

A Docker container reporting:

```text
healthy
```

means the configured service-level health probe succeeds.

It does **not** prove that:

- end-to-end model inference works;
- PII redaction works;
- model authorization works;
- rate limiting works;
- network isolation works; or
- all gateway security policies work.

Those behaviors are tested independently.

---

## 9. Network Trust-Boundary Validation

Network enforcement is validated separately from the gateway-host test script.

Testing only from the gateway itself would not prove that a client cannot bypass the gateway.

The representative client validation confirmed:

```text
Client → LiteLLM TCP/4000
PASS

Client → Ollama TCP/11434
BLOCKED

Gateway → Ollama TCP/11434
PASS
```

For the tested IPv4 client trust zone, OPNsense policy prevents direct client access to the Ollama inference endpoint while preserving the authorized gateway path.

### Scope

This demonstrates the tested IPv4 network path.

It does not prove that every possible:

- interface;
- host;
- VLAN;
- route;
- alternate NIC; or
- layer-2 path

is restricted.

### IPv6 Limitation

The representative validation client had:

```text
no routable IPv6 interface address
no IPv6 route
```

Therefore, no routable IPv6 bypass existed from that client during testing.

The Ollama host was observed listening on IPv6.

Accordingly:

**IPv6 firewall enforcement has not been demonstrated.**

If routable IPv6 is introduced, the Ollama IPv6 path must be explicitly controlled and validated.

---

## 10. Reproducible Security Validation

The primary automated test is:

```text
tests/validate_gateway.sh
```

See:

```text
tests/README.md
```

for detailed instructions.

The script is run on the deployed Ubuntu gateway host and supports two modes.

### Normal Mode

```bash
./tests/validate_gateway.sh
```

The current validated run produced:

```text
PASS: 7
FAIL: 0
SKIP: 1
```

Normal mode tests:

1. gateway availability;
2. scoped-key authenticated inference;
3. reasoning suppression;
4. synthetic email and phone redaction;
5. configured prompt keyword blocking;
6. benign prompt control; and
7. unauthorized-model rejection.

Rate limiting is intentionally skipped during normal mode so exhausting the request quota does not interfere with other tests.

### Dedicated Rate-Limit Mode

Example for the current 10-RPM interactive-client policy:

```bash
sleep 65

VALIDATION_MODE=rate-limit \
EXPECTED_RPM_LIMIT=10 \
./tests/validate_gateway.sh
```

Validated result:

```text
HTTP 200: 10
HTTP 429: 1
Other:    0

PASS: 1
FAIL: 0
SKIP: 0
```

The expected RPM value is provided as a test input rather than embedded as a fixed policy assumption in the script.

---

## 11. Sanitized Evidence

Validation evidence is documented in:

```text
evidence/README.md
```

The evidence record distinguishes between:

- configured controls;
- behaviorally validated controls;
- scope limitations; and
- conditions not demonstrated.

The evidence directory must not contain:

- API keys;
- master keys;
- passwords;
- `.env` contents;
- real PII;
- credential hashes; or
- other sensitive authentication material.

---

## 12. Framework Alignment

Framework mappings in this project are intended to provide security-engineering context.

They are **not claims of formal compliance**.

### OWASP Top 10 for LLM Applications

| Area | Lab Control | Validation |
|---|---|---|
| Sensitive information disclosure | Presidio pre-call transformation of tested synthetic PII | Synthetic email and phone redaction validated |
| Unbounded consumption | Per-key RPM policy and budget metadata | 10-RPM enforcement behaviorally validated |
| Unauthorized model access / excessive privilege | Scoped virtual key restricted to `local-llama` and LLM API routes | Unauthorized model returned HTTP 403 |

The deterministic keyword rule provides an additional prompt boundary but is not characterized as comprehensive prompt-injection protection.

---

### NIST AI Risk Management Framework 1.0

The NIST AI RMF mappings are based on the actual wording and intent of the framework rather than renaming subcategories to match individual gateway controls.

#### MEASURE 2.1 — TEVV Documentation

NIST describes MEASURE 2.1 as documenting test sets, metrics, and details of tools used during test, evaluation, verification, and validation.

This project supports that outcome through:

- documented test objectives;
- reproducible validation procedures;
- explicit PASS/FAIL criteria;
- synthetic test inputs;
- documented tooling;
- sanitized observed results; and
- documented limitations.

Relevant repository artifacts:

```text
tests/README.md
tests/validate_gateway.sh
evidence/README.md
```

The mapping is therefore to the **validation methodology and documentation**, not simply to PII filtering or input inspection.

#### MANAGE 1.3 — Planned Responses to Prioritized AI Risks

NIST MANAGE 1.3 concerns developing, planning, and documenting responses to AI risks identified as high priority.

This lab demonstrates examples of technical risk responses including:

```text
Sensitive data exposure
    → pre-call PII transformation

Unrestricted client model access
    → scoped virtual-key authorization

Unbounded request consumption
    → per-key RPM controls

Gateway bypass
    → network restriction of direct inference access

Reasoning-content exposure
    → gateway-side reasoning policy
```

These technical controls can serve as documented risk-treatment responses in an AI risk-management process.

The project does not claim that implementing these controls alone satisfies MANAGE 1.3 or the NIST AI RMF as a whole.

---

### Least Privilege / Zero-Trust Security Pattern

The lab applies least-privilege principles through:

```text
client identity
    → scoped virtual key
    → permitted API routes
    → permitted model
    → bounded request rate
```

The tested network architecture further requires the representative client to use the gateway rather than directly accessing the Ollama backend over the validated IPv4 path.

This is a demonstrated architectural pattern, not a claim of organization-wide Zero Trust Architecture compliance.

---

## 13. Current Validation Status

| Control | Status | Scope / Qualification |
|---|---|---|
| Gateway availability | PASS | Tested LiteLLM HTTP endpoint |
| Scoped-key authentication | PASS | Interactive client key |
| Authorized model inference | PASS | `local-llama` |
| Reasoning suppression | PASS | Explicit client override attempted |
| Synthetic email redaction | PASS | Tested synthetic example |
| Synthetic phone redaction | PASS | Tested synthetic example |
| Keyword guardrail | PASS | Configured test phrase |
| Benign prompt control | PASS | Unrelated benign request |
| Model scope restriction | PASS | Unauthorized model request |
| Stored 10-RPM policy | PASS | Independently verified |
| 10-RPM enforcement | PASS | Concurrent 11-request validation |
| Client → LiteLLM path | PASS | Tested IPv4 client |
| Direct client → Ollama restriction | PASS | Tested IPv4 trust zone |
| Gateway → Ollama path | PASS | Tested backend path |
| Presidio host-port removal | PASS | Internal connectivity retained |
| Docker health checks | PASS | Current deployed services |
| Pinned container runtime | PASS | Regression-tested digests |
| IPv6 enforcement | LIMITED | No routable IPv6 on tested client |

`PASS` means the stated behavior was observed under the documented lab conditions.

`LIMITED` means the condition was examined, but complete enforcement was not demonstrated.

---

## 14. Security Findings Identified During Hardening

The hardening process itself produced several useful engineering findings.

### Configuration Drift

The initially committed configuration and the working VM deployment had diverged.

**Response:**

```text
runtime behavior
    → reconcile Git configuration
    → externalize environment-specific values
    → regression test
```

The repository is now intended to remain the configuration source of truth.

---

### Ineffective Keyword Configuration

An initially configured keyword setting did not block the expected prompt.

Testing demonstrated:

```text
configured control ≠ validated control
```

The configuration was replaced with a LiteLLM content-filter guardrail supported by the deployed LiteLLM version.

Blocked and benign test cases were then validated.

---

### Reasoning Default Was Not Enforcement

Setting the model default to:

```text
reasoning_effort: none
```

suppressed reasoning during ordinary requests but could be overridden by a client requesting:

```text
reasoning_effort: high
```

A gateway-side pre-call policy was therefore added to overwrite the client value.

Regression testing then confirmed:

```text
client requests high reasoning
        ↓
gateway overwrites policy
        ↓
reasoning_content: null
```

This illustrates the difference between a default setting and an enforced policy.

---

### Unnecessary Presidio Host Exposure

Presidio services initially had host-published ports even though LiteLLM communicated with them through the internal Docker network.

The host mappings were removed.

Validation then confirmed:

```text
former host Presidio ports
    → inaccessible

LiteLLM → Presidio
    → functional

PII regression test
    → PASS
```

---

### Moving Container Tags

Moving image references reduce reproducibility because the same repository configuration can retrieve a different runtime later.

The validated container versions were therefore pinned by digest.

---

### Sequential Rate-Limit Testing Was Inconclusive

An early rate-limit test sent requests sequentially.

At the updated 10-RPM policy, all 11 requests could succeed because request timing could cross a limiter window.

The validation was redesigned as a concurrent burst:

```text
10-RPM policy
    +
11 concurrent requests
    →
10 accepted + 1 rejected
```

The test methodology was corrected rather than incorrectly concluding that the security control had failed.

---

## 15. Engineering Takeaways

### Configuration Is Not Evidence

A YAML setting proves only that a setting exists.

It does not prove that the deployed software interprets or enforces it as expected.

Controls in this lab are therefore distinguished as:

```text
configured
    → tested
    → behavior observed
    → evidence documented
```

---

### Defaults Are Not Security Boundaries

A client-controllable parameter can defeat a default.

Security-sensitive behavior should be enforced at a trusted boundary when possible.

---

### Test the Negative Path

Successful model inference proves that the system works.

Security validation also requires testing what should **not** work:

```text
unauthorized model
    → denied

blocked phrase
    → denied

direct client → Ollama
    → denied

request above rate threshold
    → denied
```

---

### Test Controls Independently

Combining unrelated tests can create false failures.

Rate limiting originally interfered with PII and benign-prompt validation.

The final suite therefore separates normal functional/security testing from intentional rate exhaustion.

---

### Scope Security Claims Narrowly

A successful synthetic email test does not prove universal PII protection.

A blocked IPv4 route does not prove IPv6 protection.

A healthy container does not prove a functioning security control.

The documentation intentionally states what was actually tested and identifies what remains outside that scope.

---

## 16. Known Limitations

This project currently does not demonstrate:

- comprehensive prompt-injection detection;
- universal PII detection;
- output-side PII filtering for every response path;
- full IPv6 network enforcement;
- production-scale throughput;
- high availability;
- clustered gateway operation;
- production secret-management integration;
- enterprise identity-provider integration;
- full SIEM integration;
- formal penetration testing;
- formal compliance assessment; or
- production-readiness certification.

These are potential future extensions, not current capabilities.

---

## 17. Lab vs. Production

This repository demonstrates security patterns in a controlled lab.

A production deployment would require additional engineering appropriate to its environment, potentially including:

- managed secret storage;
- certificate-based TLS;
- enterprise identity integration;
- hardened network segmentation;
- centralized logging and detection;
- backup and recovery;
- availability engineering;
- dependency vulnerability management;
- change control;
- performance testing;
- expanded adversarial testing; and
- operational monitoring.

No claim is made that the current lab configuration should be deployed unchanged into a production environment.

---

## 18. Validation Philosophy

The guiding principle of this project is:

> **Do not document a security control as working merely because it appears in configuration. Test the behavior that the control is supposed to enforce.**

The repository therefore pairs implementation artifacts with reproducible tests and sanitized evidence:

```text
configuration
      +
validation procedure
      +
observed result
      +
documented limitation
      =
defensible lab evidence
```

For validation procedures, see:

```text
tests/README.md
```

For sanitized results, see:

```text
evidence/README.md
```