variable "agent_runtime_name" {
  description = "Name of the AgentCore agent runtime"
  type        = string
}

variable "description" {
  description = "Description of the agent runtime"
  type        = string
  default     = ""
}

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
}

variable "ecr_image_uri" {
  description = "Full ECR image URI (repository_url:tag)"
  type        = string
}

variable "network_mode" {
  description = "Network mode: PUBLIC or VPC"
  type        = string
  default     = "PUBLIC"
}

variable "environment_variables" {
  description = "Environment variables for the agent runtime"
  type        = map(string)
  default     = {}
}

variable "additional_secret_arns" {
  description = "Extra Secrets Manager ARNs the runtime is allowed to read (e.g., gateway client credentials)"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
