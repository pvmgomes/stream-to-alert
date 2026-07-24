# Credentials come from the caller's environment (local AWS CLI profile, or
# GitHub OIDC → IAM role in CI per Phase 5) — never hardcoded here.
provider "aws" {
  region = var.aws_region
}
