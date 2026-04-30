locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

################################################################################
# Secrets Manager (Slack credentials)
################################################################################

resource "aws_secretsmanager_secret" "slack" {
  name        = "/${var.project_name}/${var.environment}/slack"
  description = "Slack bot_token, signing_secret, bot_user_id"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "slack_placeholder" {
  secret_id = aws_secretsmanager_secret.slack.id
  secret_string = jsonencode({
    bot_token      = "PLACEHOLDER"
    signing_secret = "PLACEHOLDER"
    bot_user_id    = "PLACEHOLDER"
  })

  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}

################################################################################
# DynamoDB (event_id dedup)
################################################################################

resource "aws_dynamodb_table" "dedup" {
  name         = "${local.name_prefix}-slack-dedup"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = var.tags
}

################################################################################
# SQS FIFO + DLQ
################################################################################

resource "aws_sqs_queue" "agent_jobs_dlq" {
  name                      = "${local.name_prefix}-slack-jobs-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = 1209600 # 14 days
  tags                      = var.tags
}

resource "aws_sqs_queue" "agent_jobs" {
  name                        = "${local.name_prefix}-slack-jobs.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  visibility_timeout_seconds  = var.invoker_timeout_seconds * 6
  message_retention_seconds   = 14400 # 4 hours

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.agent_jobs_dlq.arn
    maxReceiveCount     = 2
  })

  tags = var.tags
}

################################################################################
# IAM
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

resource "aws_iam_role" "receiver" {
  name               = "${local.name_prefix}-slack-receiver"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "receiver" {
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
    resources = [aws_secretsmanager_secret.slack.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.dedup.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.agent_jobs.arn]
  }
}

resource "aws_iam_role_policy" "receiver" {
  name   = "${local.name_prefix}-slack-receiver"
  role   = aws_iam_role.receiver.id
  policy = data.aws_iam_policy_document.receiver.json
}

resource "aws_iam_role" "invoker" {
  name               = "${local.name_prefix}-slack-invoker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "invoker" {
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
    resources = [aws_secretsmanager_secret.slack.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.agent_jobs.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["bedrock-agentcore:InvokeAgentRuntime"]
    resources = ["${var.agent_runtime_arn}*"]
  }
}

resource "aws_iam_role_policy" "invoker" {
  name   = "${local.name_prefix}-slack-invoker"
  role   = aws_iam_role.invoker.id
  policy = data.aws_iam_policy_document.invoker.json
}

################################################################################
# Lambda packages
################################################################################

data "archive_file" "receiver" {
  type        = "zip"
  source_dir  = var.receiver_source_dir
  output_path = "${path.module}/build/receiver.zip"
}

data "archive_file" "invoker" {
  type        = "zip"
  source_dir  = var.invoker_source_dir
  output_path = "${path.module}/build/invoker.zip"
}

################################################################################
# Lambda functions
################################################################################

resource "aws_cloudwatch_log_group" "receiver" {
  name              = "/aws/lambda/${local.name_prefix}-slack-receiver"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "invoker" {
  name              = "/aws/lambda/${local.name_prefix}-slack-invoker"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "receiver" {
  function_name    = "${local.name_prefix}-slack-receiver"
  role             = aws_iam_role.receiver.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256
  timeout          = var.receiver_timeout_seconds
  memory_size      = var.receiver_memory_mb

  environment {
    variables = {
      SLACK_SECRET_NAME = aws_secretsmanager_secret.slack.name
      DEDUP_TABLE       = aws_dynamodb_table.dedup.name
      JOB_QUEUE_URL     = aws_sqs_queue.agent_jobs.url
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.receiver]
  tags       = var.tags
}

resource "aws_lambda_function" "invoker" {
  function_name    = "${local.name_prefix}-slack-invoker"
  role             = aws_iam_role.invoker.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.invoker.output_path
  source_code_hash = data.archive_file.invoker.output_base64sha256
  timeout          = var.invoker_timeout_seconds
  memory_size      = var.invoker_memory_mb

  environment {
    variables = {
      SLACK_SECRET_NAME = aws_secretsmanager_secret.slack.name
      AGENT_RUNTIME_ARN = var.agent_runtime_arn
      AGENT_QUALIFIER   = var.agent_qualifier
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.invoker]
  tags       = var.tags
}

resource "aws_lambda_event_source_mapping" "invoker_sqs" {
  event_source_arn                   = aws_sqs_queue.agent_jobs.arn
  function_name                      = aws_lambda_function.invoker.arn
  batch_size                         = 1
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
}

################################################################################
# API Gateway (HTTP API)
################################################################################

resource "aws_apigatewayv2_api" "slack" {
  name          = "${local.name_prefix}-slack"
  protocol_type = "HTTP"
  tags          = var.tags
}

resource "aws_apigatewayv2_integration" "receiver" {
  api_id                 = aws_apigatewayv2_api.slack.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.receiver.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack_events" {
  api_id    = aws_apigatewayv2_api.slack.id
  route_key = "POST /slack/events"
  target    = "integrations/${aws_apigatewayv2_integration.receiver.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.slack.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }

  tags = var.tags
}

resource "aws_lambda_permission" "apigw_invoke_receiver" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.receiver.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack.execution_arn}/*/*"
}
