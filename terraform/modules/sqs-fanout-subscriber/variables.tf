variable "queue_name" {
  description = "Name of the SQS queue"
  type        = string
}

variable "topic_arn" {
  description = "ARN of the existing SNS topic this queue subscribes to"
  type        = string
}

variable "create_dlq" {
  description = "Whether to create a dead-letter queue and redrive policy for this queue"
  type        = bool
  default     = false
}

variable "max_receive_count" {
  description = "Number of receives before a message is moved to the DLQ. Ignored if create_dlq is false."
  type        = number
  default     = 5
}
