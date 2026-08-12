variable "table_name" {
  description = "Name of the DynamoDB table"
  type        = string
}

variable "hash_key" {
  description = "Attribute name used as the partition key"
  type        = string
}

variable "hash_key_type" {
  description = "DynamoDB attribute type for the partition key (S, N, or B)"
  type        = string
  default     = "S"
}

variable "range_key" {
  description = "Attribute name used as the sort key. Omit for a table with no sort key."
  type        = string
  default     = null
}

variable "range_key_type" {
  description = "DynamoDB attribute type for the sort key (S, N, or B). Ignored if range_key is null."
  type        = string
  default     = "S"
}

variable "stream_enabled" {
  description = "Whether to enable a DynamoDB Stream on this table"
  type        = bool
  default     = false
}

variable "stream_view_type" {
  description = "Stream view type (e.g. NEW_IMAGE). Required if stream_enabled is true."
  type        = string
  default     = null
}
