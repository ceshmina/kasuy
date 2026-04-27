environment        = "production"
aws_region         = "ap-northeast-1"
agent_runtime_name = "kasuy-qa-agent"
agent_description  = "Q&A agent (production)"
ecr_image_tag      = "latest"
network_mode       = "PUBLIC"

agent_environment_variables = {
  LOG_LEVEL = "WARNING"
  ENV       = "production"
}
