# Cost Model — GCP vs AWS

Project 303 has two runnable reference implementations. This document
describes the cost profile of each so stakeholders can pick the right path.

> **TL;DR**: The GCP path is optimised for **dev / low-traffic production**
> (~$0–$130/mo). The AWS path is optimised to mirror the **enterprise
> architecture in ARCHITECTURE.md** (~$28K/mo full mode with Llama 3 70B on
> SageMaker, ~$170/mo baseline). Both expose the same REST API and use the
> same RAG pipeline code.

---

## 1. Mapping Each Cost Line Item

| Concern | GCP cost | AWS cost |
|---|---|---|
| RAG API service | Cloud Run (pay-per-request; free 2M req/month) | ECS Fargate (always-on, 2 tasks × 2 vCPU × 4 GiB) |
| LLM inference (primary) | Gemini API (pay-per-token, ~$0.075 / 1M input tokens for Flash) | SageMaker ml.p4d.24xlarge ($32.77/hr always-on) |
| LLM inference (alt) | Self-hosted vLLM on g2-standard-4 (~$100/mo spot) | SageMaker ml.g5.12xlarge ($5.67/hr) |
| Vector DB | Qdrant on e2-medium (~$30/mo) or in-memory ($0) | Qdrant on t3.medium (~$30/mo) + EBS |
| Document storage | GCS (free up to 5 GiB) | S3 (~$3/mo at <100 GiB) |
| Container registry | Artifact Registry (~$0.10/GB/mo) | ECR (~$0.10/GB/mo) |
| Secrets | Secret Manager (~$0.06/secret/mo, 6 free) | Secrets Manager (~$0.40/secret/mo) |
| Load balancer | Native Cloud Run HTTPS (free) | Application Load Balancer (~$22/mo) |
| Egress / NAT | Cloud Run egress, no NAT required | NAT Gateway (~$32/mo + data) |
| Logs / metrics | Cloud Logging / Monitoring (generous free tier) | CloudWatch (~$5–15/mo for this scale) |

---

## 2. Three Operating Modes

### Mode A — Demo / Dev (both clouds)

The API runs but uses the cheapest possible LLM and zero GPU.

| Item | GCP | AWS |
|---|---|---|
| Compute | Cloud Run (scale-to-zero) | ECS Fargate 1 task |
| Vector DB | In-memory | EC2 t3.medium |
| LLM | Gemini Flash API (pay per request) | OpenAI fallback (pay per request) |
| **Estimate** | **$0 + Gemini usage** | **~$110/mo + OpenAI usage** |

This is the recommended mode for development, demos, and the Colab
quickstart notebook.

### Mode B — Production with managed LLM (recommended for most teams)

Always-on, low-tail-latency, but inference billed per token through a
managed LLM API instead of paying for idle GPU.

| Item | GCP | AWS |
|---|---|---|
| Compute | Cloud Run, min instances = 1 | ECS Fargate 2 tasks |
| Vector DB | Qdrant on e2-medium | Qdrant on t3.medium |
| LLM | Gemini 2.5 Pro API | Amazon Bedrock (Claude Sonnet) or OpenAI |
| **Fixed infra estimate** | **~$50/mo** | **~$170/mo** |
| **LLM usage (10M tokens/mo)** | ~$10–$30 | ~$30–$80 |

### Mode C — Full enterprise mode (matches ARCHITECTURE.md)

Self-hosted 70B model on dedicated GPUs. Matches the ADR-001 "70%
self-hosted + 30% commercial" target.

| Item | GCP | AWS |
|---|---|---|
| Compute | GKE Autopilot + vLLM 8x A100 (custom) | SageMaker ml.p4d.24xlarge (8x A100) |
| Vector DB | Qdrant cluster | Qdrant cluster |
| Commercial fallback | Gemini Pro | OpenAI / Bedrock |
| **Fixed GPU cost** | **~$75K/mo** (A2-ultragpu-8g on-demand) | **~$23.5K/mo** (single p4d.24xlarge endpoint) |
| Mistral 7B (4x A10G/L4) | ~$25K/mo (g2-standard-48) | ~$4.1K/mo (ml.g5.12xlarge) |
| Commercial API | ~$50K/mo | ~$50K/mo |
| Other infra | ~$10K/mo | ~$10K/mo |
| **Monthly total** | **~$160K/mo** | **~$88K/mo** (single endpoint), ~$92K/mo with Mistral |

Notes:
- The GCP A2 8x A100 price (~$75K/mo on-demand) lines up closely with the
  $75K/mo figure quoted in `architecture/decisions/ADR-001-llm-selection.md`.
- AWS SageMaker is cheaper per-month because it's the managed price for the
  same hardware (~$32.77/hr × 24 × 30 = $23.6K) — the platform absorbs the
  orchestration overhead that you'd pay engineering time for on GKE.

---

## 3. Why the Two Implementations Diverge

The original ARCHITECTURE.md and ADRs were drafted against an AWS-EKS-with-vLLM
target ($100K/mo). The GCP reference is a **cost-optimised re-implementation**
that uses Gemini API and serverless ECS-equivalent (Cloud Run) to make the
project runnable for $0–$130/mo for dev work and demos. The AWS reference is
the **canonical implementation** of the ARCHITECTURE.md design, with the
following intentional substitution:

- **SageMaker replaces EKS+vLLM**: SageMaker uses the same `ml.p4d.24xlarge`
  hardware (8x A100 80GB) the docs specify, with HuggingFace's TGI container
  doing tensor parallelism. It avoids the operational complexity of running
  vLLM on EKS while preserving the model and hardware choice.

Both implementations:
- Use the same RAG pipeline code (`reference-implementation/python/src/rag/pipeline.py`).
- Use Qdrant for the vector store (same image, same client).
- Expose the same FastAPI surface (`/v1/chat`, `/v1/documents`, `/v1/retrieve`, `/health`).
- Apply the same guardrails (`reference-implementation/python/src/guardrails/safety.py`).

---

## 4. Sensitivity Analysis

### GPU instance type swap (AWS, full mode)

| Instance | GPUs | Cost / hr | Cost / month | Notes |
|---|---|---|---|---|
| ml.p4d.24xlarge | 8x A100 80GB | $32.77 | $23,594 | matches ARCHITECTURE.md spec |
| ml.p4de.24xlarge | 8x A100 80GB (more RAM) | $40.97 | $29,498 | longer-context use cases |
| ml.g5.48xlarge | 8x A10G 24GB | $16.29 | $11,729 | half the cost, slower; only fits Llama 3 70B with INT8 quantisation |
| ml.g5.12xlarge | 4x A10G 24GB | $5.67 | $4,082 | fits Llama 3 8B/13B or Mistral 7B |

### Reserved instance / Savings Plan

The SageMaker pricing above is on-demand. A 1-year Savings Plan cuts the rate
~30%; a 3-year SP cuts it ~50%. For production, expect:
- 1-yr SP, ml.p4d.24xlarge: ~$16.5K/mo
- 3-yr SP, ml.p4d.24xlarge: ~$11.7K/mo

This brings AWS full-mode total to ~$50K–60K/mo — closer to the
ADR-005 target of $150K/mo all-in.

---

## 5. Recommendations

| If you need... | Use... | Why |
|---|---|---|
| Free / minimal dev environment | GCP, Mode A, Colab notebook | Cloud Run scales to zero; Gemini has a free tier |
| Small-scale production (<1K users) | GCP Mode B, or AWS Mode B with Bedrock | Same architecture, no GPU bill |
| Data-residency-sensitive workloads | AWS Mode C (SageMaker in your own VPC) | Tokens never leave your account |
| Maximum throughput / lowest tail latency | AWS Mode C with Reserved/Spot mix | A100 tensor parallelism in TGI is hard to beat |
| Multi-region HA | AWS Mode C with Route 53 + endpoint replicas | SageMaker supports per-region endpoints; GCP equivalent requires multi-region Cloud Run |
