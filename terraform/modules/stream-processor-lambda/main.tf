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

# Scoped to exactly what this Lambda needs: read the one DynamoDB stream it's
# attached to, publish to the one SNS topic it alerts on, and write its own
# CloudWatch log group.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid = "ReadDynamoDbStream"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = [var.stream_arn]
  }

  statement {
    sid       = "PublishTransactionAlerts"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
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
  handler          = "com.streamtoalert.streamprocessor.StreamProcessorHandler"
  runtime          = "java21"
  filename         = var.jar_path
  source_code_hash = filebase64sha256(var.jar_path)
  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      SNS_TOPIC_ARN = var.sns_topic_arn
      THRESHOLD     = var.threshold
    }
  }
}

resource "aws_lambda_event_source_mapping" "this" {
  event_source_arn  = var.stream_arn
  function_name     = aws_lambda_function.this.arn
  starting_position = "LATEST"
  batch_size        = 10
}
