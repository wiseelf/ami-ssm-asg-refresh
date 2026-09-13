resource "aws_cloudwatch_log_group" "imagebuilder_image" {
  name              = "/aws/imagebuilder/${var.name}/image"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_cloudwatch_log_group" "imagebuilder_pipeline" {
  name              = "/aws/imagebuilder/${var.name}/pipeline"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_imagebuilder_component" "build" {
  name        = "${var.name}-build"
  description = "Write the release marker used to identify the built AMI"
  platform    = "Linux"
  version     = var.recipe_version
  data        = file("${path.module}/components/build.yml")
}

resource "aws_imagebuilder_component" "test" {
  name        = "${var.name}-test"
  description = "Verify Amazon Linux and the release marker; supports deliberate failure"
  platform    = "Linux"
  version     = var.recipe_version
  data        = file("${path.module}/components/test.yml")
}

resource "aws_imagebuilder_image_recipe" "lab" {
  name         = var.name
  version      = var.recipe_version
  parent_image = data.aws_ssm_parameter.amazon_linux_2023.value

  component {
    component_arn = aws_imagebuilder_component.build.arn

    parameter {
      name  = "ReleaseId"
      value = var.release_id
    }
  }

  component {
    component_arn = aws_imagebuilder_component.test.arn

    parameter {
      name  = "ExpectedReleaseId"
      value = var.release_id
    }

    parameter {
      name  = "ForceFailure"
      value = tostring(var.force_test_failure)
    }
  }

  block_device_mapping {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      encrypted             = true
      volume_size           = 8
      volume_type           = "gp3"
    }
  }

  systems_manager_agent {
    uninstall_after_build = false
  }

  ami_tags = {
    Project = var.name
    Release = var.release_id
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "lab" {
  name                          = var.name
  description                   = "Build and test infrastructure for ${var.name}"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder.name
  instance_types                = [var.instance_type]
  security_group_ids            = [aws_security_group.instances.id]
  subnet_id                     = aws_subnet.public.id
  terminate_instance_on_failure = true

  instance_metadata_options {
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
  }

  resource_tags = merge(local.common_tags, {
    Name = "${var.name}-imagebuilder"
  })
}

resource "aws_imagebuilder_distribution_configuration" "lab" {
  name        = var.name
  description = "Publish the tested AMI and update ${local.parameter_name}"

  distribution {
    region = var.aws_region

    ami_distribution_configuration {
      name        = "${var.name}-${var.release_id}-{{ imagebuilder:buildDate }}"
      description = "${var.name} ${var.release_id} built by EC2 Image Builder"
      ami_tags = {
        Project = var.name
        Release = var.release_id
      }
    }

    ssm_parameter_configuration {
      data_type      = "aws:ec2:image"
      parameter_name = aws_ssm_parameter.ami.name
    }
  }
}

resource "aws_imagebuilder_image_pipeline" "lab" {
  name                             = var.name
  description                      = "Manual Image Builder pipeline for the Parameter Store ASG refresh lab"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.lab.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.lab.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.lab.arn
  execution_role                   = aws_iam_role.imagebuilder_execution.arn
  enhanced_image_metadata_enabled  = true
  status                           = "ENABLED"

  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60
  }

  logging_configuration {
    image_log_group_name    = aws_cloudwatch_log_group.imagebuilder_image.name
    pipeline_log_group_name = aws_cloudwatch_log_group.imagebuilder_pipeline.name
  }

  lifecycle {
    replace_triggered_by = [aws_imagebuilder_image_recipe.lab]
  }

  depends_on = [
    aws_iam_role_policy_attachment.imagebuilder_execution,
    aws_iam_role_policy.imagebuilder_publish,
  ]
}
