# Spec 01 — Transactions table

## Goal

Add the `Transactions` DynamoDB table with a stream enabled, as the source
event for the stream-processor Lambda in Phase 2. Deploy it to LocalStack
and verify it exists and streams correctly, via Terraform.

## Interface / contract

### `terraform/modules/dynamodb-table` (generic, reusable module)

The target layout names this module `dynamodb-table` (singular, not
`transactions-table`), and Phase 4 needs a second table
(`FraudReviewCases`). So this module is generic/parameterized rather than
hardcoded to `Transactions`, and Phase 4 will reuse it instead of adding a
second module.

Variables:

| Name | Type | Default | Notes |
|---|---|---|---|
| `table_name` | `string` | — | required |
| `hash_key` | `string` | — | required, attribute name |
| `hash_key_type` | `string` | `"S"` | |
| `range_key` | `string` | `null` | optional — omit for a table with no sort key |
| `range_key_type` | `string` | `"S"` | ignored if `range_key` is null |
| `stream_enabled` | `bool` | `false` | |
| `stream_view_type` | `string` | `null` | required if `stream_enabled = true` (e.g. `NEW_IMAGE`) |

Billing mode is hardcoded to `PAY_PER_REQUEST` (on-demand) inside the
module, not exposed as a variable — this matches the "on-demand billing"
cost-hygiene choice from `README.md` and there's no case in this project
that needs provisioned throughput.

Outputs: `table_name`, `table_arn`, `stream_arn` (`null` when
`stream_enabled = false`).

### `Transactions` table instantiation

New `terraform/envs/localstack/main.tf` and `terraform/envs/aws/main.tf`
(neither exists yet — this phase adds them), each calling the module:

```hcl
module "transactions_table" {
  source = "../../modules/dynamodb-table"

  table_name       = "Transactions"
  hash_key         = "accountId"
  range_key        = "transactionId"
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}
```

Both `accountId` and `transactionId` are strings (`S`). No GSIs — nothing
in this project queries the table by anything other than
`accountId`+`transactionId`.

### Verification

`awslocal` isn't installed in this environment; plain `aws` CLI against
LocalStack's endpoint is equivalent and what will actually be used:

```
aws --endpoint-url=http://localhost:4566 dynamodb describe-table --table-name Transactions
```

Confirms the table exists, `KeySchema` matches (`accountId` HASH,
`transactionId` RANGE), and `StreamSpecification` shows
`StreamEnabled: true` / `StreamViewType: NEW_IMAGE`.

## Out of scope for this phase

- The stream processor Lambda / event source mapping that reads this
  stream — Phase 2.
- `FraudReviewCases` table — Phase 4 (reuses this same module).
- Seeding any actual transaction data.
- GSIs, TTL, point-in-time recovery, or any other table feature not needed
  by a later phase in `ACTION_PLAN.md`.

## Definition of done

- [ ] `terraform/modules/dynamodb-table` module implemented per the
      contract above.
- [ ] `terraform/envs/localstack/main.tf` instantiates it as `Transactions`.
- [ ] `terraform/envs/aws/main.tf` instantiates it identically (same
      module call — no environment-specific divergence needed for a table).
- [ ] `terraform fmt` clean, `terraform validate` passes in both envs.
- [ ] `terraform apply` against LocalStack succeeds; `describe-table`
      confirms schema and stream settings as specified above.
- [ ] `terraform destroy` against LocalStack cleans up without error
      (sanity check — this table will be destroyed/recreated often during
      iteration).
- [ ] Work done on `feature/01-transactions-table`, PR'd into `develop`.
