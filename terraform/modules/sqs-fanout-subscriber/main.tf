resource "aws_sqs_queue" "dlq" {
  count = var.create_dlq ? 1 : 0

  name = "${var.queue_name}-dlq"
}

resource "aws_sqs_queue" "this" {
  name = var.queue_name

  redrive_policy = var.create_dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = var.max_receive_count
  }) : null
}

# Required for SNS to be allowed to deliver to this queue — without it the
# subscription is created but messages silently fail to deliver.
data "aws_iam_policy_document" "allow_sns_publish" {
  statement {
    sid       = "AllowSnsPublish"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.topic_arn]
    }
  }
}

resource "aws_sqs_queue_policy" "this" {
  queue_url = aws_sqs_queue.this.id
  policy    = data.aws_iam_policy_document.allow_sns_publish.json
}

resource "aws_sns_topic_subscription" "this" {
  topic_arn            = var.topic_arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.this.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.this]
}
