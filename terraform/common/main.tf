module "ecr" {
  source = "../../modules/ecr"

  repository_name = "${var.project_name}-agent"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "agentcore_gateway" {
  source = "../../modules/agentcore_gateway"

  project_name      = var.project_name
  environment       = var.environment
  search_source_dir = "${path.module}/../../../search_lambda"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "agentcore_memory" {
  source = "../../modules/agentcore_memory"

  project_name = var.project_name
  environment  = var.environment

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "agent_runtime" {
  source = "../../modules/agentcore_runtime"

  agent_runtime_name = var.agent_runtime_name
  description        = var.agent_description
  environment        = var.environment
  ecr_image_uri      = "${module.ecr.repository_url}:${var.ecr_image_tag}"
  network_mode       = var.network_mode
  environment_variables = merge(var.agent_environment_variables, {
    GATEWAY_URL                = module.agentcore_gateway.gateway_url
    GATEWAY_CLIENT_SECRET_NAME = module.agentcore_gateway.client_secret_name
    AGENT_MEMORY_ID            = module.agentcore_memory.memory_id
  })
  additional_secret_arns = [module.agentcore_gateway.client_secret_arn]
  memory_arn             = module.agentcore_memory.memory_arn

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
