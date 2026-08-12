# Spec 05 — CI/CD pipeline

## Goal

Two new GitHub Actions workflows on top of the existing `ci.yml`
(build/test on PR, unchanged):

- `deploy-localstack.yml` — on merge to `develop`, stand up LocalStack in
  the runner, `terraform apply` the full stack, and run an automated
  end-to-end smoke test (the Phase 4 verification, scripted).
- `deploy-aws.yml` — on merge to `main`, `terraform apply` against the
  real AWS sandbox account, authenticated via GitHub OIDC, gated behind a
  GitHub Environment requiring manual approval.

## Decisions needing sign-off before implementation

1. **Local Terraform state breaks repeat `deploy-aws.yml` runs — how do we
   handle it?** `terraform/envs/aws` deliberately has no remote backend
   (per `CLAUDE.md`/`README.md`: local state only). That's fine for
   `deploy-localstack.yml`, where the entire environment (LocalStack
   container + state) is recreated from nothing every run — no
   cross-run memory needed. It's *not* fine for `deploy-aws.yml`: a
   GitHub-hosted runner starts every job with an empty filesystem, so
   `terraform apply` has no record of what it created last time. A second
   deploy would try to recreate already-existing resources (DynamoDB
   `ResourceInUseException`, IAM `EntityAlreadyExists`, Lambda
   `ResourceConflictException`, etc.).

   Three ways to resolve this, in order of how much they expand scope:
   - **(a) Accept the constraint, document it.** `deploy-aws.yml` only
     works correctly if the account is empty when it runs — i.e. Phase
     7's `terraform destroy` runbook was followed after the *previous*
     session. This adds zero infrastructure but makes the pipeline
     fragile to a missed teardown; the next `deploy-aws.yml` run simply
     fails loudly (not silently) until someone runs `terraform destroy`
     by hand and retries. Matches this project's "practice reps, not a
     product" framing and Phase 7's existing expectation that the real
     account is torn down between sessions anyway.
   - **(b) Persist state as a GitHub Actions artifact/cache** between
     runs. Avoids new AWS infra, but caches are evictable and there's no
     real locking — two close-together runs could race. A band-aid, not
     a real fix.
   - **(c) Add a minimal remote backend** (S3 bucket + DynamoDB lock
     table) for the `aws` env only. The "correct" production answer, but
     it contradicts this project's explicit local-state-only decision and
     adds a small permanent piece of infrastructure (plus the same
     bootstrapping problem one level down: something has to create the
     bucket/table before Terraform can use them as a backend).

   **Decision: (a).** This project's own Phase 7 already establishes the
   discipline of destroying the real stack after each session; a CI
   pipeline that assumes that discipline and fails clearly when it's
   skipped is simpler and more honest than adding remote-state
   infrastructure to work around not following it.

   **Path to a production-grade version of this (documented here, not
   implemented):** if this project's `aws` env ever needed to tolerate
   out-of-order applies or a forgotten teardown, the standard fix is an
   S3 backend + DynamoDB lock table, scoped to this env only:
   - An S3 bucket (versioned, default-encrypted, public access blocked)
     holding `envs/aws/terraform.tfstate`.
   - A small DynamoDB table (`LockID` as hash key, on-demand billing) so
     concurrent `terraform apply` runs can't corrupt state — the same
     locking problem callout in decision (b) above.
   - A `backend "s3" { ... }` block added to
     `terraform/envs/aws/versions.tf`, with the bucket/table
     themselves created by *another* one-time bootstrap step (same
     chicken-and-egg shape as decision 2 below — something has to create
     the backend before Terraform can use it as a backend).
   - CI would then need `s3:GetObject`/`PutObject`/`ListBucket` on that
     bucket and `dynamodb:GetItem`/`PutItem`/`DeleteItem` on the lock
     table added to the deploy role's policy.

   Deliberately not building this now — it's a real infrastructure
   commitment (a permanently-running bucket + table, however cheap) for a
   project whose whole premise is short-lived practice sessions that get
   torn down. Worth revisiting if the real-AWS leg of this project ever
   stops being "spin up, validate, destroy."

2. **GitHub OIDC → IAM role requires a one-time bootstrap in the real AWS
   account — done manually via the AWS Console, not Terraform.** There's
   a chicken-and-egg problem: CI can't assume a role via OIDC until that
   role (and the OIDC identity provider) already exist, and nothing can
   create them via OIDC before they exist. Rather than adding a
   `terraform/bootstrap/` root (which just relocates the "whose state is
   this and who applies it" question one level down), this is a manual,
   one-time AWS Console procedure — see the runbook below. The resulting
   role ARN gets stored as a repo variable (`AWS_DEPLOY_ROLE_ARN`, not a
   secret — role ARNs aren't sensitive) for `deploy-aws.yml` to
   reference.

3. **`deploy-localstack.yml` reuses `docker-compose.yml` directly**
   (`docker compose up -d` as a workflow step) rather than reimplementing
   the LocalStack container via GitHub Actions' `services:` block. Keeps
   one source of truth for the LocalStack config instead of two YAML
   files that can drift, and matches exactly how this has been manually
   validated in every phase so far.

4. **The Phase 4 smoke test becomes a real script**,
   `scripts/smoke-test-localstack.sh`, callable both from CI and locally.
   It: builds nothing itself (jars are built in an earlier workflow step);
   inserts a notable transaction, polls `FraudReviewCases` with a
   timeout/retry loop until the case row appears (or fails loudly after a
   timeout — no fixed `sleep`, since CI runner speed varies) and asserts
   its fields; inserts a non-notable transaction and asserts no case row
   appears for it. This is what Phase 4's spec deferred ("automating it
   into a repeatable smoke test is explicitly Phase 5's job") — not new
   scope.

5. **`deploy-aws.yml` does not run `terraform destroy`.** Teardown stays a
   deliberate, manual, human-run step per Phase 7 — automating destroy
   into the deploy pipeline would silently tear down a stack someone
   might still be using for Phase 6 manual validation.

## Interface / contract

### OIDC role setup — manual AWS Console runbook (one-time, done by you)

**1. Create the OIDC identity provider** (skip if it already exists — an
AWS account only needs one GitHub OIDC provider total, shared across all
repos/roles that use it):
- IAM → *Identity providers* → **Add provider**.
- Provider type: **OpenID Connect**.
- Provider URL: `https://token.actions.githubusercontent.com`.
- Audience: `sts.amazonaws.com`.
- Get thumbprint / Add provider — the console fetches and verifies this
  for you.

**2. Create the deploy role**:
- IAM → *Roles* → **Create role**.
- Trusted entity type: **Web identity**.
- Identity provider: the `token.actions.githubusercontent.com` provider
  from step 1. Audience: `sts.amazonaws.com`.
- GitHub organization: `pvmgomes`. Repository: `stream-to-alert`. Branch:
  `main`. (The console's GitHub-specific fields generate a trust policy
  condition scoped to
  `repo:pvmgomes/stream-to-alert:ref:refs/heads/main` — this role is only
  assumable from a workflow run triggered by a push to `main`, not from
  PRs or other branches.)
- Skip attaching a managed policy on the "Add permissions" step — attach
  the inline policy in step 3 instead.
- Name: `github-actions-deploy-stream-to-alert`. Create role.
- **After creating the role, edit its trust policy** (IAM → Roles →
  this role → *Trust relationships* → **Edit trust policy**) — the
  console wizard's generated `sub` condition doesn't actually work as-is.
  GitHub's real OIDC tokens include numeric ID qualifiers alongside the
  org/repo names (`repo:pvmgomes@<user-id>/stream-to-alert@<repo-id>:ref:...`),
  confirmed via CloudTrail during Phase 6's first real deploy attempt (see
  `specs/06-real-aws-validation.md`) — the console's plain
  `repo:pvmgomes/stream-to-alert:ref:refs/heads/main` pattern never
  actually matches anything. Replace the `sub` condition's `StringLike`
  list with both forms so it works regardless of whether GitHub is
  sending ID-qualified subjects for this token type:
  ```json
  "StringLike": {
    "token.actions.githubusercontent.com:sub": [
      "repo:pvmgomes/stream-to-alert:ref:refs/heads/main",
      "repo:pvmgomes@*/stream-to-alert@*:ref:refs/heads/main"
    ]
  }
  ```

**3. Attach an inline policy** scoped to the six AWS services this
project uses, with `iam:*` further restricted to this project's Lambda
role naming convention rather than unrestricted IAM access:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProjectResources",
      "Effect": "Allow",
      "Action": [
        "dynamodb:*",
        "sns:*",
        "sqs:*",
        "lambda:*",
        "logs:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProjectLambdaRoles",
      "Effect": "Allow",
      "Action": "iam:*",
      "Resource": [
        "arn:aws:iam::*:role/stream-processor-role*",
        "arn:aws:iam::*:role/fraud-review-consumer-role*"
      ]
    }
  ]
}
```
(IAM policies don't support scoping `dynamodb`/`sns`/`sqs`/`lambda`/`logs`
actions to this project's specific resource names without significant
extra complexity — those five stay account-wide *for this personal
sandbox account*, matching "never shared/production" in `README.md`. Only
`iam:*` — the one action set with real blast radius beyond this project's
own resources — is resource-scoped.)

**4. Wire the role into GitHub**: copy the role's ARN from the IAM
console, then in the repo: *Settings → Secrets and variables → Actions →
Variables* → **New repository variable** → name `AWS_DEPLOY_ROLE_ARN`,
value the role ARN.

**5. Create the `aws-sandbox` GitHub Environment**: *Settings →
Environments* → **New environment** → name `aws-sandbox`.

**Addendum — required reviewers turned out not to be available:**
confirmed directly against the GitHub API (not just the UI) that
environment protection rules (required reviewers) *and* classic branch
protection *and* the newer repository rulesets are all blocked with
"Upgrade to GitHub Pro or make this repository public to enable this
feature" — this repo is private, and GitHub Free doesn't include any
server-side merge/deploy gating for private repos, not just the
environment-reviewers feature originally planned. Decision: skip the
gate for now rather than upgrade the plan or make the repo public. The
`aws-sandbox` environment still exists but currently enforces
nothing — the real checkpoint is that nothing in this project auto-merges
to `main`; every merge so far has been a deliberate, human-clicked PR
merge, which is already the point at which a real deploy becomes
possible. You can also watch/cancel a run from the Actions tab before it
reaches `terraform apply`.

**Second addendum (Phase 6) — `deploy-aws.yml` stopped targeting this
environment entirely:** referencing `environment: aws-sandbox` in the job
turned out to actively break OIDC auth, not just fail to add protection.
GitHub changes the token's `sub` claim format for any job that references
an environment — from `repo:OWNER/REPO:ref:refs/heads/main` to
`repo:OWNER/REPO:environment:aws-sandbox` — which the trust policy from
step 2 above doesn't match, since it was written assuming the
branch-based format. Diagnosed via CloudTrail during Phase 6's first real
deploy attempt (see `specs/06-real-aws-validation.md`). Since the
environment wasn't providing any enforcement anyway (per the first
addendum), the fix was to drop `environment: aws-sandbox` from
`deploy-aws.yml` rather than update the trust policy — restores the
working branch-based subject with no AWS-side change needed. The
`aws-sandbox` environment itself still exists (harmless, unreferenced)
in case it becomes useful again if this repo ever goes public or moves to
a paid plan.

### `.github/workflows/deploy-localstack.yml` (new)

Trigger: `on: push: branches: [develop]`.

Steps: checkout → set up JDK 21 → `mvn package` both `services/*` modules
→ `docker compose up -d` → wait for LocalStack health endpoint →
`terraform init && terraform apply -auto-approve` in `envs/localstack` →
run `scripts/smoke-test-localstack.sh` → `terraform destroy -auto-approve`
→ `docker compose down` (always, via `if: always()`, so a failed smoke
test still cleans up the runner).

### `.github/workflows/deploy-aws.yml` (new)

Trigger: `on: push: branches: [main]`.

`permissions: id-token: write, contents: read` (required for OIDC). Does
*not* set `environment:` — see the second addendum to runbook step 5:
doing so changes the OIDC token's subject format and broke role
assumption entirely, for an environment that wasn't enforcing anything
anyway.

Steps: checkout → set up JDK 21 → `mvn package` both `services/*` modules
→ `aws-actions/configure-aws-credentials@v4` with
`role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}` → `terraform init &&
terraform apply -auto-approve` in `envs/aws`. No destroy step (see
decision 5).

### `scripts/smoke-test-localstack.sh` (new)

Bash, targets `http://localhost:4566`. Exits non-zero with a clear message
on any assertion failure or timeout (default timeout: 30s, polling every
2s). Steps per decision 4 above.

## Out of scope for this phase

- Adding a remote Terraform backend (see decision 1 — deliberately not
  doing this).
- Phase 6's actual real-AWS validation run — this phase only builds the
  pipeline that *would* run it; first real trigger of `deploy-aws.yml` is
  Phase 6.
- Phase 7's teardown automation — stays a manual runbook.
- Release-branch tooling (`release/*` merge mechanics) — out of scope for
  both `README.md` and this plan; `main` is just "the branch that
  triggers real deploys," however a commit gets there.

## Definition of done

- [ ] OIDC identity provider + deploy role created via the AWS Console
      runbook above; `AWS_DEPLOY_ROLE_ARN` repo variable set from the
      role's ARN.
- [ ] `aws-sandbox` GitHub Environment created. Required reviewer
      deliberately not configured — unavailable on this repo's
      private+Free plan combination (confirmed via API); see the
      addendum to runbook step 5.
- [ ] `scripts/smoke-test-localstack.sh` implemented and runnable locally
      against a `docker compose up -d` LocalStack instance.
- [ ] `.github/workflows/deploy-localstack.yml` implemented per the
      contract above; a push to `develop` runs it end-to-end successfully
      (apply → smoke test passes → destroy).
- [ ] `.github/workflows/deploy-aws.yml` implemented per the contract
      above; not yet triggered for real (that's Phase 6) but validated via
      `terraform validate`/`plan` locally against the `aws` env.
- [ ] Work done on `feature/05-cicd-pipeline`, PR'd into `develop`.
