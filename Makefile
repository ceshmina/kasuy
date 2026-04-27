.PHONY: login-staging login-production \
       init-staging init-production \
       plan-staging plan-production \
       apply-staging apply-production \
       agent-local agent-test

# ==============================================================================
# Agent Local
# ==============================================================================

agent-local:
	cd agent && AWS_PROFILE=apkas-staging.admin uv run main.py

agent-test:
	python3 agent/test_local.py "$(or $(PROMPT),Hello)"

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
