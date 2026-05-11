# =============================================================================
# AWS Terraform - Variables
# =============================================================================

variable "project_name" {
  description = "Project name prefix for AWS resources"
  type        = string
  default     = "project-303-rag"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  default     = "production"
}

variable "region" {
  description = "AWS region (must support SageMaker p4d.24xlarge if enable_sagemaker=true)"
  type        = string
  default     = "us-west-2"
}

# ── Networking ───────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

# ── ECS Fargate (RAG API) ────────────────────────────────────────────────────

variable "ecs_task_cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)"
  type        = string
  default     = "2048" # 2 vCPU — matches GCP Cloud Run default
}

variable "ecs_task_memory" {
  description = "Fargate task memory (MiB)"
  type        = string
  default     = "4096" # 4 GiB
}

variable "ecs_desired_count" {
  description = "Desired number of ECS service tasks"
  type        = number
  default     = 2 # min 2 for HA (matches ARCHITECTURE.md HPA minReplicas)
}

variable "ecs_max_count" {
  description = "Max number of ECS service tasks for autoscaling"
  type        = number
  default     = 10 # matches ARCHITECTURE.md maxReplicas
}

# ── LLM Backend Configuration ────────────────────────────────────────────────

variable "llm_backend" {
  description = "LLM backend: 'sagemaker' (Llama 3 70B self-hosted) or 'openai' (commercial fallback)"
  type        = string
  default     = "sagemaker"

  validation {
    condition     = contains(["sagemaker", "openai"], var.llm_backend)
    error_message = "llm_backend must be 'sagemaker' or 'openai'"
  }
}

variable "embedding_model" {
  description = "HuggingFace embedding model name (runs inside the ECS task)"
  type        = string
  default     = "BAAI/bge-small-en-v1.5"
}

# ── SageMaker Endpoint ───────────────────────────────────────────────────────

variable "enable_sagemaker" {
  description = "Deploy a SageMaker endpoint for self-hosted LLM inference. WARNING: ml.p4d.24xlarge costs ~$32.77/hr (~$23.5K/month)."
  type        = bool
  default     = false # Off by default to avoid surprise charges
}

variable "sagemaker_model_id" {
  description = "HuggingFace model repo to deploy on the SageMaker TGI container. Default is Llama 3 70B Instruct (matches ADR-001)."
  type        = string
  default     = "meta-llama/Meta-Llama-3-70B-Instruct"
}

variable "sagemaker_instance_type" {
  description = "SageMaker endpoint instance type. ml.p4d.24xlarge = 8x A100 (matches ARCHITECTURE.md). Use ml.g5.12xlarge (4x A10G, ~$5.67/hr) for cheaper dev."
  type        = string
  default     = "ml.p4d.24xlarge"
}

variable "sagemaker_initial_instance_count" {
  description = "Number of SageMaker endpoint instances"
  type        = number
  default     = 1
}

# HuggingFace Hub token for downloading gated models like Llama 3.
# Llama 3 requires accepting Meta's license on HuggingFace first.
variable "huggingface_token" {
  description = "HuggingFace Hub access token (required to download Llama 3 weights — accept the license at huggingface.co/meta-llama/Meta-Llama-3-70B-Instruct first)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_sagemaker_mistral" {
  description = "Also deploy a Mistral 7B endpoint on ml.g5.12xlarge for simple queries — matches the ADR-001 70/30 routing pattern. Adds ~$4.1K/month."
  type        = bool
  default     = false
}

# ── Qdrant VM (Vector DB) ────────────────────────────────────────────────────

variable "enable_qdrant_vm" {
  description = "Deploy a dedicated EC2 instance for Qdrant. Set false to run Qdrant in-memory inside the ECS task (lost on restart)."
  type        = bool
  default     = true
}

variable "qdrant_instance_type" {
  description = "EC2 instance type for Qdrant"
  type        = string
  default     = "t3.medium" # 2 vCPU, 4 GiB RAM, ~$30/month — matches GCP e2-medium
}

variable "qdrant_volume_size" {
  description = "EBS volume size (GiB) for Qdrant storage"
  type        = number
  default     = 50
}

# ── Optional: EKS / vLLM mode (advanced) ─────────────────────────────────────

variable "enable_vllm_eks" {
  description = "Reserved flag — see kubernetes/aws/ for an EKS+vLLM deployment path. Not provisioned by this Terraform stack."
  type        = bool
  default     = false
}

# ── Tagging ──────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Default tags applied to all AWS resources"
  type        = map(string)
  default = {
    Project    = "project-303-llm-rag"
    ManagedBy  = "terraform"
    CostCenter = "ai-infrastructure"
  }
}
