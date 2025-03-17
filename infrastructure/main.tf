provider "aws" {
  region = "us-east-1" # Change as needed
}

data "aws_caller_identity" "current" {}
locals {
    account_id = data.aws_caller_identity.current.account_id
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_security_group" "ecs_sg" {
  vpc_id = aws_vpc.main.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "main" {
  name = "my-cluster"
}

# Define the IAM policy for ECS task execution role
resource "aws_iam_policy" "ecs_task_execution_policy" {
  name        = "ecs-task-execution-policy"
  description = "Policy to allow ECS tasks to pull images from GHCR"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "secretsmanager:GetSecretValue",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_task_execution_policy.arn
}

resource "aws_ecs_task_definition" "app" {
  family                   = "my-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  memory                   = "512"
  cpu                      = "256"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "my-app"
      image = "ghcr.io/sioop/spring-boot-react-ci-cd-aws-tf:latest"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
      repositoryCredentials = {
        credentialsParameter = "arn:aws:secretsmanager:us-east-1:${local.account_id}:secret:ghcr-credentials"
      }
    }
  ])
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_ecs_service" "app" {
  name            = "my-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name = "/ecs/my-app"
}

# Auto Scaling for ECS Service
resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scaling policy for scaling out based on CPU utilization
resource "aws_appautoscaling_policy" "scale_up" {
  name                   = "scale-up-policy"
  resource_id               = aws_appautoscaling_target.ecs_target.resource_id
  service_namespace = aws_appautoscaling_target.ecs_target.service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  policy_type             = "StepScaling"
  
  # Autoscaling to target 70% CPU utilization
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
    step_adjustment {
      metric_interval_upper_bound = 70
      scaling_adjustment          = 1
    }
  }
}

# Scaling policy for scaling in based on CPU utilization
resource "aws_appautoscaling_policy" "scale_down" {
  name                   = "scale-down-policy"
  resource_id               = aws_appautoscaling_target.ecs_target.resource_id
  service_namespace = aws_appautoscaling_target.ecs_target.service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  policy_type             = "StepScaling"
  
  # Autoscaling to target 30% CPU utilization
  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
    step_adjustment {
      metric_interval_lower_bound = 30
      scaling_adjustment          = -1
    }
  }
}

# Bucket for storing CloudTrail logs
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket_prefix = "cloudtrail-logs"
}

# CloudTrail for logging API calls
resource "aws_cloudtrail" "cloudtrail" {
  name                          = "my-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.bucket
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  # Filter CloudTrail logs to only include API calls relevant to this infrastructure
  event_selector {
    read_write_type = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Bucket"
      values = ["arn:aws:s3:::${aws_s3_bucket.cloudtrail_logs.bucket}"]
    }
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::${aws_s3_bucket.cloudtrail_logs.bucket}/*"]
    }
    data_resource {
      type   = "AWS::IAM::Role"
      values = ["arn:aws:iam::${local.account_id}:role/ecsTaskExecutionRole"]
    }
    data_resource {
      type   = "AWS::IAM::Policy"
      values = ["arn:aws:iam::${local.account_id}:policy/ecs-task-execution-policy"]
    }
    data_resource {
      type   = "AWS::ECS::Cluster"
      values = ["arn:aws:ecs:${local.account_id}:cluster/my-cluster"]
    }
    data_resource {
      type   = "AWS::ECS::Service"
      values = ["arn:aws:ecs:${local.account_id}:service/my-app-service"]
    }
    data_resource {
      type   = "AWS::ECS::TaskDefinition"
      values = ["arn:aws:ecs:${local.account_id}:task-definition/my-app"]
    }
    data_resource {
      type   = "AWS::ECS::TaskSet"
      values = ["arn:aws:ecs:${local.account_id}:task-set/my-app"]
    }
  }
}