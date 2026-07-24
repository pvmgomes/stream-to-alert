# Spec 00 — Repo & environment scaffolding

## Goal

Bootstrap the repository so later phases (Transactions table, stream
processor, fan-out, consumer, CI/CD) have somewhere to land: Git Flow
branches, a CI skeleton that runs on every PR, a LocalStack `docker-compose`
setup, and the Terraform root/module directory structure. No AWS resources,
Lambda code, or actual Terraform resources are created in this phase.

## Interface / contract

### Git branches

- `develop` created from current `main`.
- This phase's work happens on `feature/00-scaffolding` (branched from
  `develop`), PR'd back into `develop`.
- The three currently-untracked docs (`README.md`, `ACTION_PLAN.md`,
  `CLAUDE.md`) are committed as part of this phase, since they predate the
  Git Flow setup and everything after this phase assumes they're tracked.

### `.github/workflows/ci.yml`

- Trigger: `pull_request` (any branch). Merge-triggered deploy workflows are
  out of scope here (Phase 5).
- Sets up JDK 25 (Temurin) + Maven, with dependency caching.
- Builds and unit-tests every Maven module under `services/*/pom.xml`, if
  any exist. Implemented as a loop/`find`-driven step rather than hardcoding
  module names, so it passes as a trivial no-op now (no `services/`
  subdirectories yet) and automatically picks up `stream-processor` and
  `fraud-review-consumer` in later phases without editing `ci.yml` again.

### `docker-compose.yml`

- Single `localstack/localstack` service, pinned to a specific major version
  tag (not `:latest`) for reproducibility.
- `SERVICES=dynamodb,sns,sqs,lambda`, port `4566` published, a healthcheck
  against the LocalStack health endpoint.
- No persistence volume — ephemeral/local-only, consistent with the
  "no cleanup needed for LocalStack" note in `ACTION_PLAN.md` Phase 7.

### Terraform root structure

Per the layout in `README.md`:

```
terraform/
├── modules/
│   ├── dynamodb-table/
│   ├── stream-processor-lambda/
│   ├── sns-sqs-fanout/
│   └── consumer-lambda/
└── envs/
    ├── localstack/
    └── aws/
```

- Each module directory gets a placeholder `main.tf` (empty/comment stub) —
  real resources are added in Phases 1–4, one module at a time.
- Each env (`localstack/`, `aws/`) gets `versions.tf` (Terraform + AWS
  provider version constraints) and `providers.tf`. `localstack/`'s provider
  block points at the LocalStack endpoint (`endpoints { dynamodb = ...,
  sns = ..., sqs = ..., lambda = ... }` on `http://localhost:4566`); `aws/`'s
  provider block targets real AWS (region only, no hardcoded credentials —
  those come from the caller's environment/CI OIDC role).
- No backend block in either env — local state, per `README.md`'s explicit
  "local state is fine for this project" note.
- `terraform init` should succeed in both envs even though there's nothing
  to `plan`/`apply` yet (no resources until Phase 1+).

## Out of scope for this phase

- Any actual Terraform resources (DynamoDB tables, Lambdas, SNS/SQS) —
  Phases 1–4.
- Any Lambda/Maven code — Phases 2 and 4.
- `deploy-localstack.yml` / `deploy-aws.yml` — Phase 5.
- GitHub Environment / OIDC role setup — Phase 5.

## Definition of done

- [ ] `develop` branch exists, pushed to `origin`.
- [ ] `feature/00-scaffolding` branch merged into `develop` via PR.
- [ ] `README.md`, `ACTION_PLAN.md`, `CLAUDE.md`, and this spec are committed.
- [ ] `docker compose up -d` starts LocalStack; health check reports
      `dynamodb`, `sns`, `sqs`, `lambda` as available.
- [ ] `.github/workflows/ci.yml` runs on the PR and passes (green) despite
      no Maven modules existing yet.
- [ ] `terraform init` succeeds in `terraform/envs/localstack` and
      `terraform/envs/aws`.
