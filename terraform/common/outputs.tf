output "ecr_repository_url" {
  description = "The ECR repository URL"
  value       = module.ecr.repository_url
}

output "agent_runtime_id" {
  description = "The AgentCore runtime ID"
  value       = module.agent_runtime.agent_runtime_id
}

output "agent_runtime_arn" {
  description = "The AgentCore runtime ARN"
  value       = module.agent_runtime.agent_runtime_arn
}

output "endpoint_arn" {
  description = "The AgentCore runtime endpoint ARN"
  value       = module.agent_runtime.endpoint_arn
}

output "endpoint_name" {
  description = "The AgentCore runtime endpoint name (used as qualifier when invoking)"
  value       = module.agent_runtime.endpoint_name
}

output "role_arn" {
  description = "The IAM role ARN used by the runtime"
  value       = module.agent_runtime.role_arn
}
