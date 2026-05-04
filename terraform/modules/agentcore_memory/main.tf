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
