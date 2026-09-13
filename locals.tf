locals {
  parameter_name = "/imagebuilder/${var.name}/ami"

  common_tags = {
    Project   = var.name
    ManagedBy = "Terraform"
    Purpose   = "Parameter-Store-ASG-refresh-lab"
  }
}
