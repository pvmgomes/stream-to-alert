# Spec 03 — SNS topic + SQS fan-out

## Goal

Extend the existing `transaction-alerts` SNS topic (created in Phase 2) with
two SQS subscribers, so a published alert fans out to both a fraud-review
leg and a customer-notification leg, per `README.md`'s architecture.

This phase only wires the queues and subscriptions — no Lambda consumes
`fraud-review-queue` yet (that's Phase 4). Verification is done by reading
messages off both queues directly.

## Decisions needing sign-off before implementation

1. **`fraud-review-queue` gets a DLQ + redrive policy; `customer-notification-queue`
   does not.** Matches `ACTION_PLAN.md` Phase 3 and `README.md`'s "Explicitly
   out of scope" — `customer-notification-queue` has no consumer yet, so
   there's nothing that can fail and redrive. `maxReceiveCount = 5` on the
   redrive policy (arbitrary but standard default; nothing in this project
   depends on a specific value).

2. **The topic module and the queue module are split, single-purpose,
   each reused per instance — not one dual-mode module.** Two options were
   considered:
   - Extend `sns-sqs-fanout` into a grab-bag module that creates *either*
     a topic *or* a queue depending on which variables are non-null. This
     was drafted first but rejected: it bolts two unrelated resource
     types onto one module whose variable surface depends on the call
     site, and no call site ever needs both modes at once — pure
     speculative flexibility, at odds with this project's "don't design
     for hypothetical future requirements" guidance.
   - **Split into two single-purpose modules (chosen):**
     - `terraform/modules/sns-topic` — renamed from `sns-sqs-fanout`.
       Content is unchanged from Phase 2 (just `aws_sns_topic.this`); only
       the directory name changes, because after this phase the module
       does exactly one job (create a topic) and the old "fanout" name no
       longer describes it — the fan-out now lives in the new queue
       module. Both envs' `source` path for the existing
       `transaction_alerts_topic` call updates accordingly; the module
       *content* and its local call label are untouched.
     - `terraform/modules/sqs-fanout-subscriber` — new. Does exactly one
       thing: given an existing topic ARN, create one queue, subscribe it
       to that topic, and optionally create a DLQ + redrive policy.
       Instantiated once per queue (twice total).

   This mirrors Phase 1's `dynamodb-table` pattern — one generic module,
   reused per resource — but each module here has a single, unambiguous
   job, so a reader never has to figure out which variables apply to a
   given call site.

3. **Subscription filter policy: none.** Both queues get every message
   published to the topic (plain fan-out, no attribute-based filtering).
   Nothing in the plan calls for routing different alert types to different
   queues.

## Interface / contract

### `terraform/modules/sns-topic` (renamed from `sns-sqs-fanout`)

Unchanged from Phase 2 — `topic_name` variable, `aws_sns_topic.this`
resource, `topic_arn` output. This phase's diff for this module is the
directory rename only; `git mv terraform/modules/sns-sqs-fanout
terraform/modules/sns-topic`.

### `terraform/modules/sqs-fanout-subscriber` (new)

**Variables:**
| Name | Type | Default | Notes |
|---|---|---|---|
| `queue_name` | string | — | required |
| `topic_arn` | string | — | required; ARN of the existing topic to subscribe to |
| `create_dlq` | bool | `false` | creates a DLQ + redrive policy for this queue when true |
| `max_receive_count` | number | `5` | redrive threshold; only used when `create_dlq = true` |

**Resources:**
- `aws_sqs_queue.this` — the queue itself; when `create_dlq = true`, its
  `redrive_policy` references the DLQ's ARN.
- `aws_sqs_queue.dlq` (count = `create_dlq ? 1 : 0`) — named
  `"${queue_name}-dlq"`.
- `aws_sns_topic_subscription.this` — `protocol = "sqs"`,
  `endpoint = aws_sqs_queue.this.arn`, `raw_message_delivery = true`.
- `aws_sqs_queue_policy.this` — allows `sns.amazonaws.com` to
  `sqs:SendMessage` to this queue, condition-scoped to `topic_arn`
  (standard SNS→SQS subscription requirement; without this the
  subscription is created but messages silently fail to deliver).

**Outputs:** `queue_arn`, `queue_url`, `dlq_arn` (empty string when
`create_dlq = false`).

### Env wiring

Both `terraform/envs/localstack/main.tf` and `terraform/envs/aws/main.tf`:

```hcl
module "transaction_alerts_topic" {
  source = "../../modules/sns-topic"   # was ../../modules/sns-sqs-fanout

  topic_name = "transaction-alerts"
}

module "fraud_review_queue" {
  source = "../../modules/sqs-fanout-subscriber"

  queue_name = "fraud-review-queue"
  topic_arn  = module.transaction_alerts_topic.topic_arn
  create_dlq = true
}

module "customer_notification_queue" {
  source = "../../modules/sqs-fanout-subscriber"

  queue_name = "customer-notification-queue"
  topic_arn  = module.transaction_alerts_topic.topic_arn
  create_dlq = false
}
```

### Verification on LocalStack

1. `terraform apply` in `envs/localstack` (stream-processor jar from Phase 2
   must already be built/deployed).
2. Insert a notable transaction (`amount` > 10000) via
   `aws --endpoint-url=http://localhost:4566 dynamodb put-item`, same as
   Phase 2's check.
3. Confirm delivery to **both** queues:
   ```
   aws --endpoint-url=http://localhost:4566 sqs receive-message \
     --queue-url <fraud-review-queue-url>
   aws --endpoint-url=http://localhost:4566 sqs receive-message \
     --queue-url <customer-notification-queue-url>
   ```
   Each should return one message whose body is the raw alert JSON from
   Phase 2 (not wrapped in an SNS envelope — confirms
   `raw_message_delivery = true` took effect).
4. Confirm the DLQ exists on `fraud-review-queue` only:
   `aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes
   --queue-url <fraud-review-queue-url> --attribute-names RedrivePolicy`
   returns a policy; the same call against
   `customer-notification-queue` returns no `RedrivePolicy` attribute.

## Out of scope for this phase

- `fraud-review-consumer` Lambda / event source mapping on
  `fraud-review-queue` — Phase 4.
- `FraudReviewCases` table — Phase 4.
- Any consumer/logic on `customer-notification-queue` — permanently out of
  scope per `README.md`.
- Message filtering/attribute-based routing on the subscriptions.
- CI/CD deploy workflows — Phase 5.

## Definition of done

- [ ] `terraform/modules/sns-sqs-fanout` renamed to
      `terraform/modules/sns-topic`; content otherwise unchanged.
- [ ] `terraform/modules/sqs-fanout-subscriber` implemented per the
      contract above (queue + optional DLQ + subscription + queue policy).
- [ ] Both envs: topic module call's `source` updated to `sns-topic`; new
      `fraud_review_queue` (with DLQ) and `customer_notification_queue`
      (without DLQ) module calls added, wired to the existing topic.
- [ ] `terraform fmt`/`validate` clean in both envs.
- [ ] LocalStack validation per "Verification" above passes: both queues
      receive a raw (unwrapped) copy of a notable alert; DLQ exists only on
      `fraud-review-queue`.
- [ ] `terraform destroy` against LocalStack cleans up without error.
- [ ] Work done on `feature/03-sns-sqs-fanout`, PR'd into `develop`.
