variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
}

variable "event_expiry_days" {
  description = "Days short-term memory events are retained before expiry. Provider minimum is 7."
  type        = number
  default     = 7

  validation {
    condition     = var.event_expiry_days >= 7 && var.event_expiry_days <= 365
    error_message = "event_expiry_days must be between 7 and 365."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the memory's APPLICATION_LOGS delivery"
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
