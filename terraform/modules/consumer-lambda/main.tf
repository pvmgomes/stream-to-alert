data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Scoped to exactly what this Lambda needs: consume the one SQS queue it's
# triggered from, write to the one DynamoDB table it records cases in, and
# write its own CloudWatch log group.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid = "ConsumeFraudReviewQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "WriteFraudReviewCases"
    actions   = ["dynamodb:PutItem"]
    resources = [var.table_arn]
  }

  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/${var.function_name}:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.function_name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "this" {
  function_name    = var.function_name
  role             = aws_iam_role.this.arn
  handler          = "com.streamtoalert.fraudreviewconsumer.FraudReviewConsumerHandler"
  runtime          = "java21"
  filename         = var.jar_path
  source_code_hash = filebase64sha256(var.jar_path)
  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      TABLE_NAME = var.table_name
    }
  }
}

resource "aws_lambda_event_source_mapping" "this" {
  event_source_arn = var.queue_arn
  function_name    = aws_lambda_function.this.arn
  batch_size       = var.batch_size

  function_response_types = ["ReportBatchItemFailures"]
}
