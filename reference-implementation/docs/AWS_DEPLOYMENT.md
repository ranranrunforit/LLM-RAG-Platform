# AWS Deployment Guide
**Project 303: Enterprise LLM Platform with RAG**

End-to-end deployment of the platform on AWS using **SageMaker** for LLM
inference (Llama 3 70B), **ECS Fargate** for the RAG API, **Qdrant on EC2**
for the vector store, **S3** for documents, and **Secrets Manager** for
credentials.

Architecture mapping (cf. GCP_DEPLOYMENT.md):

| Concern | AWS service | GCP analog |
|---|---|---|
| RAG API service | ECS Fargate | Cloud Run |
| LLM inference | SageMaker Endpoint (Llama 3 70B on ml.p4d.24xlarge) | Gemini API |
| Vector DB | Qdrant on EC2 | Qdrant on GCE VM |
| Container registry | ECR | Artifact Registry |
| Document storage | S3 | GCS |
| Secrets | Secrets Manager | Secret Manager |
| Logs / metrics | CloudWatch | Cloud Logging / Monitoring |
| Load balancer | Application Load Balancer | Cloud Run native HTTPS |

---

## Prerequisites

```bash
# 1. AWS CLI v2
aws --version          # >= 2.13

# 2. Terraform >= 1.5
terraform --version

# 3. Docker
docker --version

# 4. (Optional) jq for parsing CLI output
jq --version
```

You will also need:

- An AWS account with **SageMaker p4d.24xlarge quota** in your chosen region if
  you plan to enable the full Llama 3 70B endpoint. Quotas live under
  `Service Quotas → Amazon SageMaker → ml.p4d.24xlarge for endpoint usage`.
  Request an increase before running `terraform apply` with
  `enable_sagemaker=true`. For dev/testing, leave `enable_sagemaker=false` and
  the platform runs on Qdrant + OpenAI fallback (commercial API).
- A **HuggingFace account** with the Llama 3 license accepted at
  <https://huggingface.co/meta-llama/Meta-Llama-3-70B-Instruct> and a personal
  access token (settings → Access Tokens). Set it via `TF_VAR_huggingface_token`.

---

## Step 1 — Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region name:   us-west-2
# Default output format: json

# Verify
aws sts get-caller-identity
```

---

## Step 2 — Deploy Infrastructure with Terraform

```bash
cd reference-implementation/terraform/aws

# Create terraform.tfvars
cat > terraform.tfvars <<'EOF'
project_name = "project-303-rag"
environment  = "production"
region       = "us-west-2"

# Set true ONLY when ready to spend ~$23.5K/month on Llama 3 70B
enable_sagemaker         = false
enable_sagemaker_mistral = false

# Vector DB on EC2 — recommended for persistence
enable_qdrant_vm = true

# Match ARCHITECTURE.md HPA pattern: 2 → 10 tasks
ecs_desired_count = 2
ecs_max_count     = 10
EOF

# If you plan to enable SageMaker now, also export the HF token:
export TF_VAR_huggingface_token="hf_xxxxxxxxxxxxxxxx"

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

`terraform apply` creates: VPC, subnets, NAT, ALB, ECS cluster, task
definition, autoscaling target, ECR repository, S3 bucket, Secrets Manager
secrets, Qdrant EC2 instance, and (if enabled) the SageMaker endpoint.

> **First apply will create the ECS service but tasks will be in `PENDING`
> until the ECR image exists** — that's expected. We push the image in Step 4
> then ECS pulls it.

Save the outputs:

```bash
terraform output -raw rag_api_url
terraform output -raw ecr_repository_url
terraform output -raw documents_bucket
terraform output -raw sagemaker_endpoint_name   # "N/A" if disabled
```

---

## Step 3 — Populate Secrets

The Terraform stack creates the secrets but, like GCP, does not set values.

```bash
REGION=us-west-2
PROJECT=project-303-rag-production

# Generate and store the RAG API service key
SERVICE_API_KEY=$(openssl rand -base64 32)
aws secretsmanager put-secret-value \
  --secret-id ${PROJECT}-service-api-key \
  --secret-string "$SERVICE_API_KEY" \
  --region $REGION

# (Optional) OpenAI key for commercial-API fallback
# aws secretsmanager put-secret-value \
#   --secret-id ${PROJECT}-openai-api-key \
#   --secret-string 'sk-...' \
#   --region $REGION

echo "Save this key for calling the API later:"
echo "API_KEY=$SERVICE_API_KEY"
```

---

## Step 4 — Build and Push the RAG API Image

```bash
cd reference-implementation/python

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-2
ECR_REPO=$(cd ../terraform/aws && terraform output -raw ecr_repository_url)

# Authenticate Docker against ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Build the AWS image (pre-bakes the embedding + reranker models)
docker build -f Dockerfile.aws -t rag-api:aws .

# Tag + push
docker tag rag-api:aws "$ECR_REPO:latest"
docker push "$ECR_REPO:latest"
```

The build takes ~10 min because it downloads PyTorch and the sentence
transformer model. After push, ECS will pull within ~1 minute and start
healthy tasks.

> If you do not have local Docker, use **AWS CodeBuild** with the same
> Dockerfile or **Cloud9** for a browser-based equivalent.

---

## Step 5 — Force ECS to Pull the New Image

```bash
aws ecs update-service \
  --cluster project-303-rag-production-cluster \
  --service project-303-rag-production-rag-api \
  --force-new-deployment \
  --region us-west-2

# Wait until at least one task is RUNNING + healthy
aws ecs wait services-stable \
  --cluster project-303-rag-production-cluster \
  --services project-303-rag-production-rag-api \
  --region us-west-2
```

---

## Step 6 — Smoke Test

```bash
RAG_URL=$(cd reference-implementation/terraform/aws && terraform output -raw rag_api_url)
API_KEY=$SERVICE_API_KEY   # from Step 3

# Health check
curl "$RAG_URL/health"
# Expected: {"status":"ok","services":{"qdrant":"ok","llm":"ok (sagemaker)" or "ok (openai)"}...}

# Index a document
curl -X POST "$RAG_URL/v1/documents" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"documents":[{"id":"doc-1","text":"Enterprise customers may request a full refund within 30 days of purchase.","metadata":{"source":"refund-policy"}}]}'

# RAG query — only works if SageMaker is enabled OR OpenAI key is set
curl -X POST "$RAG_URL/v1/chat" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"query":"What is the refund policy for enterprise customers?","user_id":"smoke-test"}'

# Retrieval only (no LLM — always works)
curl -X POST "$RAG_URL/v1/retrieve" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"query":"refund","top_k":3}'
```

---

## Step 7 — (Optional) Enable SageMaker Llama 3 70B

This is the expensive step. **Confirm your p4d quota and budget first.**

```bash
cd reference-implementation/terraform/aws

# Pre-flight: confirm quota for ml.p4d.24xlarge endpoint usage in your region
aws service-quotas get-service-quota \
  --service-code sagemaker \
  --quota-code L-1194F228 \
  --region us-west-2

# Flip the flag + apply
sed -i 's/enable_sagemaker = false/enable_sagemaker = true/' terraform.tfvars

# Ensure the HF token is exported (needed to download Llama 3 weights)
export TF_VAR_huggingface_token="hf_xxxxxxxxxxxxxxxx"

terraform apply
# Endpoint provisioning takes ~15-20 minutes (model download dominates).

# Verify
aws sagemaker describe-endpoint \
  --endpoint-name $(terraform output -raw sagemaker_endpoint_name) \
  --region us-west-2 \
  --query 'EndpointStatus'

# Force ECS to pick up the new SAGEMAKER_ENDPOINT env value
aws ecs update-service \
  --cluster project-303-rag-production-cluster \
  --service project-303-rag-production-rag-api \
  --force-new-deployment \
  --region us-west-2
```

After ECS recycles, `/health` will report `llm: ok (sagemaker)` and `/v1/chat`
will route through Llama 3 70B.

---

## Step 8 — Tear Down (stop charges)

The biggest ongoing cost is the SageMaker endpoint. Disable it first if you
want to pause without destroying the rest:

```bash
sed -i 's/enable_sagemaker = true/enable_sagemaker = false/' terraform.tfvars
terraform apply
```

Full teardown:

```bash
# Empty the documents bucket first (Terraform refuses to delete non-empty buckets)
DOCS_BUCKET=$(terraform output -raw documents_bucket)
aws s3 rm s3://$DOCS_BUCKET --recursive

terraform destroy
```

---

## Cost Summary

| Component | Setup | Monthly cost |
|---|---|---|
| ECS Fargate (2 tasks × 2 vCPU/4 GiB) | Always on | ~$70 |
| ALB | Single LB, low traffic | ~$22 |
| NAT Gateway | Single AZ | ~$32 + data |
| Qdrant EC2 t3.medium | 24/7 | ~$30 |
| EBS gp3 50 GiB | Qdrant data | ~$5 |
| S3 (documents) | <100 GiB | ~$3 |
| Secrets Manager (2 secrets) | | ~$1 |
| CloudWatch Logs (ECS Container Insights) | | ~$5–15 |
| **Baseline (no SageMaker)** | | **≈$170/mo** |
| SageMaker ml.p4d.24xlarge (Llama 3 70B) | If enabled, 24/7 | **+$23,500/mo** |
| SageMaker ml.g5.12xlarge (Mistral 7B opt.) | If enabled, 24/7 | +$4,100/mo |
| **Full enterprise mode** | | **≈$28K–$30K/mo** |

This aligns with the ADR-001 / ARCHITECTURE.md target of `$100K/mo` for
self-hosted infrastructure once you scale to the full 8x A100 + 4x A10G
fleet and include OpenAI fallback charges.

---

## Troubleshooting

### ECS task keeps failing the health check
- Inspect CloudWatch Logs at `/ecs/project-303-rag-production-rag-api`.
- Common: `QDRANT_HOST` resolves to an instance that hasn't finished booting
  — wait 2 minutes, the Qdrant EC2 user-data installs Docker on first boot.
- Common: `boto3` cannot reach Secrets Manager — confirm the ECS task role
  has the policy from `iam.tf` (Terraform applies this automatically).

### `InvokeEndpoint` returns `ValidationException: Endpoint ... not found`
- The Terraform output `sagemaker_endpoint_name` and the ECS env var get
  out of sync if you flipped `enable_sagemaker` without redeploying ECS.
- Fix: re-run `aws ecs update-service ... --force-new-deployment`.

### Llama 3 download stalls inside SageMaker
- SageMaker logs are in CloudWatch under `/aws/sagemaker/Endpoints/<name>`.
- Most common cause: the HuggingFace token is wrong or the Llama 3 license
  was not accepted on huggingface.co.

### Want to use the EKS path instead of ECS Fargate
- The recommended path is ECS Fargate (simpler, no cluster to manage).
- If your org already runs EKS, see `kubernetes/aws/rag-service/deployment.yaml`
  for an equivalent Deployment + Ingress (ALB) manifest, plus
  `kubernetes/aws/qdrant/deployment.yaml`. Replace `ACCOUNT_ID` placeholders
  and ensure the AWS Load Balancer Controller and EBS CSI driver are
  installed on the cluster.

---

## Next Steps

- See `runbooks/deployment-guide-aws.md` for ongoing operations (scaling,
  rolling updates, blue/green for SageMaker variants).
- See `docs/COST-MODEL.md` for a full GCP vs AWS cost comparison.
- See `architecture/decisions/ADR-006-multi-cloud-deployment.md` for the
  rationale of the dual-cloud reference implementation.
