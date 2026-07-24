# Bank Transaction Alerts — DynamoDB Streams → Lambda → SNS → SQS

A practice project for hands-on reps with an event-driven AWS integration
pattern: **DynamoDB Streams → Lambda → SNS → SQS (fan-out) → Lambda → DynamoDB**.

This is a learning project, not a product. The business logic is deliberately
thin — the point is the integration plumbing, not fraud detection.

## Scenario

A bank records transactions (deposits, withdrawals, transfers) in a
`Transactions` DynamoDB table. Any transaction over a configurable threshold
(default **$10,000**) is treated as "notable" and triggers an alert flow:

1. A **stream processor Lambda** is attached directly to the table's
   DynamoDB Stream (native event source mapping — no intermediary needed for
   this leg). For each new transaction, it checks `amount > threshold`.
2. Notable transactions are published, enriched, to an SNS topic:
   **`transaction-alerts`**.
3. SNS fans out to two SQS queues — this is the reason SNS sits here at all:
   DynamoDB Streams alone caps out at 2 direct Lambda consumers, so SNS
   removes that ceiling and lets independent consumers be added later
   without touching the producer.
   - **`fraud-review-queue`** — consumed by a second Lambda that writes a
     case record into a new `FraudReviewCases` table. This is the fully
     wired, end-to-end leg.
   - **`customer-notification-queue`** — left unconsumed (or log-only).
     Represents "another team's concern" that exists purely to demonstrate
     fan-out; no real notification logic is built.

## Architecture

```
Transactions (DynamoDB, Streams: NEW_IMAGE)
        │ (event source mapping)
        ▼
stream-processor (Lambda, Java 21)
   filters: amount > threshold
        │ sns:Publish
        ▼
transaction-alerts (SNS topic)
        │ fan-out
   ┌────┴─────────────────────┐
   ▼                          ▼
fraud-review-queue        customer-notification-queue
   │ (event source mapping)      (unconsumed / stub)
   ▼
fraud-review-consumer (Lambda, Java 21)
        │
        ▼
FraudReviewCases (DynamoDB)
```

## Tech stack & methodology

| Concern | Choice |
|---|---|
| Lambda language/runtime | Java 21 (Maven) |
| IaC | Terraform |
| Local iteration | LocalStack (via Docker) |
| Real deploy target | Your AWS sandbox account |
| Branching | Git Flow (`main`, `develop`, `feature/*`, `release/*`, `hotfix/*`) |
| CI/CD | GitHub Actions — build/test on PR, deploy to LocalStack on merge to `develop`, deploy to real AWS on merge to `main` |
| Development methodology | Spec-Driven Development (SDD) — see below |

### Spec-Driven Development

Every phase in `ACTION_PLAN.md` starts with a short spec document
(`specs/NN-phase-name.md`) written before any code: what's being built, the
interface/contract, and what "done" looks like. Claude Code drafts the spec,
pauses for your approval, and only then implements the feature and its tests
together in the same pass. The spec is the source of truth if code and
intent ever disagree — this keeps an AI agent's output anchored to an
explicit, reviewable contract instead of an implicit one held only in chat
history.

## Explicitly out of scope

- Real fraud-detection logic (the threshold rule is intentionally naive)
- Real customer notifications (email/SMS) on `customer-notification-queue`
- AuthN/authZ beyond least-privilege IAM roles per Lambda
- Multi-region, HA, or any production-grade resilience work
- Cost optimization beyond basic hygiene (on-demand billing, teardown after
  each real-AWS session — see "Cleanup" in `ACTION_PLAN.md`)
- A frontend or API of any kind — this is backend plumbing only

## Prerequisites

- AWS account with programmatic access (sandbox/dev, not shared/production)
- Terraform >= 1.7
- Docker (for LocalStack)
- Java 21 + Maven
- A GitHub repository with Actions enabled

## Repository layout (target)

```
.
├── README.md
├── ACTION_PLAN.md
├── specs/                        # SDD specs, one per phase
├── terraform/
│   ├── modules/
│   │   ├── dynamodb-table/
│   │   ├── stream-processor-lambda/
│   │   ├── sns-sqs-fanout/
│   │   └── consumer-lambda/
│   └── envs/
│       ├── localstack/
│       └── aws/
├── services/
│   ├── stream-processor/         # Java 21 Maven module
│   └── fraud-review-consumer/    # Java 21 Maven module
├── docker-compose.yml            # LocalStack
└── .github/workflows/
    ├── ci.yml
    ├── deploy-localstack.yml
    └── deploy-aws.yml
```

## How to use this repo

See `ACTION_PLAN.md` — it's written to be handed to Claude Code as an
execution guide, phase by phase, with a spec-and-approval gate before each
implementation step.
