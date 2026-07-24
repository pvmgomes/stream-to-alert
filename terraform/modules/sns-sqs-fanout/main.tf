# SQS queues and subscriptions (fraud-review-queue, customer-notification-queue)
# are added in Phase 3 — see specs/03-sns-sqs-fanout.md. This phase only needs
# the topic itself so the stream processor Lambda has something to publish to.
resource "aws_sns_topic" "this" {
  name = var.topic_name
}
