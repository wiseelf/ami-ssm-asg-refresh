data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/rollout.py"
  output_path = "${path.module}/lambda/rollout.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_sqs_queue" "event_delivery_failure" {
  name                      = "${var.name}-event-delivery-failure"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "lambda_failure" {
  name                      = "${var.name}-lambda-failure"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_lambda_function" "reconcile" {
  function_name = var.name
  description   = "Start an ASG refresh when Image Builder publishes an AMI parameter"
  role          = aws_iam_role.lambda.arn
  handler       = "rollout.lambda_handler"
  runtime       = "python3.13"
  architectures = ["x86_64"]

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  memory_size                    = 128
  timeout                        = 60
  reserved_concurrent_executions = 1

  environment {
    variables = {
      PARAMETER_NAME         = aws_ssm_parameter.ami.name
      ASG_NAME               = aws_autoscaling_group.lab.name
      EXPECTED_ACCOUNT_ID    = data.aws_caller_identity.current.account_id
      EXPECTED_REGION        = var.aws_region
      AMI_OWNER_ID           = data.aws_caller_identity.current.account_id
      REQUIRED_AMI_TAG_KEY   = "Project"
      REQUIRED_AMI_TAG_VALUE = var.name
      MIN_HEALTHY_PERCENTAGE = "100"
      MAX_HEALTHY_PERCENTAGE = "150"
      INSTANCE_WARMUP        = tostring(var.instance_warmup)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

resource "aws_lambda_function_event_invoke_config" "reconcile" {
  function_name          = aws_lambda_function.reconcile.function_name
  maximum_retry_attempts = 2

  destination_config {
    on_failure {
      destination = aws_sqs_queue.lambda_failure.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "parameter_update" {
  name        = "${var.name}-parameter-update"
  description = "Invoke reconciliation only when Image Builder updates the lab AMI parameter"

  event_pattern = jsonencode({
    source      = ["aws.ssm"]
    detail-type = ["Parameter Store Change"]
    account     = [data.aws_caller_identity.current.account_id]
    region      = [var.aws_region]
    detail = {
      name      = [aws_ssm_parameter.ami.name]
      operation = ["Update"]
    }
  })
}

resource "aws_sqs_queue_policy" "event_delivery_failure" {
  queue_url = aws_sqs_queue.event_delivery_failure.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeDeliveryFailures"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.event_delivery_failure.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.parameter_update.arn
        }
      }
    }]
  })
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeParameterUpdate"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reconcile.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.parameter_update.arn
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.parameter_update.name
  arn  = aws_lambda_function.reconcile.arn

  dead_letter_config {
    arn = aws_sqs_queue.event_delivery_failure.arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }

  depends_on = [
    aws_lambda_permission.eventbridge,
    aws_sqs_queue_policy.event_delivery_failure,
  ]
}
