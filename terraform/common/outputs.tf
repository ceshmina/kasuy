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

output "endpoint_name" {
  description = "The AgentCore runtime endpoint name (used as qualifier when invoking)"
  value       = module.agent_runtime.endpoint_name
}

output "role_arn" {
  description = "The IAM role ARN used by the runtime"
  value       = module.agent_runtime.role_arn
}

output "slack_request_url" {
  description = "URL to register in Slack App Event Subscriptions Request URL"
  value       = module.slack_integration.slack_request_url
}

output "slack_secret_name" {
  description = "Name of the Secrets Manager secret holding Slack credentials"
  value       = module.slack_integration.slack_secret_name
}

output "gateway_id" {
  description = "AgentCore Gateway ID"
  value       = module.agentcore_gateway.gateway_id
}

output "gateway_url" {
  description = "AgentCore Gateway MCP endpoint URL"
  value       = module.agentcore_gateway.gateway_url
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID for Gateway M2M authentication"
  value       = module.agentcore_gateway.cognito_user_pool_id
}

output "cognito_app_client_id" {
  description = "Cognito M2M App Client ID"
  value       = module.agentcore_gateway.cognito_app_client_id
}

output "agentcore_gateway_client_secret_name" {
  description = "Secrets Manager name holding Cognito M2M client credentials"
  value       = module.agentcore_gateway.client_secret_name
}

output "tavily_secret_name" {
  description = "Secrets Manager name holding the Tavily API key"
  value       = module.agentcore_gateway.tavily_secret_name
}

output "search_function_name" {
  description = "Search Lambda function name"
  value       = module.agentcore_gateway.search_function_name
}

output "agent_memory_id" {
  description = "AgentCore Memory ID used by the runtime for per-user long-term memory"
  value       = module.agentcore_memory.memory_id
}
