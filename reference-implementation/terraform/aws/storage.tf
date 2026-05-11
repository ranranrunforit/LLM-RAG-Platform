# =============================================================================
# Storage — ECR (Docker images), S3 (documents), Secrets Manager (API keys)
# =============================================================================

# ── ECR repository for RAG API image ─────────────────────────────────────────

resource "aws_ecr_repository" "rag_api" {
  name                 = "${local.name_prefix}-rag-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${local.name_prefix}-rag-api"
  }
}

resource "aws_ecr_lifecycle_policy" "rag_api" {
  repository = aws_ecr_repository.rag_api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ── S3 bucket for RAG documents (analog to GCS bucket) ────────────────────────

resource "aws_s3_bucket" "documents" {
  bucket = "${local.name_prefix}-documents-${local.account_id}"

  tags = {
    Name = "${local.name_prefix}-documents"
  }
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 365
      storage_class = "STANDARD_IA"
    }
  }
}

# ── Secrets Manager — API keys ───────────────────────────────────────────────

# Service API key — used by the RAG API to authenticate inbound requests.
# The Terraform output prints a `put-secret-value` command; the user runs it
# manually after apply (matches GCP_DEPLOYMENT.md Step 4 pattern).
resource "aws_secretsmanager_secret" "service_api_key" {
  name        = "${local.name_prefix}-service-api-key"
  description = "API key required in X-API-Key header on RAG API requests"

  recovery_window_in_days = 0 # No recovery — easier to recreate during dev
}

# OpenAI key (optional fallback if user picks llm_backend=openai)
resource "aws_secretsmanager_secret" "openai_api_key" {
  name        = "${local.name_prefix}-openai-api-key"
  description = "OpenAI API key for commercial LLM fallback (optional)"

  recovery_window_in_days = 0
}

# Seed initial versions so ECS secret injection has an AWSCURRENT version even
# before the operator overwrites these values after `terraform apply`.
#
# Two constraints drive the placeholders below:
#   1. Secrets Manager rejects empty strings (`InvalidRequestException: A secret
#      value can't be empty`) — every version must have non-empty content.
#   2. We don't want Terraform to revert real values the operator sets later via
#      `aws secretsmanager put-secret-value`, so `ignore_changes` is required.
#
# The OpenAI key uses the literal sentinel "unset"; OpenAIProvider in
# src/llm/gateway.py treats this value as "no key" and skips registration.
resource "aws_secretsmanager_secret_version" "service_api_key" {
  secret_id     = aws_secretsmanager_secret.service_api_key.id
  secret_string = "CHANGE_ME_AFTER_TERRAFORM_APPLY"

  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = "unset"

  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}
