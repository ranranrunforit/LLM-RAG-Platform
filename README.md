# LLM Platform with RAG

**Duration**: 90 hours | **Difficulty**: Very High | **Project ID**: project-303-llm-rag-platform   

**Stack:** vLLM, RAG, Qdrant Vector DB, Terraform, Kubernetes, Prometheus, Grafana, Docker, AWS EKS, GCP GKE

## Overview

A reference enterprise LLM platform with Retrieval-Augmented Generation
(RAG), demonstrating how to design, build, and operate an LLM service that
serves 10,000+ internal users at sub-second latency while keeping cost,
data privacy, and safety under control.

The project ships with **two runnable reference implementations** that
deploy the same RAG pipeline and FastAPI surface to different clouds:

- **GCP** — Cloud Run + Gemini API + Qdrant on GCE (cost-optimised, ~$0–$130/mo)
- **AWS** — ECS Fargate + SageMaker (Llama 3 70B on ml.p4d.24xlarge) + Qdrant on EC2

See [`reference-implementation/README.md`](./reference-implementation/README.md)
for the runnable code and [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the
design narrative.

## Learning Objectives

1. Apply enterprise architecture frameworks to a real LLM platform problem
2. Document architecture using ADRs, executive briefs, and technical deep dives
3. Design for scalability, security, cost, and responsible-AI constraints
4. Communicate trade-offs to executive and engineering audiences
5. Translate a documented design into runnable infrastructure on more than
   one cloud and verify the result

## Key Deliverables

- LLM platform architecture with hybrid self-hosted + commercial routing
- 2-stage RAG pipeline (dense retrieval + cross-encoder reranking)
- Multi-layer safety guardrails (PII, prompt injection, content moderation)
- Multi-cloud reference implementation (GCP + AWS) with Terraform, Kubernetes,
  and a single Python codebase that runs on both
- Architecture Decision Records, business case, governance framework,
  and stakeholder presentations

## Project Scenario

### Context

You are the AI Infrastructure Architect at **TechCorp**, a Fortune 500
company undergoing digital transformation. The organisation currently:

- Spends **~$500K/month on commercial LLM APIs** (GPT-4, Claude) for ~10,000
  internal users — translating to $6M/year and growing.
- Cannot send proprietary data to those APIs, so Legal has blocked roughly
  40% of the use cases the business wants to ship.
- Sees a 15% hallucination rate without RAG, which keeps the platform out
  of customer-facing applications.
- Operates a multi-cloud footprint (AWS production, GCP for ML/data
  workloads) and needs the LLM platform to be deployable to either.

### Your Mission

Design and deliver an LLM platform that meets the requirements below while
optimising for cost, performance, and safety.

## Requirements

### Functional Requirements

1. **FR-1 — Hybrid LLM routing**: route requests to a self-hosted model for
   sensitive data and to a commercial API for complex reasoning, transparently
   to the caller.
2. **FR-2 — RAG over enterprise knowledge**: ground answers in an internal
   corpus (Confluence, SharePoint, code repos, support tickets) with source
   citations.
3. **FR-3 — Safety guardrails**: detect and block PII leaks, prompt
   injection, jailbreak attempts, and toxic output.
4. **FR-4 — REST API**: expose chat, document ingestion, and retrieval-only
   endpoints with API-key auth and Prometheus metrics.
5. **FR-5 — Multi-cloud deployable**: the same application codebase and API
   surface must run on GCP and AWS without cloud-specific changes to the core
   business logic.

### Non-Functional Requirements

1. **Performance**: P95 latency < 800ms end-to-end; sustain 10,000 req/sec at peak.
2. **Scalability**: scale from 2 to 10 replicas based on CPU / GPU utilisation.
3. **Security**: TLS 1.3 in transit, AES-256 at rest, document-level ACLs,
   audit logs retained 2 years, SOC 2 Type II ready.
4. **Cost**: reduce monthly LLM spend by ≥70% vs the $500K/month baseline.
5. **Availability**: 99.9% monthly SLA.

### Constraints

- **Budget**: $8M Year-1 capital + ~$2M/year operating after Year 1.
- **Timeline**: 6 months to MVP, 12 months to full enterprise rollout.
- **Compliance**: GDPR, CCPA, SOC 2; AI-Act high-risk-system controls for
  finance / legal use cases.
- **Integration**: must work with the existing AWS account (production
  workloads) and GCP project (data / ML).

## Project Structure

```
project-303-llm-rag-platform/
├── README.md                            # This file
├── requirements.md                      # Full requirements + RTM
├── ARCHITECTURE.md                      # Architecture narrative
│
├── architecture/
│   └── decisions/                       # ADR-001..ADR-006
│
├── business/
│   └── business-case.md                 # NPV / ROI model
│
├── governance/
│   └── llm-governance-framework.md      # Responsible AI policy
│
├── runbooks/
│   ├── deployment-guide.md              # Cloud-agnostic ops overview
│   ├── deployment-guide-aws.md          # AWS day-2 ops
│   ├── operations-manual.md
│   └── troubleshooting-guide.md
│
├── stakeholder-materials/
│   ├── executive-presentation.md
│   └── technical-deep-dive.md
│
└── reference-implementation/            # Runnable code (see its README)
    ├── terraform/{gcp,aws,modules}/
    ├── kubernetes/{gcp,aws,vllm}/
    ├── python/                          # Shared FastAPI + RAG + guardrails
    ├── monitoring/prometheus/
    └── docs/{GCP_DEPLOYMENT,AWS_DEPLOYMENT,COST-MODEL}.md
```

## Getting Started

1. Read [`requirements.md`](./requirements.md) and
   [`ARCHITECTURE.md`](./ARCHITECTURE.md).
2. Walk through the ADRs in [`architecture/decisions/`](./architecture/decisions/).
3. Pick a cloud and follow the deployment guide:
   - GCP: [`reference-implementation/docs/GCP_DEPLOYMENT.md`](./reference-implementation/docs/GCP_DEPLOYMENT.md)
   - AWS: [`reference-implementation/docs/AWS_DEPLOYMENT.md`](./reference-implementation/docs/AWS_DEPLOYMENT.md)
4. Compare cost trade-offs in [`reference-implementation/docs/COST-MODEL.md`](./reference-implementation/docs/COST-MODEL.md).

## Assessment Rubric

### Architecture Quality (40%)

- **Completeness**: all FR / NFR requirements addressed.
- **Soundness**: appropriate patterns; trade-offs documented in ADRs.
- **Scalability**: design and code both demonstrate the 10x growth path.
- **Security**: encryption, RBAC, audit logging, ACL-aware retrieval.
- **Cost-effectiveness**: budget honoured; cost model evidence-based.

### Documentation (30%)

- Clear narrative documents (README, ARCHITECTURE).
- Six ADRs covering the load-bearing decisions.
- Stakeholder-specific materials (exec deck + technical deep dive).
- Up-to-date deployment guides for each supported cloud.

### Strategic Thinking (20%)

- Business case with NPV / ROI.
- Multi-cloud strategy with clear motivation.
- Risk register + mitigations.
- Trade-off analysis (vLLM vs SageMaker, in-house vs commercial, etc.).

### Implementation Planning (10%)

- Phased roadmap.
- Resource estimates.
- Measurable success metrics.

## Success Criteria

- ✅ All FR / NFR requirements satisfied in design and code.
- ✅ Six ADRs published, including the multi-cloud rationale.
- ✅ Both clouds reach a green `/health` and complete a `/v1/chat` round trip.
- ✅ Cost model within the $8M Year-1 + $2M/yr operating envelope.
- ✅ Stakeholder materials internally consistent and aligned with the code.

## Timeline

- **Week 1–2**: Requirements + ADRs draft
- **Week 3–6**: Architecture design + GCP reference build
- **Week 7–8**: AWS reference build + cost modelling
- **Week 9–10**: Governance + runbooks + stakeholder materials
- **Week 11**: Presentation and iteration   

## Next Steps

1. Read [requirements.md](./requirements.md) thoroughly.
2. Skim [ARCHITECTURE.md](./ARCHITECTURE.md).
3. Pick a cloud and run through one deployment guide end-to-end.
4. Iterate.
