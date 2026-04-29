output "slack_request_url" {
  description = "URL to register in Slack App Event Subscriptions Request URL"
  value       = "${aws_apigatewayv2_api.slack.api_endpoint}/slack/events"
}

output "slack_secret_name" {
  description = "Name of the Secrets Manager secret holding Slack credentials"
  value       = aws_secretsmanager_secret.slack.name
}

output "slack_secret_arn" {
  description = "ARN of the Secrets Manager secret holding Slack credentials"
  value       = aws_secretsmanager_secret.slack.arn
}

output "receiver_function_name" {
  description = "Name of the receiver Lambda function"
  value       = aws_lambda_function.receiver.function_name
}

output "invoker_function_name" {
  description = "Name of the invoker Lambda function"
  value       = aws_lambda_function.invoker.function_name
}

output "job_queue_url" {
  description = "URL of the SQS FIFO queue for agent invocation jobs"
  value       = aws_sqs_queue.agent_jobs.url
}

output "dedup_table_name" {
  description = "Name of the DynamoDB dedup table"
  value       = aws_dynamodb_table.dedup.name
}
