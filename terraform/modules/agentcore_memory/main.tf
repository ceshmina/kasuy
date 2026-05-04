################################################################################
# AgentCore Memory (long-term per-Slack-user)
################################################################################
# A single managed Memory resource with a USER_PREFERENCE long-term strategy.
# The strategy's namespace uses {actorId}, so memories are auto-scoped per
# Slack user (the invoker passes actor_id = "team_id:user_id").
#
# Short-term events are still written by the SDK (that's how the system
# extracts long-term records), but `event_expiry_duration` is set to the
# provider minimum to keep STM ephemeral. The durable data lives under
# /preferences/{actorId}/ in long-term memory.

resource "aws_bedrockagentcore_memory" "this" {
  name                  = "${var.project_name}_${var.environment}_user_memory"
  description           = "Per-Slack-user long-term memory for the Kasuy agent"
  event_expiry_duration = var.event_expiry_days
  tags                  = var.tags
}

resource "aws_bedrockagentcore_memory_strategy" "user_preference" {
  name        = "user_preference"
  memory_id   = aws_bedrockagentcore_memory.this.id
  type        = "USER_PREFERENCE"
  description = "Per-actor preference learning (actorId = Slack team:user)"
  namespaces  = ["/preferences/{actorId}/"]
}

################################################################################
# Memory log delivery to CloudWatch
################################################################################
# Memory emits APPLICATION_LOGS covering long-term extraction/consolidation
# stages and DeleteMemory lifecycle events. The default vendedlogs path keeps
# them grouped consistently with the Runtime application logs.

resource "aws_cloudwatch_log_group" "memory" {
  name              = "/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/${aws_bedrockagentcore_memory.this.id}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_delivery_source" "memory" {
  name         = "${var.project_name}_${var.environment}_memory_app_logs"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_memory.this.arn
  tags         = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "memory" {
  name = "${var.project_name}_${var.environment}_memory_app_logs"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.memory.arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery" "memory" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.memory.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.memory.arn

  tags = var.tags
}
