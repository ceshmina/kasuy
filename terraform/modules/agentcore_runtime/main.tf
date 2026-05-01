################################################################################
# IAM Role
################################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runtime_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]
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

  dynamic "statement" {
    for_each = length(var.additional_secret_arns) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.additional_secret_arns
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.agent_runtime_name}_${var.environment}_role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.agent_runtime_name}_${var.environment}_policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.runtime_permissions.json
}

################################################################################
# AgentCore Runtime
################################################################################

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = "${var.agent_runtime_name}_${var.environment}"
  description        = var.description
  role_arn           = aws_iam_role.this.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = var.ecr_image_uri
    }
  }

  network_configuration {
    network_mode = var.network_mode
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  environment_variables = var.environment_variables

  tags = var.tags
}

################################################################################
# Runtime Endpoint
################################################################################

resource "aws_bedrockagentcore_agent_runtime_endpoint" "this" {
  name             = "${var.agent_runtime_name}_${var.environment}_endpoint"
  agent_runtime_id = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
  description      = "Endpoint for ${var.agent_runtime_name} (${var.environment})"

  tags = var.tags
}
