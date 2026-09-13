resource "aws_iam_role" "imagebuilder_instance" {
  name = "${var.name}-imagebuilder-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "imagebuilder_instance" {
  role       = aws_iam_role.imagebuilder_instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "imagebuilder_instance_ssm" {
  role       = aws_iam_role.imagebuilder_instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "imagebuilder" {
  name = "${var.name}-imagebuilder"
  role = aws_iam_role.imagebuilder_instance.name
}

resource "aws_iam_role" "imagebuilder_execution" {
  name = "${var.name}-imagebuilder-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "imagebuilder.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:imagebuilder:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "imagebuilder_execution" {
  role       = aws_iam_role.imagebuilder_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/EC2ImageBuilderExecutionPolicy"
}

resource "aws_iam_role_policy" "imagebuilder_publish" {
  name = "publish-lab-ami-parameter"
  role = aws_iam_role.imagebuilder_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishAmiParameter"
        Effect   = "Allow"
        Action   = "ssm:PutParameter"
        Resource = aws_ssm_parameter.ami.arn
      },
      {
        Sid      = "ValidatePublishedAmi"
        Effect   = "Allow"
        Action   = "ec2:DescribeImages"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "reconcile-parameter-with-asg"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadExactParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = aws_ssm_parameter.ami.arn
      },
      {
        Sid    = "InspectLabState"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeInstanceRefreshes",
          "ec2:DescribeImages",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Sid      = "StartRefreshForLabGroup"
        Effect   = "Allow"
        Action   = "autoscaling:StartInstanceRefresh"
        Resource = aws_autoscaling_group.lab.arn
      },
      {
        Sid    = "ValidateLaunchPermission"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:RunInstances"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassLabInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.asg_instance.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid    = "WriteFunctionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid      = "PublishFailedInvocation"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.lambda_failure.arn
      }
    ]
  })
}
