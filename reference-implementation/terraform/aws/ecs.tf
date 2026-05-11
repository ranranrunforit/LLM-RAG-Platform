# =============================================================================
# ECS Fargate — RAG API service (analog to GCP Cloud Run)
# =============================================================================

# ── CloudWatch log group ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "rag_api" {
  name              = "/ecs/${local.name_prefix}-rag-api"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-rag-api-logs"
  }
}

# ── ECS Cluster ──────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── Task Definition ──────────────────────────────────────────────────────────

# Resolve the SageMaker endpoint name into the task env. When SageMaker is
# disabled, the value is empty — the Python LLM gateway falls back to whatever
# other provider is configured (OpenAI if openai_api_key secret is set).
#
# `effective_llm_backend` guards against the foot-gun of leaving
# llm_backend="sagemaker" while enable_sagemaker=false. In that case, the
# SageMaker provider would not register and the first request would 500 with
# "No LLM providers available". Force the backend to "openai" so the gateway
# at least tries the commercial fallback (and fails loudly at startup if the
# OpenAI key was never put into Secrets Manager).
locals {
  sagemaker_endpoint_name = var.enable_sagemaker ? try(aws_sagemaker_endpoint.llm[0].name, "") : ""
  qdrant_host             = var.enable_qdrant_vm ? try(aws_instance.qdrant[0].private_ip, "localhost") : ":memory:"
  effective_llm_backend   = var.enable_sagemaker ? var.llm_backend : "openai"
}

resource "aws_ecs_task_definition" "rag_api" {
  family                   = "${local.name_prefix}-rag-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "rag-api"
    image     = "${aws_ecr_repository.rag_api.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "LLM_BACKEND", value = local.effective_llm_backend },
      { name = "EMBEDDING_MODEL", value = var.embedding_model },
      { name = "QDRANT_HOST", value = local.qdrant_host },
      { name = "QDRANT_PORT", value = "6333" },
      { name = "SAGEMAKER_ENDPOINT", value = local.sagemaker_endpoint_name },
      { name = "SAGEMAKER_REGION", value = local.region },
      { name = "AWS_REGION", value = local.region },
      { name = "ENABLE_RERANKING", value = "true" },
      { name = "ENABLE_PII_DETECTION", value = "true" },
      # Force HuggingFace offline mode — same trick as GCP Cloud Run.
      # Models are pre-baked into the Docker image at build time.
      { name = "HF_HUB_OFFLINE", value = "1" },
      { name = "TRANSFORMERS_OFFLINE", value = "1" },
      { name = "S3_DOCUMENTS_BUCKET", value = aws_s3_bucket.documents.id },
    ]

    secrets = [
      { name = "API_KEY", valueFrom = aws_secretsmanager_secret.service_api_key.arn },
      { name = "OPENAI_API_KEY", valueFrom = aws_secretsmanager_secret.openai_api_key.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.rag_api.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "rag-api"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 90 # Embedding model needs ~60s to warm up
    }
  }])

  tags = {
    Name = "${local.name_prefix}-rag-api"
  }
}

# ── ALB ──────────────────────────────────────────────────────────────────────

resource "aws_lb" "rag_api" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "rag_api" {
  name        = "${local.name_prefix}-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

resource "aws_lb_listener" "rag_api" {
  load_balancer_arn = aws_lb.rag_api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rag_api.arn
  }
}

# ── ECS Service ──────────────────────────────────────────────────────────────

resource "aws_ecs_service" "rag_api" {
  name            = "${local.name_prefix}-rag-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rag_api.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.rag_api.arn
    container_name   = "rag-api"
    container_port   = 8080
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # Ignore desired_count drift caused by autoscaling
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.rag_api]

  tags = {
    Name = "${local.name_prefix}-rag-api"
  }
}

# ── Autoscaling (matches ARCHITECTURE.md HPA pattern: 2 → 10 replicas) ───────

resource "aws_appautoscaling_target" "rag_api" {
  max_capacity       = var.ecs_max_count
  min_capacity       = var.ecs_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.rag_api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "rag_api_cpu" {
  name               = "${local.name_prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.rag_api.resource_id
  scalable_dimension = aws_appautoscaling_target.rag_api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.rag_api.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
