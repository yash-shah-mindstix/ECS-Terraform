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

resource "aws_security_group" "ecs2" {
  name   = "${var.project_name}-ecs2-sg"
  vpc_id = var.vpc_id

  # Allow traffic from ALB
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Allow traffic only from Service A SG
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id] # Only Service A
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

  tags = local.common_tags
}

# Target Group for Service A
resource "aws_lb_target_group" "service_a_tg" {
  name        = "${var.project_name}-tg-a"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

  tags = local.common_tags
}

# Target Group for Service B
resource "aws_lb_target_group" "service_b_tg" {
  name        = "${var.project_name}-tg-b"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

  tags = local.common_tags
}

# HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.demo.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# Listener Rule for Service A
resource "aws_lb_listener_rule" "service_a_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_a_tg.arn
  }

  condition {
    path_pattern {
      values = ["/service-a/*"]
    }
  }
}

# Listener Rule for Service B
resource "aws_lb_listener_rule" "service_b_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_b_tg.arn
  }

  condition {
    path_pattern {
      values = ["/service-b/*"]
    }
  }
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
    }
  ])

  tags = local.common_tags
}

############################################
# ECS Service
############################################

resource "aws_ecs_service" "serviceA" {
  name            = "${var.project_name}-service-a"
  cluster         = aws_ecs_cluster.demo.id
  task_definition = aws_ecs_task_definition.demo.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.pvt_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service_a_tg.arn
    container_name   = "demo"
    container_port   = 80
  }

  depends_on = [
    aws_lb_listener_rule.service_a_rule
  ]

  tags = local.common_tags
}

resource "aws_ecs_service" "serviceB" {
  name            = "${var.project_name}-service-b"
  cluster         = aws_ecs_cluster.demo.id
  task_definition = aws_ecs_task_definition.demo.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.pvt_subnet_ids
    security_groups  = [aws_security_group.ecs2.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service_b_tg.arn
    container_name   = "demo"
    container_port   = 80
  }

  depends_on = [
    aws_lb_listener_rule.service_b_rule
  ]

  tags = local.common_tags
}

############################################
# Auto Scaling – Service A
############################################

# 1) Define the scalable target
resource "aws_appautoscaling_target" "serviceA_target" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.demo.name}/${aws_ecs_service.serviceA.name}"
  min_capacity       = 1
  max_capacity       = 4
}

# 2) Define a target tracking scaling policy
resource "aws_appautoscaling_policy" "serviceA_cpu_policy" {
  name               = "${var.project_name}-cpu-scaling-A"
  service_namespace  = aws_appautoscaling_target.serviceA_target.service_namespace
  resource_id        = aws_appautoscaling_target.serviceA_target.resource_id
  scalable_dimension = aws_appautoscaling_target.serviceA_target.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 50.0
  }
}
