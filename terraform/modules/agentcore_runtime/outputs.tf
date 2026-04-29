output "agent_runtime_id" {
  description = "The ID of the AgentCore agent runtime"
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
}

output "agent_runtime_arn" {
  description = "The ARN of the AgentCore agent runtime"
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

output "endpoint_arn" {
  description = "The ARN of the runtime endpoint"
  value       = aws_bedrockagentcore_agent_runtime_endpoint.this.agent_runtime_endpoint_arn
}

output "endpoint_name" {
  description = "The name of the runtime endpoint (used as qualifier when invoking)"
  value       = aws_bedrockagentcore_agent_runtime_endpoint.this.name
}

output "role_arn" {
  description = "The ARN of the IAM role used by the runtime"
  value       = aws_iam_role.this.arn
}
