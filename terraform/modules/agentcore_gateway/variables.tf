variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
}

variable "search_source_dir" {
  description = "Path to the search Lambda source directory"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the search Lambda"
  type        = number
  default     = 14
}

variable "search_lambda_timeout_seconds" {
  description = "Search Lambda timeout"
  type        = number
  default     = 60
}

variable "search_lambda_memory_mb" {
  description = "Search Lambda memory size"
  type        = number
  default     = 512
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
