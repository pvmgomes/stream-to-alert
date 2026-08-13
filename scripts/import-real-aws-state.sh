#!/usr/bin/env bash
# Recovers local Terraform state for terraform/envs/aws after a CI-driven
# apply. deploy-aws.yml runs `terraform apply` on an ephemeral GitHub
# Actions runner with no backend configured (this project uses local state
# by design — see CLAUDE.md's tech stack table), so whatever state that
# apply produced is discarded when the job ends. The resources it created
# are real and billed, but as far as any local `terraform` command is
# concerned, they don't exist.
#
# This script re-derives that state by importing each resource `main.tf`
# declares, using the actual AWS-assigned identifiers (queue URLs,
# subscription ARNs, event-source-mapping UUIDs, ...) looked up live via
# the AWS CLI rather than hardcoded, so it stays correct as long as the
# resource *names* in terraform/envs/aws/main.tf don't change.
#
# Read-only against AWS: `terraform import` only reads the remote resource
# and writes to the local .tfstate file. It does not create, modify, or
# delete anything in the account. Run `terraform plan` afterward to see
# what (if anything) differs from HEAD's config, then `terraform destroy`
# as a separate, explicit step — see "Cleanup" in ACTION_PLAN.md Phase 7.
#
# Usage: scripts/import-real-aws-state.sh
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-sa-east-1}"
cd "$(dirname "$0")/../terraform/envs/aws"

terraform init -input=false >/dev/null

import() {
  local address="$1"
  local id="$2"
  if terraform state show "$address" >/dev/null 2>&1; then
    echo "==> ${address} already in state, skipping"
    return
  fi
  echo "==> Importing ${address} (id=${id})"
  terraform import -input=false "$address" "$id"
}

queue_url() {
  aws sqs get-queue-url --queue-name "$1" --query QueueUrl --output text
}

subscription_arn_for() {
  local queue_name="$1"
  local queue_arn="arn:aws:sqs:${AWS_DEFAULT_REGION}:$(aws sts get-caller-identity --query Account --output text):${queue_name}"
  aws sns list-subscriptions-by-topic \
    --topic-arn "arn:aws:sns:${AWS_DEFAULT_REGION}:$(aws sts get-caller-identity --query Account --output text):transaction-alerts" \
    --query "Subscriptions[?Endpoint=='${queue_arn}'].SubscriptionArn | [0]" --output text
}

mapping_uuid_for() {
  aws lambda list-event-source-mappings --function-name "$1" \
    --query 'EventSourceMappings[0].UUID' --output text
}

import module.transactions_table.aws_dynamodb_table.this "Transactions"
import module.fraud_review_cases_table.aws_dynamodb_table.this "FraudReviewCases"

import module.transaction_alerts_topic.aws_sns_topic.this \
  "arn:aws:sns:${AWS_DEFAULT_REGION}:$(aws sts get-caller-identity --query Account --output text):transaction-alerts"

FRAUD_QUEUE_URL="$(queue_url fraud-review-queue)"
FRAUD_DLQ_URL="$(queue_url fraud-review-queue-dlq)"
NOTIFY_QUEUE_URL="$(queue_url customer-notification-queue)"

import module.fraud_review_queue.aws_sqs_queue.this "$FRAUD_QUEUE_URL"
import "module.fraud_review_queue.aws_sqs_queue.dlq[0]" "$FRAUD_DLQ_URL"
import module.fraud_review_queue.aws_sqs_queue_policy.this "$FRAUD_QUEUE_URL"
import module.fraud_review_queue.aws_sns_topic_subscription.this "$(subscription_arn_for fraud-review-queue)"

import module.customer_notification_queue.aws_sqs_queue.this "$NOTIFY_QUEUE_URL"
import module.customer_notification_queue.aws_sqs_queue_policy.this "$NOTIFY_QUEUE_URL"
import module.customer_notification_queue.aws_sns_topic_subscription.this "$(subscription_arn_for customer-notification-queue)"

import module.stream_processor.aws_iam_role.this "stream-processor-role"
import module.stream_processor.aws_iam_role_policy.this "stream-processor-role:stream-processor-policy"
import module.stream_processor.aws_lambda_function.this "stream-processor"
import module.stream_processor.aws_lambda_event_source_mapping.this "$(mapping_uuid_for stream-processor)"

import module.fraud_review_consumer.aws_iam_role.this "fraud-review-consumer-role"
import module.fraud_review_consumer.aws_iam_role_policy.this "fraud-review-consumer-role:fraud-review-consumer-policy"
import module.fraud_review_consumer.aws_lambda_function.this "fraud-review-consumer"
import module.fraud_review_consumer.aws_lambda_event_source_mapping.this "$(mapping_uuid_for fraud-review-consumer)"

echo "==> Import complete. Run 'terraform plan' in terraform/envs/aws to review before destroying."
