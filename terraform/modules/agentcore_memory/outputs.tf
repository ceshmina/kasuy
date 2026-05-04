output "memory_id" {
  description = "ID of the AgentCore Memory resource"
  value       = aws_bedrockagentcore_memory.this.id
}

output "memory_arn" {
  description = "ARN of the AgentCore Memory resource"
  value       = aws_bedrockagentcore_memory.this.arn
}

output "user_preference_strategy_id" {
  description = "ID of the USER_PREFERENCE strategy"
  value       = aws_bedrockagentcore_memory_strategy.user_preference.memory_strategy_id
}
