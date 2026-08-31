# Production AI Security Gateway & Guardrail Architecture

An enterprise reference implementation and educational guide for deploying an **AI Security Gateway** sitting between client applications and large language model backends. This gateway enforces **inline PII redaction**, **virtual API key governance**, **least-privilege model scoping**, and **edge rate limiting** to mitigate critical vulnerabilities outlined in the OWASP Top 10 for LLMs and the NIST AI Risk Management Framework (AI RMF 1.0).

---

## 1. Executive Summary & Educational Objectives

Modern enterprises face significant architectural challenges when adopting generative AI:
* **Sensitive Data Ingestion:** Users and applications inadvertently transmit personally identifiable information (PII), credentials, or proprietary intellectual property into foundational models (OWASP LLM02: Sensitive Information Disclosure).
* **Unbounded Resource Exhaustion:** Unrestricted query loops, denial-of-wallet vectors, or distributed requests overwhelm inference backends, leading to systemic compute degradation and massive API bills (OWASP LLM10: Unbounded Consumption).
* **Flat Context Control:** Direct client connections to model endpoints lack central auditing, token tracking, uniform authentication, and runtime enforcement boundaries.

This project implements a **Defensive Gateway Architecture** designed to act as an inline security enforcement proxy. By decoupling client interfaces from raw model runtimes, the gateway transparently analyzes, sanitizes, meters, and routes all prompt payloads before they ever reach the underlying neural inference engine.

---

## 2. Architectural Blueprint & Data Flow

```text
+-----------------------------------------------------------------------------------+
| 1. CLIENT CONSUMPTION LAYER                                                       |
|    - Open WebUI, Enterprise Chatbots, SOC Automation Scripts, Low-Code Pipelines  |
+-----------------------------------------------------------------------------------+
                                          |
                        HTTP POST /v1/chat/completions
                        Authorization: Bearer <scoped_virtual_key>
                                          v
+-----------------------------------------------------------------------------------+
| 2. AI SECURITY GATEWAY (LiteLLM Reverse Proxy)                                    |
|    * Edge Authentication: Validates virtual key against persistent metadata DB    |
|    * Rate Limiting & Quotas: Enforces Requests-Per-Minute (RPM) and token limits  |
|    * Routing & Isolation: Determines downstream model routing rules               |
+-----------------------------------------------------------------------------------+
                                          |
                      Asynchronous Pre-Call Interception
                                          v
+-----------------------------------------------------------------------------------+
| 3. INLINE DATA PROTECTION ENGINE (Microsoft Presidio)                             |
|    * Presidio Analyzer: Named-Entity Recognition (NER) scans for SSN, PII, etc.   |
|    * Presidio Anonymizer: Sanitizes sensitive tokens into structured generic masks|
+-----------------------------------------------------------------------------------+
                                          |
                       Sanitized & Verified Prompt Only
                                          v
+-----------------------------------------------------------------------------------+
| 4. PERSISTENT STORAGE & AUDIT                                                     |
|    * PostgreSQL DB: Stores forensic audit trails, virtual keys, and usage metrics |
+-----------------------------------------------------------------------------------+
                                          |
                          Forward Sanitized Request
                                          v
+-----------------------------------------------------------------------------------+
| 5. INFERENCE RUNTIME (Backend Engine)                                             |
|    * Host-Isolated Inference Node (e.g., Ollama / vLLM / External Foundation API) |
+-----------------------------------------------------------------------------------+

---

## 3. Threat Modeling & Framework Alignment

| Security Framework | Control / ID | Threat Vector | Technical Gateway Implementation |
| :--- | :--- | :--- | :--- |
| **OWASP Top 10 for LLMs** | **LLM02** | **Sensitive Information Disclosure** | Pre-call callback dispatches raw text to Microsoft Presidio Analyzer/Anonymizer to redact PII prior to model ingestion. |
| **OWASP Top 10 for LLMs** | **LLM10** | **Unbounded Consumption** | Virtual keys enforce edge rate limits (RPM/TPM) and strict dollar/token budgets to prevent compute exhaustion. |
| **NIST AI RMF 1.0** | **MEASURE 2.1** | **Input Validation & Safety** | Automated inspection of raw user prompts at the ingestion boundary before inference. |
| **NIST AI RMF 1.0** | **MANAGE 1.3** | **Resource Governance** | Systematic compute quotas, client isolation, and automated telemetry tracking. |
| **Zero Trust Architecture** | **Least Privilege** | **Direct Model Access Exposure** | Direct model network ports are inaccessible to client applications; all traffic requires authenticated, scoped proxy tokens. |

---

## 4. Component Deep Dive

### A. LiteLLM Proxy Core
LiteLLM serves as the central API gateway translating universal OpenAI-compatible API requests into downstream provider payloads. It enforces access control lists (ACLs), manages virtual credentials, tracks per-token spending, and coordinates pre-call and post-call security hooks.

### B. Microsoft Presidio Analyzer & Anonymizer
Microsoft Presidio is an open-source data protection framework.
* **Analyzer:** Leverages pattern matching (regex) and natural language processing (spaCy NER models) to detect sensitive entities such as names, email addresses, phone numbers, IP addresses, credit cards, and social security numbers.
* **Anonymizer:** Replaces identified sensitive substrings with configurable masks (e.g., replacing a real person's name with `<PERSON>` or masking an SSN as `***-**-****`).

### C. Persistent Telemetry & Audit Layer (PostgreSQL)
All transaction metadata—including virtual key identities, latency metrics, token consumption, and timestamped forensic logs—is committed to an isolated PostgreSQL relational store. This provides accountability without storing unredacted sensitive payloads.

---

ai-security-gateway/
├── config/
│   └── litellm_config.yaml    # Gateway routing policies, callback hooks, and settings
├── docs/                      # Reference diagrams, threat models, and architecture specs
├── .env.example               # Environment variables template for database and master keys
├── .gitignore                 # Exclusion list preventing secrets/databases from entering Git
├── docker-compose.yml         # Container orchestration manifest for all gateway services
└── README.md                  # Comprehensive documentation and operational guide

---

## 6. Configuration & Deployment Guide

### Prerequisites
* Docker Engine (v24.0+) & Docker Compose (v2.0+)
* Model inference engine running locally (e.g., Ollama running on host at port 11434) or accessible upstream endpoint

### Step 1: Environment Configuration
Clone the repository and copy the environment template:
    cp .env.example .env

Populate the `.env` file with secure production-grade secrets:
    POSTGRES_USER=litellm_admin
    POSTGRES_PASSWORD=your_secure_db_password
    POSTGRES_DB=litellm_db
    LITELLM_MASTER_KEY=sk-admin-master-key
    UI_USERNAME=admin
    UI_PASSWORD=your_secure_ui_password

### Step 2: Gateway Policy Definition (`config/litellm_config.yaml`)
    model_list:
      - model_name: local-llama
        litellm_params:
          model: ollama/qwen2.5:latest
          api_base: http://host.docker.internal:11434

    litellm_settings:
      callbacks: ["presidio"]
      presidio:
        analyzer_url: "http://presidio-analyzer:3000"
        anonymizer_url: "http://presidio-anonymizer:3000"
        redact_pii: true

    general_settings:
      database_url: "postgresql://litellm_admin:your_secure_db_password@postgres:5432/litellm_db"
      master_key: "sk-admin-master-key"

### Step 3: Container Orchestration (`docker-compose.yml`)
    services:
      litellm:
        image: ghcr.io/berriai/litellm:main-latest
        container_name: litellm-security-gateway
        restart: unless-stopped
        ports:
          - "4000:4000"
        environment:
          - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
          - LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
          - UI_USERNAME=${UI_USERNAME}
          - UI_PASSWORD=${UI_PASSWORD}
          - PRESIDIO_ANALYZER_URL=http://presidio-analyzer:3000
          - PRESIDIO_ANONYMIZER_URL=http://presidio-anonymizer:3000
        volumes:
          - ./config/litellm_config.yaml:/app/config.yaml:ro
        command: ["--config", "/app/config.yaml", "--port", "4000"]
        depends_on:
          - postgres
          - presidio-analyzer
          - presidio-anonymizer

      presidio-analyzer:
        image: mcr.microsoft.com/presidio-analyzer:latest
        container_name: presidio-analyzer
        restart: unless-stopped
        ports:
          - "5001:3000"

      presidio-anonymizer:
        image: mcr.microsoft.com/presidio-anonymizer:latest
        container_name: presidio-anonymizer
        restart: unless-stopped
        ports:
          - "5002:3000"

      postgres:
        image: postgres:16-alpine
        container_name: litellm-postgres
        restart: unless-stopped
        environment:
          POSTGRES_USER: ${POSTGRES_USER}
          POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
          POSTGRES_DB: ${POSTGRES_DB}
        volumes:
          - pgdata:/var/lib/postgresql/data

    volumes:
      pgdata:

### Step 4: Stack Initialization
Execute Docker Compose in detached mode:
    docker compose up -d

Verify that all four microservices are healthy:
    docker compose ps

---

## 7. Verification, Validation & Telemetry

### Test Case 1: Inline PII Anonymization Verification (OWASP LLM02)
Send an unsanitized payload containing real PII entities to the gateway proxy endpoint:
    curl -X POST "http://localhost:4000/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer sk-admin-master-key" \
      -d '{
        "model": "local-llama",
        "messages": [
          {
            "role": "user",
            "content": "Employee File: Jane Doe, SSN: 123-45-6789, Phone: 555-867-5309. Generate a profile summary."
          }
        ]
      }'

**Observed Gateway Sanitization:**
The Presidio pre-call hook intercepts the prompt, identifies `Jane Doe` as `<PERSON>`, `123-45-6789` as `<US_SSN>`, and `555-867-5309` as `<PHONE_NUMBER>`. The downstream model only processes:
    "Employee File: <PERSON>, SSN: <US_SSN>, Phone: <PHONE_NUMBER>. Generate a profile summary."

### Test Case 2: Edge Rate Limiting & Denial-of-Wallet Defense (OWASP LLM10)
Generate a restricted virtual key with a 2 Request-Per-Minute (RPM) rate ceiling:
    curl -X POST "http://localhost:4000/key/generate" \
      -H "Authorization: Bearer sk-admin-master-key" \
      -H "Content-Type: application/json" \
      -d '{
        "models": ["local-llama"],
        "rpm_limit": 2,
        "max_budget": 10.00
      }'

Execute a rapid request burst using the generated key:
    for i in {1..3}; do
      echo "=== Executing Request $i ==="
      curl -s -w "\nHTTP Response Code: %{http_code}\n" -X POST "http://localhost:4000/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $SCOPED_VIRTUAL_KEY" \
        -d '{"model": "local-llama", "messages": [{"role": "user", "content": "Ping"}]}'
    done

**Observed Telemetry:**
* Requests 1 & 2 succeed (`HTTP 200 OK`).
* Request 3 is blocked at the proxy boundary (`HTTP 429 Too Many Requests`):
    {
      "error": {
        "message": "Rate limit exceeded for api_key. Limit type: requests. Current limit: 2, Remaining: 0.",
        "type": "throttling_error",
        "code": "429"
      }
    }

---

## 8. Management, Governance & Observability

### Centralized Admin Dashboard
Access the administrative interface at `http://<GATEWAY_IP>:4000/ui`:
* **Virtual Key Management:** Issue scoped keys per application/user, apply token/cost ceilings, and revoke access instantly without restarting inference nodes.
* **Audit Trails & Forensics:** Review searchable logs of prompts, entity transformations, and latency graphs across all client applications.
* **Model Failover & High Availability:** Configure fallbacks to secondary models if the primary inference node experiences downtime.

---

## 9. Learning Reflections & Engineering Takeaways

1. **Defense-in-Depth Over Prompt Reliance:** Asking an LLM to "not leak sensitive data" via system prompts is non-deterministic. True data security requires deterministic, mechanical software inspection before data reaches model context.
2. **Decoupled Architecture:** Placing security controls in a gateway layer allows organizations to swap inference engines (local or cloud) without rewriting application authentication, rate-limiting, or PII masking rules.
3. **Traceable Compliance:** Automating access control and PII scrubbing provides audit-ready telemetry mapped directly to enterprise governance standards.
