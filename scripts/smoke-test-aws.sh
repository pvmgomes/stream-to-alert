#!/usr/bin/env bash
# End-to-end smoke test for the full alert flow against the real AWS sandbox
# account: Transactions insert -> stream-processor -> SNS -> both
# fraud-review-queue (-> fraud-review-consumer -> FraudReviewCases) and
# customer-notification-queue (unconsumed leg).
#
# Assumes deploy-aws.yml has already applied the stack in
# terraform/envs/aws against this account. Uses whatever AWS credentials
# are active in the caller's environment (e.g. your local AWS CLI
# session) — unlike scripts/smoke-test-localstack.sh, this writes real
# data into a real, billed account, so on success it cleans up after
# itself; on failure it leaves everything in place for inspection.
#
# Usage: scripts/smoke-test-aws.sh
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-sa-east-1}"

TRANSACTIONS_TABLE="Transactions"
CASES_TABLE="FraudReviewCases"
NOTIFICATION_QUEUE_NAME="customer-notification-queue"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-60}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-3}"
ABSENCE_WAIT_SECONDS="${ABSENCE_WAIT_SECONDS:-15}"

RUN_ID="$(date +%s)"
NOTABLE_TXN_ID="smoke-test-${RUN_ID}-notable"
QUIET_TXN_ID="smoke-test-${RUN_ID}-quiet"
ACCOUNT_ID="smoke-test-acct-${RUN_ID}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

put_transaction() {
  local transaction_id="$1"
  local amount="$2"
  aws dynamodb put-item --table-name "$TRANSACTIONS_TABLE" --item "$(
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
  aws dynamodb get-item --table-name "$CASES_TABLE" \
    --key "{\"transactionId\": {\"S\": \"${transaction_id}\"}}"
}

echo "==> Resolving customer-notification-queue URL"
NOTIFICATION_QUEUE_URL="$(aws sqs get-queue-url --queue-name "$NOTIFICATION_QUEUE_NAME" --query QueueUrl --output text)"

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

echo "==> Polling customer-notification-queue for the fan-out message (timeout ${POLL_TIMEOUT_SECONDS}s)"
elapsed=0
notify_message=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_SECONDS" ]; do
  notify_message="$(aws sqs receive-message --queue-url "$NOTIFICATION_QUEUE_URL" \
    --wait-time-seconds 2 --max-number-of-messages 10 |
    jq -r --arg txn "$NOTABLE_TXN_ID" \
      '.Messages // [] | map(select((.Body | fromjson | .transactionId) == $txn)) | first // empty')"
  if [ -n "$notify_message" ]; then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done
[ -n "$notify_message" ] || fail "no customer-notification-queue message appeared for ${NOTABLE_TXN_ID} within ${POLL_TIMEOUT_SECONDS}s"

notify_body="$(echo "$notify_message" | jq -r '.Body | fromjson')"
echo "==> Asserting fan-out message fields"
[ "$(echo "$notify_body" | jq -r '.accountId')" = "$ACCOUNT_ID" ] || fail "accountId mismatch: $notify_body"
[ "$(echo "$notify_body" | jq -r '.amount')" = "15000" ] || fail "amount mismatch: $notify_body"
echo "    OK: ${notify_body}"

echo "==> Deleting fan-out message from customer-notification-queue (nothing else will)"
aws sqs delete-message --queue-url "$NOTIFICATION_QUEUE_URL" \
  --receipt-handle "$(echo "$notify_message" | jq -r '.ReceiptHandle')"

echo "==> Inserting non-notable transaction ${QUIET_TXN_ID} (amount below threshold)"
put_transaction "$QUIET_TXN_ID" "500"

echo "==> Waiting ${ABSENCE_WAIT_SECONDS}s to confirm no case row or fan-out message appear for it"
sleep "$ABSENCE_WAIT_SECONDS"

quiet_case="$(get_case "$QUIET_TXN_ID" | jq -r '.Item // empty')"
[ -z "$quiet_case" ] || fail "unexpected FraudReviewCases row for non-notable transaction ${QUIET_TXN_ID}: $quiet_case"

quiet_notify="$(aws sqs receive-message --queue-url "$NOTIFICATION_QUEUE_URL" \
  --wait-time-seconds 2 --max-number-of-messages 10 |
  jq -r --arg txn "$QUIET_TXN_ID" \
    '.Messages // [] | map(select((.Body | fromjson | .transactionId) == $txn)) | first // empty')"
[ -z "$quiet_notify" ] || fail "unexpected customer-notification-queue message for non-notable transaction ${QUIET_TXN_ID}: $quiet_notify"
echo "    OK: no case row or fan-out message written for the non-notable transaction"

echo "==> Cleaning up synthetic test data"
aws dynamodb delete-item --table-name "$TRANSACTIONS_TABLE" \
  --key "{\"accountId\": {\"S\": \"${ACCOUNT_ID}\"}, \"transactionId\": {\"S\": \"${NOTABLE_TXN_ID}\"}}" >/dev/null
aws dynamodb delete-item --table-name "$TRANSACTIONS_TABLE" \
  --key "{\"accountId\": {\"S\": \"${ACCOUNT_ID}\"}, \"transactionId\": {\"S\": \"${QUIET_TXN_ID}\"}}" >/dev/null
aws dynamodb delete-item --table-name "$CASES_TABLE" \
  --key "{\"transactionId\": {\"S\": \"${NOTABLE_TXN_ID}\"}}" >/dev/null

echo "==> Smoke test passed"
