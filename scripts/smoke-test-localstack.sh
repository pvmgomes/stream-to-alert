#!/usr/bin/env bash
# End-to-end smoke test for the full alert flow against a running LocalStack
# instance: Transactions insert -> stream-processor -> SNS -> fraud-review-queue
# -> fraud-review-consumer -> FraudReviewCases row.
#
# Assumes `terraform apply` has already provisioned the stack in
# terraform/envs/localstack against this LocalStack instance.
#
# Usage: scripts/smoke-test-localstack.sh
set -euo pipefail

ENDPOINT_URL="${ENDPOINT_URL:-http://localhost:4566}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

TRANSACTIONS_TABLE="Transactions"
CASES_TABLE="FraudReviewCases"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-30}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
ABSENCE_WAIT_SECONDS="${ABSENCE_WAIT_SECONDS:-10}"

RUN_ID="$(date +%s)"
NOTABLE_TXN_ID="smoke-test-${RUN_ID}-notable"
QUIET_TXN_ID="smoke-test-${RUN_ID}-quiet"
ACCOUNT_ID="smoke-test-acct-${RUN_ID}"

aws_cli() {
  aws --endpoint-url="$ENDPOINT_URL" "$@"
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

put_transaction() {
  local transaction_id="$1"
  local amount="$2"
  aws_cli dynamodb put-item --table-name "$TRANSACTIONS_TABLE" --item "$(
    cat <<EOF
{
  "accountId": {"S": "${ACCOUNT_ID}"},
  "transactionId": {"S": "${transaction_id}"},
  "amount": {"N": "${amount}"},
  "type": {"S": "WITHDRAWAL"},
  "createdAt": {"S": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
}
EOF
  )" >/dev/null
}

get_case() {
  local transaction_id="$1"
  aws_cli dynamodb get-item --table-name "$CASES_TABLE" \
    --key "{\"transactionId\": {\"S\": \"${transaction_id}\"}}"
}

echo "==> Inserting notable transaction ${NOTABLE_TXN_ID} (amount above threshold)"
put_transaction "$NOTABLE_TXN_ID" "15000"

echo "==> Polling FraudReviewCases for a case row (timeout ${POLL_TIMEOUT_SECONDS}s)"
elapsed=0
case_item=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_SECONDS" ]; do
  case_item="$(get_case "$NOTABLE_TXN_ID" | jq -r '.Item // empty')"
  if [ -n "$case_item" ]; then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done

[ -n "$case_item" ] || fail "no FraudReviewCases row appeared for ${NOTABLE_TXN_ID} within ${POLL_TIMEOUT_SECONDS}s"

case_json="$(echo "$case_item" | jq '{
  transactionId: .transactionId.S,
  accountId: .accountId.S,
  amount: .amount.N,
  reason: .reason.S,
  alertedAt: .alertedAt.S
}')"

echo "==> Asserting case fields"
[ "$(echo "$case_json" | jq -r '.transactionId')" = "$NOTABLE_TXN_ID" ] || fail "transactionId mismatch: $case_json"
[ "$(echo "$case_json" | jq -r '.accountId')" = "$ACCOUNT_ID" ] || fail "accountId mismatch: $case_json"
[ "$(echo "$case_json" | jq -r '.amount')" = "15000" ] || fail "amount mismatch: $case_json"
echo "$case_json" | jq -e '.reason | contains("exceeds threshold")' >/dev/null || fail "reason missing/unexpected: $case_json"
echo "$case_json" | jq -e '.alertedAt | length > 0' >/dev/null || fail "alertedAt missing: $case_json"
echo "    OK: ${case_json}"

echo "==> Inserting non-notable transaction ${QUIET_TXN_ID} (amount below threshold)"
put_transaction "$QUIET_TXN_ID" "500"

echo "==> Waiting ${ABSENCE_WAIT_SECONDS}s to confirm no case row is written for it"
sleep "$ABSENCE_WAIT_SECONDS"
quiet_item="$(get_case "$QUIET_TXN_ID" | jq -r '.Item // empty')"
[ -z "$quiet_item" ] || fail "unexpected FraudReviewCases row for non-notable transaction ${QUIET_TXN_ID}: $quiet_item"
echo "    OK: no case row written"

echo "==> Smoke test passed"
