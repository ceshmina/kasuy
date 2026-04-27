################################################################################
# General
################################################################################

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "Deployment environment name (staging, production)"
  type        = string
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "kasuy"
}

################################################################################
# Agent Runtime
################################################################################

variable "agent_runtime_name" {
  description = "Base name for the AgentCore agent runtime"
  type        = string
  default     = "kasuy-qa-agent"
}

variable "agent_description" {
  description = "Description of the agent runtime"
  type        = string
  default     = "Simple Q&A agent using Strands Agents SDK"
}

variable "ecr_image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "network_mode" {
  description = "Network mode for the runtime (PUBLIC or VPC)"
  type        = string
  default     = "PUBLIC"
}

variable "agent_environment_variables" {
  description = "Environment variables passed to the agent runtime"
  type        = map(string)
  default     = {}
}
