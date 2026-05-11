# =============================================================================
# SageMaker Endpoint — Self-hosted LLM (Llama 3 70B by default)
#
# This block is GATED on var.enable_sagemaker because ml.p4d.24xlarge costs
# ~$32.77/hour (~$23.5K/month). Leave it off until you're ready to incur cost.
#
# Strategy: deploy via JumpStart pre-trained model URIs. AWS publishes Llama 3
# weights packaged with the HuggingFace TGI inference container, so we don't
# have to bundle our own image. SageMaker handles tensor parallelism across the
# 8 A100 GPUs automatically.
#
# Note on instance type:
#   ml.p4d.24xlarge  = 8x A100 80GB  → matches ARCHITECTURE.md spec
#   ml.g5.48xlarge   = 8x A10G 24GB  → ~$16.30/hr, half the cost, slower
#   ml.g5.12xlarge   = 4x A10G 24GB  → ~$5.67/hr, only fits Llama 3 8B/13B
# =============================================================================

# JumpStart image URIs vary by region. This map covers common ones; extend
# as needed (full list: https://docs.aws.amazon.com/sagemaker/latest/dg-ecr-paths/ecr-us-west-2.html).
# These point to the HuggingFace Text Generation Inference (TGI) container.
locals {
  tgi_image_uris = {
    "us-east-1"      = "763104351884.dkr.ecr.us-east-1.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
    "us-east-2"      = "763104351884.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
    "us-west-2"      = "763104351884.dkr.ecr.us-west-2.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
    "eu-west-1"      = "763104351884.dkr.ecr.eu-west-1.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
    "ap-northeast-1" = "763104351884.dkr.ecr.ap-northeast-1.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
  }
}

# ── SageMaker Model ──────────────────────────────────────────────────────────

resource "aws_sagemaker_model" "llm" {
  count = var.enable_sagemaker ? 1 : 0

  name               = "${local.name_prefix}-llm-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  execution_role_arn = aws_iam_role.sagemaker_execution[0].arn

  primary_container {
    image = lookup(
      local.tgi_image_uris,
      local.region,
      "763104351884.dkr.ecr.${local.region}.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
    )

    # TGI environment variables for tensor parallelism across the 8 A100 GPUs
    environment = {
      HF_MODEL_ID            = var.sagemaker_model_id
      HF_TOKEN               = var.huggingface_token
      SM_NUM_GPUS            = "8"          # tensor parallel size
      MAX_INPUT_LENGTH       = "4096"
      MAX_TOTAL_TOKENS       = "8192"       # matches Llama 3 context window
      MAX_BATCH_TOTAL_TOKENS = "16384"
      MAX_BATCH_PREFILL_TOKENS = "16384"
      # Continuous batching is on by default in TGI
    }
  }

  # Re-create model when image changes
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [name]
  }

  tags = {
    Name = "${local.name_prefix}-llm-model"
  }
}

# ── Endpoint Config ──────────────────────────────────────────────────────────

resource "aws_sagemaker_endpoint_configuration" "llm" {
  count = var.enable_sagemaker ? 1 : 0

  name = "${local.name_prefix}-llm-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.llm[0].name
    initial_instance_count = var.sagemaker_initial_instance_count
    instance_type          = var.sagemaker_instance_type
    initial_variant_weight = 1
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [name]
  }

  tags = {
    Name = "${local.name_prefix}-llm-config"
  }
}

# ── Endpoint ─────────────────────────────────────────────────────────────────

resource "aws_sagemaker_endpoint" "llm" {
  count = var.enable_sagemaker ? 1 : 0

  name                 = "${local.name_prefix}-llm"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.llm[0].name

  tags = {
    Name = "${local.name_prefix}-llm-endpoint"
  }
}

# ── Optional: secondary smaller model (Mistral 7B) ───────────────────────────
# Matches ADR-001 "70% Llama 3 70B + 30% Mistral 7B" routing pattern.
# Enable by setting enable_sagemaker_mistral=true. Uses cheaper g5.12xlarge.

resource "aws_sagemaker_model" "mistral" {
  count = var.enable_sagemaker && var.enable_sagemaker_mistral ? 1 : 0

  name               = "${local.name_prefix}-mistral-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  execution_role_arn = aws_iam_role.sagemaker_execution[0].arn

  primary_container {
    image = lookup(
      local.tgi_image_uris,
      local.region,
      "763104351884.dkr.ecr.${local.region}.amazonaws.com/huggingface-pytorch-tgi-inference:2.1.1-tgi1.4.0-gpu-py310-cu121-ubuntu22.04"
    )

    environment = {
      HF_MODEL_ID            = "mistralai/Mistral-7B-Instruct-v0.3"
      HF_TOKEN               = var.huggingface_token
      SM_NUM_GPUS            = "4"
      MAX_INPUT_LENGTH       = "4096"
      MAX_TOTAL_TOKENS       = "8192"
      MAX_BATCH_TOTAL_TOKENS = "16384"
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [name]
  }
}

resource "aws_sagemaker_endpoint_configuration" "mistral" {
  count = var.enable_sagemaker && var.enable_sagemaker_mistral ? 1 : 0

  name = "${local.name_prefix}-mistral-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.mistral[0].name
    initial_instance_count = 1
    instance_type          = "ml.g5.12xlarge" # 4x A10G — fits Mistral 7B comfortably
    initial_variant_weight = 1
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [name]
  }
}

resource "aws_sagemaker_endpoint" "mistral" {
  count = var.enable_sagemaker && var.enable_sagemaker_mistral ? 1 : 0

  name                 = "${local.name_prefix}-mistral"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.mistral[0].name
}

# Extra output when the Mistral endpoint exists
output "sagemaker_mistral_endpoint_name" {
  description = "SageMaker Mistral 7B endpoint name (if enabled)"
  value       = var.enable_sagemaker && var.enable_sagemaker_mistral ? try(aws_sagemaker_endpoint.mistral[0].name, "N/A") : "N/A"
}
