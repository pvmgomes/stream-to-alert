# Spec 06 — Real AWS validation

## Goal

Actually trigger `deploy-aws.yml` against the real sandbox account, then
validate the full flow end to end against real infrastructure: a notable
transaction produces a `FraudReviewCases` row *and* a message on
`customer-notification-queue` (the unconsumed fan-out leg — this is the
first time anything in this project checks that queue at all, since
Phases 2–5 only ever exercised the `fraud-review-queue` leg). Plus a short
CloudWatch Logs checklist for diagnosing success vs. silent failure in
each Lambda.

This phase is inherently "run it for real" — there's no spec-writing
substitute for actually merging to `main`, watching `deploy-aws.yml` run,
and poking at the live account. I'll ask for your explicit go-ahead
immediately before the merge-to-`main` step and again before writing any
test data into the real account, separate from sign-off on this spec —
both are real, costed actions in your AWS account, not just an
implementation detail.

## Decisions needing sign-off before implementation

1. **New dedicated script `scripts/smoke-test-aws.sh`, not a
   generalized/shared version of Phase 5's `smoke-test-localstack.sh`.**
   The two scripts overlap maybe 80% (insert transaction, poll
   `FraudReviewCases`, assert fields), but diverge in ways that would
   make a single shared script more complex than two simple ones:
   - This one also checks `customer-notification-queue` — receiving the
     message and asserting its content — which the LocalStack version
     doesn't do.
   - This one cleans up the test items it writes afterward (`Transactions`
     rows, the `FraudReviewCases` row, the received
     `customer-notification-queue` message) since it's running against a
     real, persistent, billed account rather than a stack that gets
     `terraform destroy`'d at the end of the CI job regardless.
   - It's run manually, once, right after a real deploy — not wired into
     any workflow.

   A shared script would need a real-vs-LocalStack branch for all three
   of these, turning one simple script into one script serving two
   audiences with conditional logic. Given this project's preference for
   duplication over premature abstraction (see the `sqs-fanout-subscriber`
   vs. dual-mode-module decision back in Phase 3), two short
   single-purpose scripts reads better than one branchy one. Flagging
   since it's a real tradeoff (DRY vs. simplicity), not a forced move —
   happy to generalize instead if you'd rather have one script.

2. **Validate manually, not via a new GitHub Actions workflow.**
   `ACTION_PLAN.md` says "manual or scripted" for this phase; the actual
   trigger (`deploy-aws.yml` on merge to `main`) and the validation (this
   script + CloudWatch checks) are two separate concerns run at two
   different times by a human watching the outcome — not something to
   wire into more CI automation. Matches Phase 5's own scope boundary
   ("Phase 6's actual real-AWS validation run" was explicitly listed as
   out of scope for Phase 5).

3. **Negative-path check included even though `ACTION_PLAN.md` only
   mentions the notable-transaction case.** `scripts/smoke-test-aws.sh`
   also inserts a non-notable transaction and asserts no case row and no
   queue message appear for it — cheap to add, consistent with how every
   prior phase validated both sides of the threshold, and catches a
   misconfigured real-account threshold env var that a notable-only test
   would miss.

## Interface / contract

### `scripts/smoke-test-aws.sh` (new)

Bash, targets real AWS (no `--endpoint-url`; uses whatever credentials are
active in the caller's environment — your local AWS CLI session, same as
how `terraform apply` was run manually against this account back when
`aws sts get-caller-identity` was checked in Phase 5's setup).

Steps:
1. Insert a notable transaction (amount above threshold) into
   `Transactions`.
2. Poll `FraudReviewCases` for the case row (timeout/retry, same pattern
   as the LocalStack script) and assert its 5 fields.
3. Poll `customer-notification-queue` (`receive-message`, timeout/retry)
   for a message whose body is the raw alert JSON for this transaction;
   assert `transactionId`/`accountId`/`amount` match, then
   `delete-message` it off the queue (nothing else ever will, since
   `customer-notification-queue` has no consumer).
4. Insert a non-notable transaction (amount at/below threshold).
5. After a fixed wait (can't poll for absence), assert no
   `FraudReviewCases` row and no `customer-notification-queue` message
   exist for it.
6. On success: delete the two `Transactions` rows and the
   `FraudReviewCases` row this run created, so repeated runs don't
   accumulate synthetic data in the real account. On failure: exit
   without cleanup, so the failing state is still there to inspect.

### CloudWatch Logs checklist

**`stream-processor`** — log group `/aws/lambda/stream-processor`:
- `aws logs tail /aws/lambda/stream-processor --since 10m` (add
  `--follow` to watch live).
- **Success**: a line like `Published alert for transaction <id>
  (messageId=...)` for the notable transaction's ID.
- **No log lines at all for the invocation window**: the DynamoDB Stream
  event source mapping likely isn't triggering — check
  `aws lambda list-event-source-mappings --function-name
  stream-processor` shows `State: Enabled`, and that the mapping's
  `EventSourceArn` matches the `Transactions` table's current stream ARN.
- **Log line `Skipping record ...: missing/invalid required fields`**:
  the inserted item doesn't match the expected shape (`accountId`,
  `transactionId`, numeric `amount`) — check the `put-item` payload, not
  the Lambda.
- **Log line `... not notable (amount=... threshold=...)`** for a
  transaction you expected to alert: the threshold env var or the test
  amount don't relate the way you think — check
  `aws lambda get-function-configuration --function-name
  stream-processor --query Environment`.

**`fraud-review-consumer`** — log group
`/aws/lambda/fraud-review-consumer`:
- `aws logs tail /aws/lambda/fraud-review-consumer --since 10m`.
- **Success**: `Wrote fraud review case for transaction <id>`.
- **No log lines at all**: check
  `aws lambda list-event-source-mappings --function-name
  fraud-review-consumer` is `Enabled`; also check
  `fraud-review-queue`'s `ApproximateNumberOfMessages` — if it's
  nonzero and growing, messages are arriving but not being pulled
  (IAM permissions on the mapping, or the mapping itself misconfigured).
- **Log line `Skipping message ...: invalid alert payload`**: the
  message body didn't parse as the expected alert shape — check
  `stream-processor`'s publish payload matches what `AlertParser`
  expects (this would mean the two Lambdas' contracts drifted).
- **Log line `Failed to write case for transaction ...`**: a DynamoDB
  `PutItem` failure — check the Lambda's IAM role actually has
  `dynamodb:PutItem` on `FraudReviewCases`' current ARN (a table
  recreated by `terraform destroy`/`apply` gets a new ARN; a stale IAM
  policy referencing an old one would silently fail here).
- **No error, but also no case row**: check `fraud-review-queue`'s DLQ —
  if the message failed 5 times (`maxReceiveCount`), it's been moved
  there and won't retry further;
  `aws sqs receive-message --queue-url <dlq-url>` to inspect it.

## Out of scope for this phase

- Automating this validation into a workflow — stays a manual, one-time
  check per merge-to-`main`, matching decision 2.
- Phase 7's teardown — this phase deliberately leaves the real stack up
  so it can be inspected; destroying it is the next, separate step.
- Fixing any bugs this validation might surface beyond what's needed to
  make the documented golden path work — if something real-AWS-specific
  breaks (e.g. an IAM permission gap that LocalStack's permissive dummy
  auth never would have caught), that's handled as its own fix, not
  silently folded into this spec's scope.

## Definition of done

- [ ] `scripts/smoke-test-aws.sh` implemented per the contract above.
- [ ] `develop` merged into `main` (with your explicit go-ahead
      immediately before), `deploy-aws.yml` runs and succeeds.
- [ ] `scripts/smoke-test-aws.sh` run against the real account (with your
      explicit go-ahead immediately before) and passes.
- [ ] CloudWatch Logs for both Lambdas inspected and match the "success"
      pattern in the checklist above for the smoke test's notable
      transaction.
- [ ] Work done on `feature/06-real-aws-validation`, PR'd into `develop`
      (the script and checklist are the artifacts; the validation run
      itself isn't a code change to merge, but the PR captures the
      checklist/script for reuse next time).
