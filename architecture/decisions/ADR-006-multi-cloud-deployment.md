# ADR-006: Multi-Cloud Deployment (GCP + AWS)

**Status**: Accepted
**Date**: 2025-02-26
**Impact**: High — affects every infrastructure decision downstream
**Supersedes**: implicit single-cloud assumption in ADR-001..ADR-005

---

## Context

When the original architecture was drafted (ADR-001..ADR-005), the platform
was assumed to run on AWS EKS + self-hosted vLLM. The first delivered
reference implementation was GCP (Cloud Run + Gemini API), built to make
the project demonstrable for $0–$130/mo. This created two problems:

1. **Documentation drift**: ARCHITECTURE.md, ADRs, runbooks, and
   stakeholder materials still described AWS-only patterns (EKS,
   p4d.24xlarge, S3) while the only runnable code targeted GCP.
2. **Single-cloud lock-in narrative**: the project documents itself as a
   strategic enterprise platform, but a Fortune-500 enterprise rarely
   commits to one cloud — most run multi-cloud and require deployability
   flexibility.

The decision below resolves both.

---

## Decision

The project ships **two equally-supported reference implementations** of the
same architecture: GCP (Cloud Run + Gemini) and AWS (ECS Fargate +
SageMaker). Both:

- Use the same Python application codebase and the same RAG pipeline code
  under `reference-implementation/python/src/`, with cloud-specific
  Dockerfiles only where bootstrap dependencies differ.
- Provide an `LLMGateway` that registers cloud-appropriate providers at
  startup (Gemini + optional vLLM on GCP; SageMaker + optional OpenAI on
  AWS).
- Run Qdrant on a small VM as the vector store (e2-medium on GCP,
  t3.medium on AWS).
- Expose the identical FastAPI surface: `/v1/chat`, `/v1/documents`,
  `/v1/retrieve`, `/health`, `/metrics`.

The AWS implementation uses **Amazon SageMaker** for the self-hosted LLM
role instead of EKS + vLLM. SageMaker runs the same Llama 3 70B model on
the same `ml.p4d.24xlarge` (8x A100 80GB) hardware specified in ADR-001
and ARCHITECTURE.md, using HuggingFace's Text Generation Inference (TGI)
container — which provides PagedAttention, continuous batching, and tensor
parallelism equivalent to vLLM. SageMaker absorbs the autoscaling,
blue/green deployment, and CloudWatch integration that would otherwise be
operationalised through Kubernetes + Helm.

---

## Alternatives Considered

**Alternative 1: AWS-only, EKS + vLLM** (original implicit decision)
- ✅ **Pros**: Maximum control of inference stack; matches the as-written
  ARCHITECTURE.md.
- ❌ **Cons**: Operationally heavy (Helm charts, GPU operator, node-group
  management). High barrier to running the project end-to-end for
  demos/portfolio review. Single cloud.
- **Rejected**: too much operational burden for the demo value.

**Alternative 2: GCP-only**
- ✅ **Pros**: Cheapest demo path. Cloud Run + Gemini scales to zero.
- ❌ **Cons**: Architecture documents would need rewriting away from the
  Llama 3 70B / 8x A100 narrative. Loses the "enterprise self-host"
  story that ADR-001's cost case rests on.
- **Rejected**: undermines the architectural story.

**Alternative 3: AWS EKS + vLLM AND GCP Cloud Run + Gemini**
- ✅ **Pros**: True like-for-like with the original docs.
- ❌ **Cons**: vLLM on EKS is a significant time investment (Helm chart,
  node groups, HPA on custom metrics) for a reference project; SageMaker
  delivers the same outcome with one Terraform module.
- **Rejected**: same end-state, more code to maintain.

**Alternative 4 (chosen): AWS SageMaker + GCP Cloud Run/Gemini**
- ✅ **Pros**: Same Llama 3 70B on same hardware. SageMaker handles
  orchestration so the reference Terraform stays small and demonstrable.
  GCP path stays cheap for dev. Same Python code on both.
- ⚠️ **Cons**: SageMaker is a managed AWS service, so the platform is no
  longer "vendor-neutral all the way down to the inference engine". This
  is acceptable for this reference — production teams that need vendor
  neutrality at the inference layer can swap SageMaker for EKS + vLLM
  using the same Terraform module pattern.
- **Accepted**.

---

## Consequences

✅ The runnable code matches the architecture narrative.
✅ Stakeholders can pick a cloud based on existing footprint without code
   changes.
✅ Dev/demo cost stays near zero on GCP; full enterprise mode is achievable
   on AWS without writing EKS+vLLM glue.
✅ The same `/v1/chat` smoke test passes on both clouds — the platform is
   genuinely portable.

⚠️ Maintaining two Terraform stacks doubles the IaC surface area. Mitigated
   by sharing the Python code, Dockerfile-ish patterns, and Prometheus
   alert rules across both.
⚠️ SageMaker is AWS-proprietary. If the team later needs to leave AWS, the
   inference layer needs to be re-platformed (likely back to EKS+vLLM).
   Mitigated by keeping the `kubernetes/vllm/` manifests in the repo as an
   escape hatch.
⚠️ The cost figures in ADR-001 / ADR-005 still quote $75K/mo + $25K/mo for
   the GPU fleet, which assumed on-demand EKS pricing. On AWS SageMaker
   the same Llama 3 70B endpoint is ~$23.5K/mo on-demand. The cost
   conclusion (≥70% reduction vs $500K/mo commercial API spend) holds on
   either path. See `reference-implementation/docs/COST-MODEL.md` for the
   reconciled numbers.

---

## Implementation Pointers

- AWS Terraform: `reference-implementation/terraform/aws/`
- GCP Terraform: `reference-implementation/terraform/gcp/`
- SageMaker provider Python code: `reference-implementation/python/src/llm/sagemaker_provider.py`
- AWS deployment guide: `reference-implementation/docs/AWS_DEPLOYMENT.md`
- GCP deployment guide: `reference-implementation/docs/GCP_DEPLOYMENT.md`
- Cost reconciliation: `reference-implementation/docs/COST-MODEL.md`

---

## Status Updates

| Date | Note |
|---|---|
| 2025-02-26 | Initial decision. AWS Terraform stack landed alongside this ADR. |
