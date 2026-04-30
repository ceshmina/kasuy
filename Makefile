.PHONY: login-staging login-production \
       init-staging init-production \
       plan-staging plan-production \
       apply-staging apply-production \
       agent-serve-local \
       agent-invoke-local agent-invoke-staging agent-invoke-production \
       agent-push-staging agent-push-production \
       test-slack-bot

# ==============================================================================
# Agent Serve (local)
# ==============================================================================

agent-serve-local:
	cd agent && AWS_PROFILE=apkas-staging.admin uv run main.py

# ==============================================================================
# Agent Invoke
# ==============================================================================

agent-invoke-local:
	cd agent && uv run python invoke.py local "$(or $(PROMPT),Hello)"

agent-invoke-staging:
	$(eval ARN := $(shell cd terraform/env/staging && AWS_PROFILE=apkas-staging.admin terraform output -raw agent_runtime_arn))
	$(eval QUALIFIER := $(shell cd terraform/env/staging && AWS_PROFILE=apkas-staging.admin terraform output -raw endpoint_name))
	cd agent && AWS_PROFILE=apkas-staging.admin AGENT_RUNTIME_ARN=$(ARN) AGENT_QUALIFIER=$(QUALIFIER) uv run python invoke.py staging "$(or $(PROMPT),Hello)"

agent-invoke-production:
	$(eval ARN := $(shell cd terraform/env/production && AWS_PROFILE=apkas-production.admin terraform output -raw agent_runtime_arn))
	$(eval QUALIFIER := $(shell cd terraform/env/production && AWS_PROFILE=apkas-production.admin terraform output -raw endpoint_name))
	cd agent && AWS_PROFILE=apkas-production.admin AGENT_RUNTIME_ARN=$(ARN) AGENT_QUALIFIER=$(QUALIFIER) uv run python invoke.py production "$(or $(PROMPT),Hello)"

# ==============================================================================
# Agent ECR Push
# ==============================================================================

AWS_REGION ?= ap-northeast-1
ECR_REPOSITORY = kasuy-agent
TAG ?= latest

agent-push-staging:
	$(eval ACCOUNT_ID := $(shell AWS_PROFILE=apkas-staging.admin aws sts get-caller-identity --query Account --output text))
	$(eval REGISTRY := $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com)
	AWS_PROFILE=apkas-staging.admin aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(REGISTRY)
	cd agent && docker buildx build --platform linux/arm64 -t $(REGISTRY)/$(ECR_REPOSITORY):$(TAG) --push .

agent-push-production:
	$(eval ACCOUNT_ID := $(shell AWS_PROFILE=apkas-production.admin aws sts get-caller-identity --query Account --output text))
	$(eval REGISTRY := $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com)
	AWS_PROFILE=apkas-production.admin aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(REGISTRY)
	cd agent && docker buildx build --platform linux/arm64 -t $(REGISTRY)/$(ECR_REPOSITORY):$(TAG) --push .

# ==============================================================================
# Slack Bot Tests
# ==============================================================================

test-slack-bot:
	cd slack_bot/tests && python3 -m unittest discover

# ==============================================================================
# AWS SSO Login
# ==============================================================================

login-staging:
	aws sso login --profile apkas-staging.admin

login-production:
	aws sso login --profile apkas-production.admin

# ==============================================================================
# Terraform - Staging
# ==============================================================================

# GODEBUG=http2client=0: Workaround for HTTP/2 PROTOCOL_ERROR when downloading large providers
init-staging:
	cd terraform/env/staging && GODEBUG=http2client=0 AWS_PROFILE=apkas-staging.admin terraform init -backend-config=backend.hcl

plan-staging:
	cd terraform/env/staging && AWS_PROFILE=apkas-staging.admin terraform plan

apply-staging:
	cd terraform/env/staging && AWS_PROFILE=apkas-staging.admin terraform apply

# ==============================================================================
# Terraform - Production
# ==============================================================================

init-production:
	cd terraform/env/production && GODEBUG=http2client=0 AWS_PROFILE=apkas-production.admin terraform init -backend-config=backend.hcl

plan-production:
	cd terraform/env/production && AWS_PROFILE=apkas-production.admin terraform plan

apply-production:
	cd terraform/env/production && AWS_PROFILE=apkas-production.admin terraform apply
