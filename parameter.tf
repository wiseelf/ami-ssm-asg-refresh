data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_ssm_parameter" "ami" {
  name        = local.parameter_name
  description = "Current AMI for the ${var.name} Auto Scaling group"
  type        = "String"
  data_type   = "aws:ec2:image"
  tier        = "Standard"
  value       = data.aws_ssm_parameter.amazon_linux_2023.value

  lifecycle {
    ignore_changes = [value]
  }
}

# Validation of aws:ec2:image values is asynchronous. Give Parameter Store time
# to finish validating the bootstrap AMI before Auto Scaling resolves the alias.
resource "time_sleep" "parameter_validation" {
  create_duration = "30s"
  depends_on      = [aws_ssm_parameter.ami]
}
