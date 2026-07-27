# SQS subscribers (fraud-review-queue, customer-notification-queue) live in
# the sqs-fanout-subscriber module, not here — see specs/03-sns-sqs-fanout.md.
resource "aws_sns_topic" "this" {
  name = var.topic_name
}
