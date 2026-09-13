variable "aws_region" {
  description = "AWS Region in which to create the lab."
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_profile" {
  description = "Optional local AWS CLI profile. Leave null to use the standard AWS credential chain."
  type        = string
  default     = null
  nullable    = true
}

variable "name" {
  description = "Short name used to identify and tag every lab resource."
  type        = string
  default     = "ami-ssm-asg-refresh"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.name))
    error_message = "name must be 3-32 lowercase letters, numbers, or hyphens, starting with a letter."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated lab VPC."
  type        = string
  default     = "10.42.0.0/24"
}

variable "public_subnet_cidr" {
  description = "CIDR for the lab's single public subnet."
  type        = string
  default     = "10.42.0.0/26"
}

variable "instance_type" {
  description = "Small x86 instance type for ASG, build, and test instances."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t2.micro", "t3.micro", "t3.small"], var.instance_type)
    error_message = "instance_type must be one of the supported small x86 types: t2.micro, t3.micro, or t3.small."
  }
}

variable "desired_capacity" {
  description = "Desired and minimum number of instances in the test ASG."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_capacity >= 2
    error_message = "desired_capacity must be at least 2 for a meaningful rolling-refresh lab."
  }
}

variable "recipe_version" {
  description = "Semantic version for the Image Builder components and recipe. Increment for each changed build."
  type        = string
  default     = "1.0.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.recipe_version))
    error_message = "recipe_version must be a numeric semantic version such as 1.0.0."
  }
}

variable "release_id" {
  description = "Marker written into /etc/asg-refresh-lab-release by the image build."
  type        = string
  default     = "v1"
}

variable "force_test_failure" {
  description = "Set true only for the negative test; the Image Builder test phase will fail before distribution."
  type        = bool
  default     = false
}

variable "instance_warmup" {
  description = "Seconds Auto Scaling waits before considering each replacement warmed up."
  type        = number
  default     = 120
}

variable "lambda_log_retention_days" {
  description = "Retention for Lambda and Image Builder CloudWatch log groups."
  type        = number
  default     = 14
}
