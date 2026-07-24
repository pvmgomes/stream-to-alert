module "transactions_table" {
  source = "../../modules/dynamodb-table"

  table_name       = "Transactions"
  hash_key         = "accountId"
  range_key        = "transactionId"
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}
