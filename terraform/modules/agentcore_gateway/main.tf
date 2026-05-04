locals {
  name_prefix = "${var.project_name}-${var.environment}"
  # Cognito user pool domain prefix must be globally unique; suffix with account id.
  cognito_domain     = "${local.name_prefix}-gw-${substr(data.aws_caller_identity.current.account_id, 0, 8)}"
  resource_server_id = "${var.project_name}-gateway"
  scope_name         = "invoke"
  full_scope         = "${local.resource_server_id}/${local.scope_name}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

################################################################################
# Cognito (M2M for Gateway inbound auth)
################################################################################

resource "aws_cognito_user_pool" "this" {
  name = "${local.name_prefix}-gateway"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  tags = var.tags
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = local.cognito_domain
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_resource_server" "this" {
  user_pool_id = aws_cognito_user_pool.this.id
  identifier   = local.resource_server_id
  name         = local.resource_server_id

  scope {
    scope_name        = local.scope_name
    scope_description = "Invoke ${local.name_prefix} AgentCore Gateway"
  }
}

resource "aws_cognito_user_pool_client" "m2m" {
  name                                 = "${local.name_prefix}-gateway-runtime"
  user_pool_id                         = aws_cognito_user_pool.this.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [local.full_scope]
  supported_identity_providers         = ["COGNITO"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true

  access_token_validity = 1
  token_validity_units {
    access_token = "hours"
  }

  depends_on = [aws_cognito_resource_server.this]
}

################################################################################
# Secrets Manager
################################################################################

resource "aws_secretsmanager_secret" "gateway_client" {
  name        = "/${var.project_name}/${var.environment}/agentcore-gateway-client"
  description = "Cognito M2M client credentials and token endpoint for AgentCore Gateway"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "gateway_client" {
  secret_id = aws_secretsmanager_secret.gateway_client.id
  secret_string = jsonencode({
    client_id      = aws_cognito_user_pool_client.m2m.id
    client_secret  = aws_cognito_user_pool_client.m2m.client_secret
    token_endpoint = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/token"
    scope          = local.full_scope
  })
}

resource "aws_secretsmanager_secret" "tavily" {
  name        = "/${var.project_name}/${var.environment}/tavily"
  description = "Tavily API key for web_search Lambda"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "tavily_placeholder" {
  secret_id     = aws_secretsmanager_secret.tavily.id
  secret_string = jsonencode({ api_key = "PLACEHOLDER" })

  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}

################################################################################
# Search Lambda
################################################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "search" {
  name               = "${local.name_prefix}-search-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "search" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.tavily.arn]
  }
}

resource "aws_iam_role_policy" "search" {
  name   = "${local.name_prefix}-search-lambda"
  role   = aws_iam_role.search.id
  policy = data.aws_iam_policy_document.search.json
}

resource "aws_cloudwatch_log_group" "search" {
  name              = "/aws/lambda/${local.name_prefix}-search"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "archive_file" "search" {
  type        = "zip"
  source_dir  = var.search_source_dir
  output_path = "${path.module}/build/search.zip"
}

resource "aws_lambda_function" "search" {
  function_name    = "${local.name_prefix}-search"
  role             = aws_iam_role.search.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.search.output_path
  source_code_hash = data.archive_file.search.output_base64sha256
  timeout          = var.search_lambda_timeout_seconds
  memory_size      = var.search_lambda_memory_mb

  environment {
    variables = {
      TAVILY_SECRET_NAME = aws_secretsmanager_secret.tavily.name
      LOG_LEVEL          = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.search]
  tags       = var.tags
}

################################################################################
# Gateway IAM (assumed by bedrock-agentcore service)
################################################################################

data "aws_iam_policy_document" "gateway_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${local.name_prefix}-gateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "gateway" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.search.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "${local.name_prefix}-gateway"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

################################################################################
# AgentCore Gateway + Lambda Target
################################################################################

resource "aws_bedrockagentcore_gateway" "this" {
  name            = "${local.name_prefix}-gateway"
  description     = "MCP Gateway exposing tools for ${local.name_prefix} agent"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  protocol_configuration {
    mcp {
      supported_versions = ["2025-11-25"]
      instructions       = "Tools for web search and related lookups."
    }
  }

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}/.well-known/openid-configuration"
      allowed_clients = [aws_cognito_user_pool_client.m2m.id]
    }
  }

  tags = var.tags
}

resource "aws_lambda_permission" "gateway_invoke" {
  statement_id  = "AllowGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.search.function_name
  principal     = "bedrock-agentcore.amazonaws.com"
  source_arn    = aws_bedrockagentcore_gateway.this.gateway_arn
}

resource "aws_bedrockagentcore_gateway_target" "tavily" {
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = "tavily"
  description        = "Tavily-backed web search tools"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.search.arn

        tool_schema {
          inline_payload {
            name        = "web_search"
            description = "Search the web via Tavily and return ranked results."

            input_schema {
              type = "object"

              property {
                name        = "query"
                type        = "string"
                required    = true
                description = "Search query string."
              }
              property {
                name        = "max_results"
                type        = "integer"
                required    = false
                description = "Maximum number of results to return (1-20, default 5)."
              }
              property {
                name        = "search_depth"
                type        = "string"
                required    = false
                description = "Search depth: 'basic' (fast) or 'advanced' (more thorough)."
              }
            }

            output_schema {
              type = "object"

              property {
                name        = "results"
                type        = "array"
                required    = false
                description = "Ranked list of web search results."

                items {
                  type = "object"

                  property {
                    name        = "title"
                    type        = "string"
                    required    = false
                    description = "Page title."
                  }
                  property {
                    name        = "url"
                    type        = "string"
                    required    = false
                    description = "Page URL."
                  }
                  property {
                    name        = "content"
                    type        = "string"
                    required    = false
                    description = "Snippet of the page content most relevant to the query."
                  }
                  property {
                    name        = "score"
                    type        = "number"
                    required    = false
                    description = "Tavily relevance score (0.0-1.0)."
                  }
                }
              }
            }
          }

          inline_payload {
            name        = "web_extract"
            description = "Extract the main text content from one or more URLs via Tavily."

            input_schema {
              type = "object"

              property {
                name        = "urls"
                type        = "array"
                required    = true
                description = "List of URLs to fetch and extract content from."

                items {
                  type = "string"
                }
              }
              property {
                name        = "extract_depth"
                type        = "string"
                required    = false
                description = "Extraction depth: 'basic' (fast) or 'advanced' (more thorough, slower)."
              }
            }

            output_schema {
              type = "object"

              property {
                name        = "results"
                type        = "array"
                required    = false
                description = "Successfully extracted pages."

                items {
                  type = "object"

                  property {
                    name        = "url"
                    type        = "string"
                    required    = false
                    description = "Page URL."
                  }
                  property {
                    name        = "raw_content"
                    type        = "string"
                    required    = false
                    description = "Extracted main text of the page."
                  }
                }
              }
              property {
                name        = "failed_results"
                type        = "array"
                required    = false
                description = "URLs that could not be extracted."

                items {
                  type = "object"

                  property {
                    name        = "url"
                    type        = "string"
                    required    = false
                    description = "URL that failed."
                  }
                  property {
                    name        = "error"
                    type        = "string"
                    required    = false
                    description = "Failure reason from Tavily."
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [aws_lambda_permission.gateway_invoke]
}

################################################################################
# Gateway log delivery to CloudWatch
################################################################################

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/${aws_bedrockagentcore_gateway.this.gateway_id}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_delivery_source" "gateway" {
  name         = "${local.name_prefix}-gateway-app-logs"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_gateway.this.gateway_arn
  tags         = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "gateway" {
  name = "${local.name_prefix}-gateway-app-logs"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.gateway.arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery" "gateway" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.gateway.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.gateway.arn

  tags = var.tags
}
