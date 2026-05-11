# Project 303: LLM Platform with RAG — Reference Implementation

Two end-to-end reference implementations of the architecture in
[../ARCHITECTURE.md](../ARCHITECTURE.md): one on **GCP** (Cloud Run + Gemini),
one on **AWS** (ECS Fargate + SageMaker). Both deploy the same RAG pipeline,
guardrails, and FastAPI surface — the only thing that changes is the cloud
substrate.

| | GCP path | AWS path |
|---|---|---|
| RAG API runtime | Cloud Run | ECS Fargate (or EKS) |
| LLM inference | Gemini API (default), vLLM VM (optional) | SageMaker endpoint, Llama 3 70B on ml.p4d.24xlarge |
| Vector DB | Qdrant on GCE VM | Qdrant on EC2 |
| Container registry | Artifact Registry | ECR |
| Documents | GCS | S3 |
| Secrets | Secret Manager | Secrets Manager |
| First-time setup doc | [docs/GCP_DEPLOYMENT.md](docs/GCP_DEPLOYMENT.md) | [docs/AWS_DEPLOYMENT.md](docs/AWS_DEPLOYMENT.md) |
| Cost (baseline / full enterprise) | $0–$130/mo / ~$160K/mo | ~$170/mo / ~$30K/mo* |

\* AWS Llama 3 70B endpoint on a 1-year Savings Plan brings full mode to
~$50K–60K/mo. See [docs/COST-MODEL.md](docs/COST-MODEL.md).

---

## Directory Structure

```
reference-implementation/
├── README.md                            # ← you are here
├── docker-compose.yml                   # Local dev (Qdrant + RAG API on your laptop)
├── colab_quickstart.ipynb               # Free-tier Colab walkthrough
│
├── terraform/
│   ├── gcp/                             # GCP infrastructure (Cloud Run + GCS + Qdrant VM)
│   │   ├── main.tf
│   │   ├── cloud-run.tf
│   │   └── variables.tf
│   ├── aws/                             # AWS infrastructure (ECS + SageMaker + Qdrant EC2)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── vpc.tf
│   │   ├── ecs.tf
│   │   ├── sagemaker.tf
│   │   ├── qdrant.tf
│   │   ├── storage.tf
│   │   └── iam.tf
│   └── modules/
│       └── gpu-nodes/                   # Reusable EKS+GPU node group (advanced)
│
├── kubernetes/
│   ├── gcp/                             # GKE Deployment manifests
│   │   ├── rag-service/
│   │   ├── qdrant/
│   │   └── monitoring/
│   ├── aws/                             # EKS Deployment manifests (alternative to ECS)
│   │   ├── rag-service/
│   │   └── qdrant/
│   └── vllm/                            # vLLM-on-Kubernetes (Llama 3 70B), cloud-agnostic
│
├── python/
│   ├── Dockerfile                       # GCP image (Gemini-first)
│   ├── Dockerfile.aws                   # AWS image (boto3 + SageMaker bootstrap)
│   ├── requirements.txt                 # Base deps
│   ├── requirements-aws.txt             # boto3 (layered on top of requirements.txt)
│   ├── src/
│   │   ├── api/main.py                  # FastAPI service (/v1/chat, /v1/documents, /v1/retrieve)
│   │   ├── rag/pipeline.py              # 2-stage retrieval (vector + reranker)
│   │   ├── guardrails/safety.py         # PII + prompt-injection + content moderation
│   │   └── llm/
│   │       ├── gateway.py               # LLMGateway + Gemini + vLLM providers
│   │       └── sagemaker_provider.py    # AWS SageMaker provider (auto-attaches via monkey-patch)
│   └── tests/unit/                      # pytest suite
│
├── monitoring/
│   └── prometheus/                      # Cloud-agnostic alert rules
│
└── docs/
    ├── GCP_DEPLOYMENT.md                # End-to-end GCP setup
    ├── GKE_DEPLOYMENT.md                # GKE variant of the GCP path
    ├── AWS_DEPLOYMENT.md                # End-to-end AWS setup (this is the AWS analog of GCP_DEPLOYMENT.md)
    └── COST-MODEL.md                    # GCP vs AWS cost breakdown
```

---

## Quick Start

### Local (your laptop)

```bash
cd reference-implementation
cp python/.env.example .env
# Edit .env to set GOOGLE_API_KEY=... (Gemini) or OPENAI_API_KEY=...
docker compose up
curl http://localhost:8080/health
```

### Google Colab (free, zero infra)

Open [`colab_quickstart.ipynb`](colab_quickstart.ipynb) — it runs the full
RAG pipeline with in-memory Qdrant, HuggingFace embeddings on CPU, and
Gemini Pro for generation.

### GCP (Cloud Run + Gemini)

Follow [docs/GCP_DEPLOYMENT.md](docs/GCP_DEPLOYMENT.md). One-line summary:

```bash
cd terraform/gcp
terraform init && terraform apply
# then build + push the Docker image to Artifact Registry
# then re-run terraform apply to wire Cloud Run to the image
```

### AWS (ECS Fargate + SageMaker)

Follow [docs/AWS_DEPLOYMENT.md](docs/AWS_DEPLOYMENT.md). One-line summary:

```bash
cd terraform/aws
terraform init && terraform apply           # creates VPC, ECS, ECR, S3, Qdrant EC2

cd ../../python
docker build -f Dockerfile.aws -t rag-api:aws .
# push to ECR (see AWS_DEPLOYMENT.md Step 4)

# To enable Llama 3 70B inference (~$23.5K/mo), edit terraform.tfvars:
#   enable_sagemaker = true
# Then `terraform apply` again.
```

---

## How the Same Code Targets Both Clouds

The `python/src/` tree is shared between the two deployments — only the
Dockerfile and a small bootstrap module differ.

- **GCP** uses `Dockerfile` and constructs `LLMGateway(...)` directly. The
  gateway auto-registers Gemini (if `GOOGLE_API_KEY` is set) and vLLM (if
  `VLLM_ENDPOINT` is set).
- **AWS** uses `Dockerfile.aws`. The entrypoint imports
  `src.llm.sagemaker_provider`, which on import monkey-patches
  `LLMGateway.__init__` to also attach a `SageMakerProvider` whenever
  `SAGEMAKER_ENDPOINT` is set. The GCP source files are not modified.

This keeps the RAG pipeline, guardrails, and API surface identical across
clouds.

---

## Operations

- GCP day-2 runbook: [../runbooks/deployment-guide.md](../runbooks/deployment-guide.md)
- AWS day-2 runbook: [../runbooks/deployment-guide-aws.md](../runbooks/deployment-guide-aws.md)
- Architecture decisions: [../architecture/decisions/](../architecture/decisions/)
- Why two clouds: [../architecture/decisions/ADR-006-multi-cloud-deployment.md](../architecture/decisions/ADR-006-multi-cloud-deployment.md)
