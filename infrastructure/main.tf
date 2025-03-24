provider "aws" {
  region = local.region
  default_tags {
    tags = {
      Environment = local.environment
      Project     = "payroll"
    }
  }
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  environment = "dev"
  port        = 80
  region      = "eu-west-1"
  github_secret_arn = "arn:aws:secretsmanager:eu-west-1:${local.account_id}:secret:github-container-registry-5b4R0V"
  container_image = "ghcr.io/sioop/spring-boot-react-ci-cd-aws-tf:latest"
}

resource "aws_lb_target_group" "app" {
  name        = "payroll-tg-${local.environment}"
  port        = local.port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    interval            = 60
    path                = "/"
    protocol            = "HTTP"
    timeout             = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "400-499"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_service" "app" {
  name            = "payroll-service-${local.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id, aws_subnet.public_az2.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "spring-boot-react-ci-cd-aws-tf"
    container_port   = local.port
  }

  depends_on = [aws_lb_listener.http]
}

data "aws_caller_identity" "current" {}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true
}

resource "aws_lb" "app" {
  name               = "payroll-alb-${local.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_az2.id]
}

resource "aws_security_group" "ecs_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = local.port
    to_port     = local.port
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

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_ecs_cluster" "main" {
  name = "payroll"
}

# Define the IAM policy for ECS task execution role
resource "aws_iam_policy" "ecs_task_execution_policy" {
  name        = "ecs-task-execution-policy-${local.environment}"
  description = "Policy to allow ECS tasks to pull images from GHCR"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
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
  family                   = "payroll-${local.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  memory                   = "512"
  cpu                      = "256"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "spring-boot-react-ci-cd-aws-tf"
      image = local.container_image
      portMappings = [
        {
          containerPort = local.port
          hostPort      = local.port
        }
      ]
      repositoryCredentials = {
        credentialsParameter = local.github_secret_arn
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.ecs_logs.name
          "awslogs-region" = "eu-west-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole-${local.environment}"

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

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name = "/ecs/${local.environment}/payroll"
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
  name               = "scale-up-policy-${local.environment}"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 70.0
  }
}

# Bucket for storing CloudTrail logs
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket_prefix = "cloudtrail-logs"
}