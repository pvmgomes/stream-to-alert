variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "queue_arn" {
  description = "ARN of the SQS queue to trigger this Lambda from"
  type        = string
}

variable "table_arn" {
  description = "ARN of the DynamoDB table this Lambda writes case records to"
  type        = string
}

variable "table_name" {
  description = "Name of the DynamoDB table this Lambda writes case records to"
  type        = string
}

variable "jar_path" {
  description = "Path to the shaded Lambda deployment jar"
  type        = string
}

variable "batch_size" {
  description = "Maximum number of SQS messages delivered per invocation"
  type        = number
  default     = 10
}
