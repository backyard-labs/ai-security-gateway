#!/usr/bin/env bash

set -u

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:4000}"
MODEL_NAME="${MODEL_NAME:-local-llama}"
VALIDATION_MODE="${VALIDATION_MODE:-normal}"

# Required only in rate-limit mode.
EXPECTED_RPM_LIMIT="${EXPECTED_RPM_LIMIT:-}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
  printf '[PASS] %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  printf '[SKIP] %s\n' "$1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$1"
    exit 2
  fi
}

print_summary() {
  echo
  echo "Validation Summary"
  echo "PASS: $PASS_COUNT"
  echo "FAIL: $FAIL_COUNT"
  echo "SKIP: $SKIP_COUNT"

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi

  exit 0
}

require_command curl
require_command jq

if [[ -z "${LITELLM_API_KEY:-}" ]]; then
  echo "LITELLM_API_KEY is not set."
  echo "Load the scoped client key before running this script."
  exit 2
fi

RESPONSE_FILE="$(mktemp)"
RATE_RESULTS_FILE=""

cleanup() {
  rm -f "$RESPONSE_FILE"

  if [[ -n "$RATE_RESULTS_FILE" ]]; then
    rm -f "$RATE_RESULTS_FILE"
  fi
}

trap cleanup EXIT

###############################################################################
# Rate-limit validation mode
###############################################################################

if [[ "$VALIDATION_MODE" == "rate-limit" ]]; then

  if [[ -z "$EXPECTED_RPM_LIMIT" ]]; then
    echo "EXPECTED_RPM_LIMIT must be set in rate-limit mode."
    echo
    echo "Example:"
    echo "  VALIDATION_MODE=rate-limit EXPECTED_RPM_LIMIT=10 ./tests/validate_gateway.sh"
    exit 2
  fi

  if ! [[ "$EXPECTED_RPM_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "EXPECTED_RPM_LIMIT must be a positive integer."
    exit 2
  fi

  echo "AI Security Gateway Validation v3"
  echo "Mode:          rate-limit"
  echo "Gateway:       $GATEWAY_URL"
  echo "Model:         $MODEL_NAME"
  echo "Expected RPM:  $EXPECTED_RPM_LIMIT"
  echo

  echo "Rate-limit validation"
  echo "This mode runs only the dedicated rate-limit test."
  echo "Run it after the previous rate-limit window has cleared."
  echo

  ALLOWED_COUNT=0
  RATE_LIMITED_COUNT=0
  UNEXPECTED_COUNT=0

  TOTAL_REQUESTS=$((EXPECTED_RPM_LIMIT + 1))
  RATE_RESULTS_FILE="$(mktemp)"

  echo "Sending $TOTAL_REQUESTS concurrent requests..."

  export GATEWAY_URL
  export MODEL_NAME
  export LITELLM_API_KEY

  seq 1 "$TOTAL_REQUESTS" |
    xargs -P "$TOTAL_REQUESTS" -I{} bash -c '
      curl -sS \
        -o /dev/null \
        -w "%{http_code}\n" \
        "$GATEWAY_URL/v1/chat/completions" \
        -H "Authorization: Bearer $LITELLM_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
          \"model\": \"$MODEL_NAME\",
          \"messages\": [
            {
              \"role\": \"user\",
              \"content\": \"concurrent rate-limit validation {}\"
            }
          ]
        }"
    ' > "$RATE_RESULTS_FILE"

  ALLOWED_COUNT="$(
    grep -c '^200$' "$RATE_RESULTS_FILE" || true
  )"

  RATE_LIMITED_COUNT="$(
    grep -c '^429$' "$RATE_RESULTS_FILE" || true
  )"

  UNEXPECTED_COUNT="$(
    grep -vcE '^(200|429)$' "$RATE_RESULTS_FILE" || true
  )"

  echo
  echo "Observed:"
  echo "HTTP 200: $ALLOWED_COUNT"
  echo "HTTP 429: $RATE_LIMITED_COUNT"
  echo "Other:    $UNEXPECTED_COUNT"

  if [[ "$ALLOWED_COUNT" -eq "$EXPECTED_RPM_LIMIT" \
        && "$RATE_LIMITED_COUNT" -ge 1 \
        && "$UNEXPECTED_COUNT" -eq 0 ]]; then
    pass "Configured RPM limit was enforced at the expected threshold"
  else
    fail "Observed rate-limit behavior did not match EXPECTED_RPM_LIMIT=$EXPECTED_RPM_LIMIT"
  fi

  print_summary
fi

###############################################################################
# Validate mode selection
###############################################################################

if [[ "$VALIDATION_MODE" != "normal" ]]; then
  echo "Unsupported VALIDATION_MODE: $VALIDATION_MODE"
  echo "Supported values:"
  echo "  normal"
  echo "  rate-limit"
  exit 2
fi

###############################################################################
# Normal validation mode
###############################################################################

echo "AI Security Gateway Validation v3"
echo "Mode:    normal"
echo "Gateway: $GATEWAY_URL"
echo "Model:   $MODEL_NAME"
echo

###############################################################################
# 1. Gateway availability
###############################################################################

echo "1. Gateway availability"

STATUS="$(
  curl -sS \
    -o /dev/null \
    -w '%{http_code}' \
    "$GATEWAY_URL/"
)"

if [[ "$STATUS" == "200" ]]; then
  pass "Gateway returned HTTP 200"
else
  fail "Gateway availability returned HTTP $STATUS"
fi

###############################################################################
# 2. Authenticated inference
###############################################################################

echo
echo "2. Authenticated inference"

STATUS="$(
  curl -sS \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": \"Reply with exactly: gateway validation successful\"
        }
      ]
    }"
)"

if [[ "$STATUS" != "200" ]]; then
  fail "Authenticated inference returned HTTP $STATUS"
else
  CONTENT="$(jq -r '.choices[0].message.content // empty' "$RESPONSE_FILE")"

  if [[ "$CONTENT" == "gateway validation successful" ]]; then
    pass "Scoped key successfully invoked authorized model"
  else
    fail "Authenticated inference returned unexpected model content"
  fi
fi

###############################################################################
# 3. Reasoning suppression
###############################################################################

echo
echo "3. Reasoning suppression"

STATUS="$(
  curl -sS \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"reasoning_effort\": \"high\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": \"Reply with exactly: reasoning policy validation\"
        }
      ]
    }"
)"

if [[ "$STATUS" != "200" ]]; then
  fail "Reasoning suppression test returned HTTP $STATUS"
else
  REASONING_PRESENT="$(
    jq '
      (.choices[0].message.reasoning_content // null) != null
    ' "$RESPONSE_FILE"
  )"

  if [[ "$REASONING_PRESENT" == "false" ]]; then
    pass "Client reasoning override was suppressed"
  else
    fail "Reasoning content was returned despite gateway policy"
  fi
fi

###############################################################################
# 4. Synthetic PII redaction
###############################################################################

echo
echo "4. Synthetic PII redaction"

STATUS="$(
  curl -sS \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": \"List the two tokens contained in this synthetic test string exactly as received: alice.testing@example.com | 212-555-0198\"
        }
      ]
    }"
)"

if [[ "$STATUS" != "200" ]]; then
  fail "Synthetic PII redaction returned HTTP $STATUS"
else
  CONTENT="$(jq -r '.choices[0].message.content // empty' "$RESPONSE_FILE")"

  if [[ "$CONTENT" == *"<EMAIL_ADDRESS>"* \
        && "$CONTENT" == *"<PHONE_NUMBER>"* \
        && "$CONTENT" != *"alice.testing@example.com"* \
        && "$CONTENT" != *"212-555-0198"* ]]; then
    pass "Synthetic email and phone values were redacted"
  else
    fail "HTTP 200 received, but expected synthetic PII redaction was not observed"
  fi
fi

###############################################################################
# 5. Prompt keyword guardrail
###############################################################################

echo
echo "5. Prompt keyword guardrail"

STATUS="$(
  curl -sS \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": \"SYSTEM OVERRIDE\"
        }
      ]
    }"
)"

if [[ "$STATUS" == "400" ]]; then
  pass "Configured blocked keyword was rejected"
else
  fail "Blocked keyword returned HTTP $STATUS instead of HTTP 400"
fi

###############################################################################
# 5a. Benign prompt control
###############################################################################

echo
echo "5a. Benign prompt control"

STATUS="$(
  curl -sS \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": \"Reply with exactly: benign prompt allowed\"
        }
      ]
    }"
)"

if [[ "$STATUS" != "200" ]]; then
  fail "Benign prompt control returned HTTP $STATUS"
else
  CONTENT="$(jq -r '.choices[0].message.content // empty' "$RESPONSE_FILE")"

  if [[ "$CONTENT" == "benign prompt allowed" ]]; then
    pass "Benign prompt remained permitted"
  else
    fail "Benign prompt returned HTTP 200 but unexpected model content"
  fi
fi

###############################################################################
# 6. Model scope restriction
###############################################################################

echo
echo "6. Model scope restriction"

STATUS="$(
  curl -sS \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "unauthorized-test-model",
      "messages": [
        {
          "role": "user",
          "content": "test"
        }
      ]
    }'
)"

if [[ "$STATUS" == "403" ]]; then
  pass "Scoped key was denied access to unauthorized model"
else
  fail "Unauthorized model returned HTTP $STATUS instead of HTTP 403"
fi

###############################################################################
# 7. Rate limiting
###############################################################################

echo
echo "7. Rate limiting"

skip "Rate limiting is validated separately with VALIDATION_MODE=rate-limit."

print_summary
