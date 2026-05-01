output "gateway_id" {
  description = "AgentCore Gateway ID"
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_arn" {
  description = "AgentCore Gateway ARN"
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}

output "gateway_url" {
  description = "AgentCore Gateway MCP endpoint URL"
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID hosting the M2M client"
  value       = aws_cognito_user_pool.this.id
}

output "cognito_app_client_id" {
  description = "Cognito M2M App Client ID"
  value       = aws_cognito_user_pool_client.m2m.id
}

output "cognito_domain" {
  description = "Cognito hosted UI / OAuth domain prefix"
  value       = aws_cognito_user_pool_domain.this.domain
}

output "client_secret_name" {
  description = "Secrets Manager name holding Cognito M2M credentials"
  value       = aws_secretsmanager_secret.gateway_client.name
}

output "client_secret_arn" {
  description = "Secrets Manager ARN holding Cognito M2M credentials"
  value       = aws_secretsmanager_secret.gateway_client.arn
}

output "tavily_secret_name" {
  description = "Secrets Manager name holding Tavily API key"
  value       = aws_secretsmanager_secret.tavily.name
}

output "tavily_secret_arn" {
  description = "Secrets Manager ARN holding Tavily API key"
  value       = aws_secretsmanager_secret.tavily.arn
}

output "search_function_name" {
  description = "Search Lambda function name"
  value       = aws_lambda_function.search.function_name
}

output "search_function_arn" {
  description = "Search Lambda function ARN"
  value       = aws_lambda_function.search.arn
}
