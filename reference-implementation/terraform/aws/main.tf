# =============================================================================
# AWS Terraform - Main Configuration
# Project 303: Enterprise LLM Platform with RAG
#
# AWS deployment mirroring the GCP reference implementation.
# Architecture mapping (see ../README.md and ../docs/AWS_DEPLOYMENT.md):
#   - RAG API:        ECS Fargate              (GCP analog: Cloud Run)
#   - LLM Inference:  SageMaker Endpoint       (GCP analog: Gemini API)
#                     Llama 3 70B on ml.p4d.24xlarge (8x A100)
#                     — matches ARCHITECTURE.md hardware spec
#   - Vector DB:      Qdrant on EC2            (GCP analog: Qdrant VM)
#   - Container Reg:  ECR                      (GCP analog: Artifact Registry)
#   - Document Store: S3                       (GCP analog: GCS)
#   - Secrets:        Secrets Manager          (GCP analog: Secret Manager)
#   - Load Balancer:  ALB                      (GCP analog: Cloud Run native ingress)
#   - Logs/Metrics:   CloudWatch               (GCP analog: Cloud Logging/Monitoring)
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Uncomment to use S3 backend for state (recommended for teams)
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "project-303/aws/terraform.tfstate"
  #   region         = "us-west-2"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# ── Data sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project_name}-${var.environment}"

  # Pick first 2 AZs for cost (mirrors GCP single-region multi-zone pattern)
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs (root)
# ─────────────────────────────────────────────────────────────────────────────

output "rag_api_url" {
  description = "Public ALB URL for the RAG API (use this to call /health, /v1/chat)"
  value       = "http://${aws_lb.rag_api.dns_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL — push the RAG API image here"
  value       = aws_ecr_repository.rag_api.repository_url
}

output "docker_push_command" {
  description = "Command to build and push the RAG API image"
  value       = <<-CMD
    aws ecr get-login-password --region ${local.region} | \
      docker login --username AWS --password-stdin ${local.account_id}.dkr.ecr.${local.region}.amazonaws.com

    cd reference-implementation/python
    docker build -f Dockerfile.aws -t rag-api:latest .
    docker tag rag-api:latest ${aws_ecr_repository.rag_api.repository_url}:latest
    docker push ${aws_ecr_repository.rag_api.repository_url}:latest
  CMD
}

output "qdrant_internal_ip" {
  description = "Qdrant EC2 private IP (if enabled)"
  value       = var.enable_qdrant_vm ? try(aws_instance.qdrant[0].private_ip, "N/A") : "N/A"
}

output "sagemaker_endpoint_name" {
  description = "SageMaker endpoint name (if enabled). The ECS task uses this as SAGEMAKER_ENDPOINT env var."
  value       = var.enable_sagemaker ? try(aws_sagemaker_endpoint.llm[0].name, "N/A") : "N/A"
}

output "documents_bucket" {
  description = "S3 bucket for RAG document storage"
  value       = aws_s3_bucket.documents.id
}

output "set_secrets_command" {
  description = "Commands to set required API key secrets after `terraform apply`"
  value       = <<-CMD
    # OpenAI / Anthropic key (optional, only if you want commercial API fallback)
    aws secretsmanager put-secret-value \
      --secret-id ${aws_secretsmanager_secret.openai_api_key.name} \
      --secret-string 'YOUR_OPENAI_KEY' \
      --region ${local.region}

    # Service API key — protects the RAG API from public abuse
    aws secretsmanager put-secret-value \
      --secret-id ${aws_secretsmanager_secret.service_api_key.name} \
      --secret-string "$(openssl rand -base64 32)" \
      --region ${local.region}
  CMD
}
