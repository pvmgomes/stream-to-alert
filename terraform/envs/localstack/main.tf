module "transactions_table" {
  source = "../../modules/dynamodb-table"

  table_name       = "Transactions"
  hash_key         = "accountId"
  range_key        = "transactionId"
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}

module "transaction_alerts_topic" {
  source = "../../modules/sns-topic"

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

module "stream_processor" {
  source = "../../modules/stream-processor-lambda"

  function_name = "stream-processor"
  stream_arn    = module.transactions_table.stream_arn
  sns_topic_arn = module.transaction_alerts_topic.topic_arn
  jar_path      = "${path.module}/../../../services/stream-processor/target/stream-processor.jar"
}
