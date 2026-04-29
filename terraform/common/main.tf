module "ecr" {
  source = "../../modules/ecr"

  repository_name = "${var.project_name}-agent"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "agent_runtime" {
  source = "../../modules/agentcore_runtime"

  agent_runtime_name    = var.agent_runtime_name
  description           = var.agent_description
  environment           = var.environment
  ecr_image_uri         = "${module.ecr.repository_url}:${var.ecr_image_tag}"
  network_mode          = var.network_mode
  environment_variables = var.agent_environment_variables

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "slack_integration" {
  source = "../../modules/slack_integration"

  project_name        = var.project_name
  environment         = var.environment
  agent_runtime_arn   = module.agent_runtime.agent_runtime_arn
  agent_qualifier     = module.agent_runtime.endpoint_name
  receiver_source_dir = "${path.module}/../../../slack_bot/receiver"
  invoker_source_dir  = "${path.module}/../../../slack_bot/invoker"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
