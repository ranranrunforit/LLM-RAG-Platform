# =============================================================================
# IAM — execution role + task role for ECS, execution role for SageMaker
# =============================================================================

# ── ECS Task Execution Role (used by ECS agent to pull image + write logs) ───

resource "aws_iam_role" "ecs_execution" {
  name = "${local.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Grant execution role permission to read the secrets we created.
# (The managed policy doesn't include Secrets Manager.)
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${local.name_prefix}-ecs-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.service_api_key.arn,
        aws_secretsmanager_secret.openai_api_key.arn,
      ]
    }]
  })
}

# ── ECS Task Role (used by the application code inside the container) ────────

resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow the RAG API to:
#  - read/write documents in the S3 bucket
#  - invoke the SageMaker endpoint
#  - read secrets at runtime (some libs re-read after startup)
resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.documents.arn,
          "${aws_s3_bucket.documents.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint",
          "sagemaker:InvokeEndpointAsync",
          "sagemaker:DescribeEndpoint",
        ]
        # Allow invoking any endpoint in this account/region — narrowed at runtime
        # by SAGEMAKER_ENDPOINT env var. Scope-down to specific ARN in production.
        Resource = "arn:aws:sagemaker:${local.region}:${local.account_id}:endpoint/*"
      },
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.service_api_key.arn,
          aws_secretsmanager_secret.openai_api_key.arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.rag_api.arn}:*"
      },
    ]
  })
}

# ── SageMaker Execution Role (used by the endpoint to pull model from S3) ────

resource "aws_iam_role" "sagemaker_execution" {
  count = var.enable_sagemaker ? 1 : 0

  name = "${local.name_prefix}-sagemaker-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  count = var.enable_sagemaker ? 1 : 0

  role       = aws_iam_role.sagemaker_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# ── EC2 Qdrant instance role (allows SSM session manager — no SSH keys needed) ─

resource "aws_iam_role" "qdrant_ec2" {
  count = var.enable_qdrant_vm ? 1 : 0

  name = "${local.name_prefix}-qdrant-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "qdrant_ssm" {
  count = var.enable_qdrant_vm ? 1 : 0

  role       = aws_iam_role.qdrant_ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "qdrant" {
  count = var.enable_qdrant_vm ? 1 : 0

  name = "${local.name_prefix}-qdrant-profile"
  role = aws_iam_role.qdrant_ec2[0].name
}
