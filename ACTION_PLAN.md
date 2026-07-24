# Action Plan

Execution guide for Claude Code. See `README.md` for the scenario and
architecture this plan builds toward.

## Working agreement

- **Git Flow.** Each phase below is done on a `feature/<phase-slug>` branch,
  PR'd into `develop`. `develop` → `release/*` → `main` when a batch of
  phases is ready to actually hit the real AWS account.
- **Spec-Driven Development.** Before writing code for a phase:
  1. Write `specs/NN-phase-name.md` (goal, interface/contract, out-of-scope
     notes, definition of done).
  2. Pause and get explicit approval on the spec before implementing.
  3. Implement the feature and its tests together in the same pass — not
     tests-after, not strict TDD red/green ceremony.
- **Definition of done, every phase:** spec approved → implemented → tests
  passing → validated against LocalStack → PR merged to `develop`.
- Don't jump ahead: each phase assumes the previous ones are merged.

---

## Phase 0 — Repo & environment scaffolding
- Initialize repo with Git Flow branches (`main`, `develop`).
- `.github/workflows/ci.yml`: build + unit test on every PR.
- `docker-compose.yml` bringing up LocalStack with `dynamodb`, `sns`, `sqs`,
  `lambda` services enabled.
- Terraform root structure per the layout in `README.md`; local state is
  fine for this project (no remote backend needed).
- Spec: `specs/00-scaffolding.md`

## Phase 1 — Transactions table
- Terraform module: `Transactions` DynamoDB table, PK `accountId`, SK
  `transactionId`, Stream enabled with `NEW_IMAGE`.
- Deploy to LocalStack; verify via `awslocal dynamodb` CLI.
- Spec: `specs/01-transactions-table.md`

## Phase 2 — Stream processor Lambda
- New Maven module `services/stream-processor` (Java 25).
- Event source mapping: DynamoDB Stream → this Lambda.
- Logic: parse stream record, compare `amount` to threshold (env var,
  default `10000`), publish enriched JSON to `transaction-alerts` SNS topic
  when notable.
- Unit tests: record parsing, threshold logic (above/below/equal boundary).
- Deploy to LocalStack; validate by inserting test items into `Transactions`
  and confirming the Lambda fires and publishes.
- Spec: `specs/02-stream-processor.md`

## Phase 3 — SNS topic + SQS fan-out
- Terraform: `transaction-alerts` SNS topic; `fraud-review-queue` and
  `customer-notification-queue` SQS queues, both subscribed with
  `raw_message_delivery = true`.
- DLQ + redrive policy on `fraud-review-queue` (the one with a real
  consumer). `customer-notification-queue` can skip a DLQ for now — it has
  no consumer to fail.
- Validate fan-out against LocalStack: publish a notable transaction,
  confirm both queues receive a copy.
- Spec: `specs/03-sns-sqs-fanout.md`

## Phase 4 — Fraud review consumer Lambda + table
- Terraform: `FraudReviewCases` DynamoDB table (PK `transactionId` or a
  generated `caseId` — decide in the spec).
- New Maven module `services/fraud-review-consumer` (Java 25).
- SQS-triggered Lambda (`ReportBatchItemFailures` for partial batch
  handling, matching the pattern from the earlier SNS→SQS→Lambda→SNS
  sketch).
- Writes a case record: `transactionId`, `accountId`, `amount`, `reason`,
  `alertedAt`.
- Unit tests + LocalStack integration test: end-to-end from a
  `Transactions` insert through to a `FraudReviewCases` row appearing.
- Spec: `specs/04-fraud-review-consumer.md`

## Phase 5 — CI/CD pipeline
- `deploy-localstack.yml`: on merge to `develop`, spin up LocalStack in the
  runner, `terraform apply` the full stack, run the end-to-end smoke test
  from Phase 4 automatically.
- `deploy-aws.yml`: on merge to `main` (i.e., after a `release/*` merge),
  `terraform apply` against the real AWS sandbox account. Gate this behind
  a GitHub Environment with manual approval — don't let it auto-fire.
- Auth: prefer GitHub OIDC → AWS IAM role over long-lived static credentials
  in secrets.
- Spec: `specs/05-cicd-pipeline.md`

## Phase 6 — Real AWS validation
- Manual or scripted smoke test against the real deployment: insert a
  notable transaction via AWS CLI/SDK, confirm the `FraudReviewCases` row
  appears and a message lands in `customer-notification-queue`.
- Short CloudWatch Logs checklist (what to look for in each Lambda's logs
  to confirm success vs. silent failure).
- Spec: `specs/06-real-aws-validation.md`

## Phase 7 — Teardown & cost hygiene
- Documented `terraform destroy` procedure against the real AWS account —
  run this after each practice session; there's no reason to leave billed
  resources up between sessions.
- LocalStack resources need no equivalent cleanup (ephemeral, local-only,
  no cost).
- Spec: not required — this is a runbook note, not a feature.

---

## Explicitly out of scope for this plan

See `README.md` → "Explicitly out of scope." If a phase seems to be
drifting into any of those areas, stop and flag it rather than expanding
scope silently.
