# Spec 04 — Fraud review consumer Lambda + table

## Goal

An SQS-triggered Lambda consuming `fraud-review-queue`, writing a case
record into a new `FraudReviewCases` DynamoDB table for each alert. This
completes the fully-wired leg of the architecture end to end:
`Transactions` insert → stream-processor → SNS → `fraud-review-queue` →
this Lambda → `FraudReviewCases` row.

## Decisions needing sign-off before implementation

1. **`FraudReviewCases` primary key is `transactionId` alone (no sort
   key).** `ACTION_PLAN.md` left this open ("PK `transactionId` or a
   generated `caseId`"). A case is 1:1 with a transaction and nothing in
   this project ever needs more than one case per transaction, so a
   generated `caseId` would add an indirection with no payoff. Using
   `transactionId` as the key also has a useful side effect: SQS is
   at-least-once delivery, so `fraud-review-queue` can redeliver the same
   message; a `PutItem` keyed on `transactionId` just overwrites the same
   item on a redelivery instead of creating a duplicate case. No
   conditional-write/dedup logic is needed — the key schema handles it for
   free.

2. **Case record keeps exactly the 5 fields `ACTION_PLAN.md` lists**:
   `transactionId`, `accountId`, `amount`, `reason`, `alertedAt`. The alert
   JSON on the queue (from Phase 2) also carries `threshold` and `type`,
   but the plan's contract for this phase only names those 5, and nothing
   downstream reads `threshold`/`type` from a case record. Consistent with
   the project's "thin business logic" scope — not carrying extra fields
   just because they're available upstream. The consumer's JSON parsing
   tolerates the extra fields being present (ignores unknown properties)
   rather than rejecting the message over them.

3. **Partial batch failure via `ReportBatchItemFailures`**, per
   `ACTION_PLAN.md`. The event source mapping sets
   `function_response_types = ["ReportBatchItemFailures"]`; the handler
   returns the message IDs that failed to parse or failed to write, so
   only those specific messages are redelivered — a bad message in a batch
   of 10 doesn't force the other 9 to be reprocessed. A message that will
   never succeed (e.g. malformed JSON) keeps being reported as failed on
   each redelivery until it hits `fraud-review-queue`'s DLQ after 5
   receives (the `maxReceiveCount` set in Phase 3) — same
   quarantine-via-DLQ pattern as any other poison message, no special-case
   handling needed in the Lambda.

4. **IAM stays least-privilege, mirroring `stream-processor-lambda`'s
   pattern**: `sqs:ReceiveMessage`/`DeleteMessage`/`GetQueueAttributes`
   scoped to `fraud-review-queue` only, `dynamodb:PutItem` scoped to
   `FraudReviewCases` only, CloudWatch Logs write scoped to this
   function's log group.

## Interface / contract

### `FraudReviewCases` table

Via the existing `dynamodb-table` module: `hash_key = "transactionId"`,
no range key, no stream (nothing consumes changes to this table).

### `services/fraud-review-consumer` (new Maven module, Java 21)

Same Maven setup as `stream-processor`: `maven.compiler.release = 21`,
`maven-shade-plugin` for the uber jar, JUnit 5 + AssertJ + Mockito for
tests, AWS SDK v2 (`software.amazon.awssdk:dynamodb` instead of `sns`).

- Handler: `RequestHandler<SQSEvent, SQSBatchResponse>`, one handler
  class.
- For each SQS message: parse the body (raw JSON — `raw_message_delivery
  = true` from Phase 3 means no SNS envelope to unwrap) into an incoming
  alert DTO, tolerant of unknown properties.
- Required fields: `transactionId`, `accountId`, `amount`, `reason`,
  `alertedAt`. Missing/unparseable → that message's ID is added to the
  batch item failures list; do not throw, so the rest of the batch is
  unaffected.
- On successful parse: `PutItem` into `FraudReviewCases` with exactly
  those 5 fields. A `PutItem` failure (e.g. throttling) also reports that
  message ID as a batch failure rather than throwing out of the handler.
- Env var: `TABLE_NAME`.

Item shape written to `FraudReviewCases`:
```json
{
  "transactionId": "...",
  "accountId": "...",
  "amount": 12345.67,
  "reason": "amount 12345.67 exceeds threshold 10000",
  "alertedAt": "2026-07-24T21:00:00Z"
}
```

Unit tests (JUnit 5 + Mockito, no LocalStack needed):
- Parsing: well-formed alert JSON → correct DTO fields; JSON missing a
  required field → parse/validation failure surfaced as "invalid", not an
  exception.
- Handler: valid message → `PutItem` invoked with the correct item, empty
  batch-failure list returned; malformed JSON → message ID reported as a
  batch failure, `PutItem` never invoked; simulated `PutItem` exception
  (mocked DynamoDB client) → message ID reported as a batch failure.

### `terraform/modules/consumer-lambda` (implements the existing placeholder)

Variables: `function_name`, `queue_arn` (the SQS queue to trigger from),
`table_arn`, `table_name`, `jar_path`, `batch_size` (default `10`).

Resources:
- `aws_iam_role` (trust policy: `lambda.amazonaws.com`) +
  `aws_iam_role_policy` scoped to exactly: `sqs:ReceiveMessage`,
  `sqs:DeleteMessage`, `sqs:GetQueueAttributes` on `queue_arn`;
  `dynamodb:PutItem` on `table_arn`; CloudWatch Logs write scoped to this
  function's log group.
- `aws_lambda_function`: `runtime = "java21"`, handler pointing at the
  shaded jar's handler class, env var `TABLE_NAME`.
- `aws_lambda_event_source_mapping`: `event_source_arn = queue_arn`,
  `batch_size = var.batch_size`, `function_response_types =
  ["ReportBatchItemFailures"]`.

Outputs: `function_name`, `function_arn`.

### Env wiring

Both `terraform/envs/localstack/main.tf` and `terraform/envs/aws/main.tf`
add:
```hcl
module "fraud_review_cases_table" {
  source = "../../modules/dynamodb-table"

  table_name = "FraudReviewCases"
  hash_key   = "transactionId"
}

module "fraud_review_consumer" {
  source = "../../modules/consumer-lambda"

  function_name = "fraud-review-consumer"
  queue_arn     = module.fraud_review_queue.queue_arn
  table_arn     = module.fraud_review_cases_table.table_arn
  table_name    = module.fraud_review_cases_table.table_name
  jar_path      = "${path.module}/../../../services/fraud-review-consumer/target/fraud-review-consumer.jar"
}
```

### Verification on LocalStack

1. `mvn -f services/fraud-review-consumer/pom.xml package` to build the
   jar (`stream-processor`'s jar must also already be built, per Phase 2).
2. `terraform apply` in `envs/localstack`.
3. Insert a notable transaction (`amount` > 10000) via
   `aws --endpoint-url=http://localhost:4566 dynamodb put-item` into
   `Transactions`.
4. Poll `FraudReviewCases`:
   `aws --endpoint-url=http://localhost:4566 dynamodb get-item
   --table-name FraudReviewCases --key '{"transactionId": {"S":
   "<id>"}}'` — confirm the row appears with the 5 expected fields.
5. Insert a non-notable transaction (`amount` ≤ 10000); confirm no case
   row is written for it (stream-processor never publishes, so nothing
   ever reaches the queue or this Lambda — same check as Phase 2/3, now
   carried one hop further).

This is documented as a manual CLI procedure, same as Phases 2 and 3.
Automating it into a repeatable smoke test is explicitly Phase 5's job
("run the end-to-end smoke test from Phase 4 automatically" against
`deploy-localstack.yml`) — not duplicated here.

## Out of scope for this phase

- Any consumer/logic on `customer-notification-queue` — permanently out of
  scope per `README.md`.
- Deduplication/conditional-write logic beyond the natural idempotency of
  keying `FraudReviewCases` on `transactionId`.
- Further DLQ/redrive tuning on `fraud-review-queue` beyond what Phase 3
  already configured.
- Scripting/automating the LocalStack smoke test — Phase 5.
- Actual deployment to real AWS — Phase 6.

## Definition of done

- [ ] `services/fraud-review-consumer` Maven module implemented; unit
      tests (parsing, batch-failure reporting, `PutItem` invocation) pass
      via `mvn -f services/fraud-review-consumer/pom.xml verify` and via
      CI (`ci.yml` auto-discovers the new module — no CI edits needed).
- [ ] `terraform/modules/consumer-lambda` implements the function, IAM
      role/policy, and SQS event source mapping (with
      `ReportBatchItemFailures`) per the contract above.
- [ ] `FraudReviewCases` table provisioned via the existing
      `dynamodb-table` module.
- [ ] Both envs wire the new modules together using Phase 3's
      `fraud_review_queue` module output.
- [ ] `terraform fmt`/`validate` clean in both envs.
- [ ] LocalStack validation per "Verification" above passes: a notable
      transaction produces a `FraudReviewCases` row with the correct
      fields; a non-notable transaction produces none.
- [ ] `terraform destroy` against LocalStack cleans up without error.
- [ ] Work done on `feature/04-fraud-review-consumer`, PR'd into
      `develop`.
