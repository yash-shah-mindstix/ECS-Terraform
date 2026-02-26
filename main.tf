terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}


############################################
# Provider
############################################

provider "aws" {
  region = var.region
}

############################################
# Local Tags
############################################

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
    Application = "INNSPIRE"
  }
}

############################################
# ECS Cluster
############################################

resource "aws_ecs_cluster" "demo" {
  name = "${var.project_name}-cluster"
  tags = local.common_tags
}

############################################
# IAM Role
############################################

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project_name}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_attach" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

############################################
# Security Groups
############################################

resource "aws_security_group" "alb" {
  name   = "${var.project_name}-alb-sg"
  vpc_id = var.vpc_id

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

  tags = local.common_tags
}

resource "aws_security_group" "ecs" {
  name   = "${var.project_name}-ecs-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

############################################
# ALB (Ingress Equivalent)
############################################

resource "aws_lb" "demo" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  tags               = local.common_tags
}

resource "aws_lb_target_group" "demo" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path = "/"
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.demo.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo.arn
  }
}

############################################
# CloudWatch Logs
############################################

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
  tags              = local.common_tags
}

############################################
# Task Definition
############################################

resource "aws_ecs_task_definition" "demo" {
  family                   = "${var.project_name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256" #0.25 vCPU
  memory                   = "512" #512MB
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "demo"
      image     = "nginx:latest"
      essential = true

      portMappings = [{
        containerPort = 80
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = local.common_tags
}

############################################
# ECS Service
############################################

resource "aws_ecs_service" "demo" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.demo.id
  task_definition = aws_ecs_task_definition.demo.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.demo.arn
    container_name   = "demo"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http]

  tags = local.common_tags
}

############################################
# Auto Scaling
############################################

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.demo.name}/${aws_ecs_service.demo.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 5

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
