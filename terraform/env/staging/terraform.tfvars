environment        = "staging"
aws_region         = "ap-northeast-1"
agent_runtime_name = "kasuy_agent"
agent_description  = "Q&A agent (staging)"
ecr_image_tag      = "3558a0e"
network_mode       = "PUBLIC"

agent_environment_variables = {
  LOG_LEVEL = "DEBUG"
  ENV       = "staging"
}
