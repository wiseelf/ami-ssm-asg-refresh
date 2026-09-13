output "ami_parameter_name" {
  description = "Parameter updated by Image Builder and resolved by the launch template."
  value       = aws_ssm_parameter.ami.name
}

output "aws_region" {
  description = "AWS Region containing the lab."
  value       = var.aws_region
}

output "project_name" {
  description = "Tag value used to scope inspection and cleanup."
  value       = var.name
}

output "event_rule_name" {
  value = aws_cloudwatch_event_rule.parameter_update.name
}

output "asg_name" {
  description = "Auto Scaling group refreshed by Lambda."
  value       = aws_autoscaling_group.lab.name
}

output "image_pipeline_arn" {
  description = "ARN to pass to start-image-pipeline-execution."
  value       = aws_imagebuilder_image_pipeline.lab.arn
}

output "lambda_function_name" {
  description = "Function to invoke with {\"mode\":\"reconcile\"} for manual reconciliation."
  value       = aws_lambda_function.reconcile.function_name
}

output "event_delivery_failure_queue_url" {
  value = aws_sqs_queue.event_delivery_failure.id
}

output "lambda_failure_queue_url" {
  value = aws_sqs_queue.lambda_failure.id
}

output "seed_ami_id" {
  description = "Concrete Amazon Linux 2023 AMI used to bootstrap the parameter and Image Builder recipe."
  value       = nonsensitive(data.aws_ssm_parameter.amazon_linux_2023.value)
}
