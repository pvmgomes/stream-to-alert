# Billing mode is intentionally hardcoded to on-demand (PAY_PER_REQUEST),
# not exposed as a variable — see README.md's cost-hygiene notes. Nothing
# in this project needs provisioned throughput.
resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key
  range_key    = var.range_key

  attribute {
    name = var.hash_key
    type = var.hash_key_type
  }

  dynamic "attribute" {
    for_each = var.range_key == null ? [] : [1]
    content {
      name = var.range_key
      type = var.range_key_type
    }
  }

  stream_enabled   = var.stream_enabled
  stream_view_type = var.stream_enabled ? var.stream_view_type : null
}
