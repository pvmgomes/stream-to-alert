# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A learning project for the AWS integration pattern **DynamoDB Streams → Lambda → SNS → SQS (fan-out) → Lambda → DynamoDB**. It simulates bank transaction alerting: transactions over a threshold (default $10,000) flow from a `Transactions` table through a stream-processor Lambda, into an SNS topic that fans out to two SQS queues, one of which is consumed by a fraud-review Lambda that writes into a `FraudReviewCases` table.

This is plumbing practice, not a product — business/fraud logic is deliberately thin. See `README.md` for the full scenario, architecture diagram, and the "Explicitly out of scope" list (no real fraud detection, no real notifications, no frontend/API, no HA/multi-region work).

**Current state:** only `README.md` and `ACTION_PLAN.md` exist. No Terraform, Lambda code, or CI has been written yet — everything under "Repository layout" below is the *target* layout, not what's present now.

## Working agreement (from ACTION_PLAN.md) — read before writing any code

This repo is driven phase-by-phase from `ACTION_PLAN.md`, using **Spec-Driven Development**:

1. Before implementing a phase, write `specs/NN-phase-name.md` (goal, interface/contract, out-of-scope notes, definition of done).
2. **Pause and get explicit approval on the spec before implementing.** Do not proceed to code on your own judgment of "close enough."
3. Once approved, implement the feature and its tests together in the same pass (not tests-after, not strict TDD red/green).
4. Definition of done for every phase: spec approved → implemented → tests passing → validated against LocalStack → PR merged to `develop`.
5. Don't jump ahead — each phase in `ACTION_PLAN.md` assumes prior phases are already merged. If a phase seems to drift into an out-of-scope area (per `README.md`), stop and flag it rather than expanding scope silently.

Branching is Git Flow: work happens on `feature/<phase-slug>` branches PR'd into `develop`; `develop` → `release/*` → `main` only when a batch of phases is ready to hit the real AWS sandbox account.

## Architecture

```
Transactions (DynamoDB, Streams: NEW_IMAGE)
        │ (event source mapping)
        ▼
stream-processor (Lambda, Java 25)
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
fraud-review-consumer (Lambda, Java 25)
        │
        ▼
FraudReviewCases (DynamoDB)
```

Key design point: DynamoDB Streams natively support at most 2 direct Lambda consumers, so SNS sits between the stream processor and the queues specifically to remove that ceiling and let independent consumers be added later without touching the producer. `customer-notification-queue` exists only to demonstrate fan-out — it has no real consumer/notification logic and (per the plan) skips a DLQ since nothing consumes it yet.

## Tech stack

| Concern | Choice |
|---|---|
| Lambda language/runtime | Java 25 (Maven) |
| IaC | Terraform (local state — no remote backend for this project) |
| Local iteration | LocalStack (via Docker) |
| Real deploy target | AWS sandbox account (never shared/production) |
| CI/CD | GitHub Actions — build/test on PR, deploy to LocalStack on merge to `develop`, deploy to real AWS on merge to `main` (behind manual-approval GitHub Environment) |
| AWS auth in CI | GitHub OIDC → AWS IAM role, not long-lived static credentials |

## Repository layout (target — being built incrementally per ACTION_PLAN.md)

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
│   ├── stream-processor/         # Java 25 Maven module
│   └── fraud-review-consumer/    # Java 25 Maven module
├── docker-compose.yml            # LocalStack
└── .github/workflows/
    ├── ci.yml
    ├── deploy-localstack.yml
    └── deploy-aws.yml
```

## Commands

No build, lint, or test tooling exists yet (no Maven modules, Terraform, or CI config have been created). Once Phase 0 scaffolding lands, update this section with the actual `mvn`/`terraform`/`docker-compose` commands rather than guessing at them now.

## Cost hygiene

After any session against the real AWS sandbox account, run `terraform destroy` (see "Cleanup" in `ACTION_PLAN.md` Phase 7) — resources should not be left running between sessions. LocalStack resources are ephemeral/local-only and need no equivalent cleanup.
