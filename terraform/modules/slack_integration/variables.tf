variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
}

variable "agent_runtime_arn" {
  description = "ARN of the existing AgentCore agent runtime to invoke"
  type        = string
}

variable "agent_qualifier" {
  description = "Qualifier (endpoint name) used when invoking the AgentCore runtime"
  type        = string
}

variable "receiver_source_dir" {
  description = "Path to the receiver Lambda source directory"
  type        = string
}

variable "invoker_source_dir" {
  description = "Path to the invoker Lambda source directory"
  type        = string
}

variable "receiver_timeout_seconds" {
  description = "Timeout for the receiver Lambda (Slack requires response within 3s)"
  type        = number
  default     = 5
}

variable "receiver_memory_mb" {
  description = "Memory size for the receiver Lambda in MB"
  type        = number
  default     = 512
}

variable "invoker_timeout_seconds" {
  description = "Timeout for the invoker Lambda"
  type        = number
  default     = 900
}

variable "invoker_memory_mb" {
  description = "Memory size for the invoker Lambda in MB"
  type        = number
  default     = 1024
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for the Lambdas"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
