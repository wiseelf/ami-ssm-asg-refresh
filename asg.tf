resource "aws_iam_role" "asg_instance" {
  name = "${var.name}-asg-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "asg_ssm" {
  role       = aws_iam_role.asg_instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "asg" {
  name = "${var.name}-asg"
  role = aws_iam_role.asg_instance.name
}

resource "aws_launch_template" "asg" {
  name_prefix   = "${var.name}-"
  description   = "ASG template resolving its AMI directly from Parameter Store"
  image_id      = "resolve:ssm:${aws_ssm_parameter.ami.name}"
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.asg.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    device_index                = 0
    security_groups             = [aws_security_group.instances.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      encrypted             = true
      volume_size           = 8
      volume_type           = "gp3"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.name}-asg" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.name}-asg" })
  }

  user_data = base64encode(<<-USER_DATA
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent
  USER_DATA
  )

  update_default_version = true

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "lab" {
  name                = var.name
  min_size            = var.desired_capacity
  desired_capacity    = var.desired_capacity
  max_size            = ceil(var.desired_capacity * 1.5)
  vpc_zone_identifier = [aws_subnet.public.id]

  health_check_type         = "EC2"
  health_check_grace_period = var.instance_warmup
  default_cooldown          = 30
  termination_policies      = ["OldestInstance"]

  launch_template {
    id      = aws_launch_template.asg.id
    version = "$Default"
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.name
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [time_sleep.parameter_validation]
}
