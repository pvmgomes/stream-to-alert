variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "stream_arn" {
  description = "ARN of the DynamoDB Stream to attach as an event source"
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic to publish notable transactions to"
  type        = string
}

variable "jar_path" {
  description = "Path to the shaded Lambda deployment jar"
  type        = string
}

variable "threshold" {
  description = "Transaction amount threshold above which an alert is published"
  type        = string
  default     = "10000"
}
