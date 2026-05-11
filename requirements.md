# LLM Platform with RAG — Detailed Requirements

## Executive Summary

TechCorp needs to take 10,000+ internal users off third-party LLM APIs and onto
a hybrid (self-hosted + commercial) platform that grounds answers in
proprietary knowledge via Retrieval-Augmented Generation, while reducing
spend by ≥70% and unblocking compliance-sensitive use cases. The platform
must deploy unchanged to either of TechCorp's two clouds (AWS production,
GCP for ML/data).

The architecture, ADRs, and runnable code live alongside this document; see
[ARCHITECTURE.md](./ARCHITECTURE.md) and
[reference-implementation/](./reference-implementation/).

## Business Context

### Company Overview

**TechCorp** is a Fortune 500 company with:
- **Industry**: Multi-line technology (SaaS + on-prem product portfolio)
- **Size**: 50,000+ employees globally
- **Revenue**: $10B+ annually
- **ML maturity**: Production ML in fraud, personalisation, and search; LLM
  usage is ad-hoc — ~30 teams calling commercial APIs directly with no
  central platform, governance, or cost visibility.

### Business Drivers

1. **Cost crisis** — $500K/month and growing on commercial LLM APIs (GPT-4,
   Claude); projected $12M/year run-rate by end of next FY if unchanged.
2. **Compliance blockade** — Legal has blocked ~40% of requested LLM use
   cases because tokens cannot leave TechCorp's tenancy boundary; sensitive
   workloads (legal review, customer PII, payroll) cannot use commercial APIs.
3. **Quality / trust** — 15% hallucination rate without RAG, which keeps the
   platform out of customer-facing applications and drives constant fact-
   checking overhead for internal users.
4. **Innovation velocity** — Competitors are shipping LLM-powered features
   ~3× faster because they have a central platform; TechCorp engineers wait
   weeks for one-off vendor approvals.

### Success Metrics

- **LLM unit cost**: ≤ $0.005/request blended (vs ~$0.05/request today on
  GPT-4) — measured monthly via cloud cost reports.
- **Adoption**: 10,000 monthly active internal users by end of Year 1; 5
  pilot teams live by Month 6.
- **RAG accuracy**: ≥ 85% on the internal QA evaluation set (vs ~70% with
  raw LLM, no grounding).
- **ROI**: Break-even within Year 1; $64.6M net value over 3 years (see
  [business/business-case.md](./business/business-case.md)).
- **Compliance posture**: SOC 2 Type II ready by Month 9; zero PII-leak
  incidents.

## Stakeholder Analysis

### Key Stakeholders

| Stakeholder | Role | Primary concerns | Hard requirements |
|---|---|---|---|
| CTO | Executive sponsor | Strategic alignment, time to value | Productionised platform by month 12 |
| VP Engineering | Technical owner | Reliability, scalability | 99.9% uptime, multi-cloud deployable |
| CISO | Security lead | Data residency, audit, threat model | TLS 1.3, AES-256 at rest, audit logs ≥ 2 yr, PII redaction |
| CFO | Budget owner | TCO, predictability | $8M Year-1 capital, ≤ $2M/yr ongoing, ≤ 10% monthly variance |
| Legal / Compliance | Risk owner | Tokens-in-tenancy, GDPR/CCPA/AI-Act | Self-hosted path for sensitive workloads; human-in-loop for high-risk |
| Data Science Platform | Power user | Model choice, throughput | Multiple model backends, batch + streaming |
| Customer Support | Pilot user | Quality, latency | <800ms P95, source citations |

### Communication Plan

- **Steering committee** (CTO, CFO, VP Eng, CISO, VP Product): monthly review.
- **Engineering working group**: weekly architecture and on-call review.
- **Security review**: bi-weekly during build, monthly after GA.
- **Finance**: monthly cost variance report (target <10%).

## Functional Requirements

### FR-1: Hybrid LLM routing

**Description**: The platform must transparently route each request to the
right LLM — self-hosted for sensitive data, commercial API for complex
reasoning — without callers having to specify the backend.

**Acceptance criteria**:
- [ ] Requests flagged as containing PII are guaranteed to be served by a
      self-hosted model (vLLM or SageMaker), verified by an automated test.
- [ ] A complexity heuristic (or explicit `llm_backend` override) can route
      non-sensitive requests to GPT-4 / Claude / Gemini.
- [ ] Caller API is unchanged regardless of which backend served the request.

**Priority**: Must have.
**Dependencies**: ADR-001 (LLM Selection), [`reference-implementation/python/src/llm/gateway.py`](./reference-implementation/python/src/llm/gateway.py).
**User stories**:
1. As a customer-support engineer, I want answers to never include PII sent
   to an external API, so that we stay GDPR-compliant by default.
2. As a data scientist, I want to opt into GPT-4 for a complex query, so
   that I can get the best reasoning when I know the data is non-sensitive.

### FR-2: RAG over enterprise knowledge

**Description**: The platform must ground answers in TechCorp's internal
corpus (Confluence, SharePoint, code repos, Zendesk) and cite sources.

**Acceptance criteria**:
- [ ] 2-stage retrieval (dense vector + cross-encoder rerank) implemented
      against a Qdrant collection of at least 1M documents.
- [ ] End-to-end answer includes source document IDs in the response payload.
- [ ] Document-level ACLs are enforced at query time (a user only sees
      chunks from documents they're authorised for).

**Priority**: Must have.
**Dependencies**: ADR-002 (RAG Architecture).

### FR-3: Safety guardrails

**Description**: The platform must detect and block PII leaks, prompt
injection, jailbreak attempts, and toxic output before they reach the LLM
(input side) or the caller (output side).

**Acceptance criteria**:
- [ ] PII detector recognises SSN, credit card, email, phone, address with
      ≥ 95% recall on the internal benchmark set.
- [ ] Prompt-injection rules catch the OWASP LLM Top-10 patterns.
- [ ] Output filter rejects responses scoring ≥ 0.8 on toxicity.
- [ ] All safety verdicts emit Prometheus counters labelled by violation
      type and risk level.

**Priority**: Must have.
**Dependencies**: ADR-004 (Safety Guardrails).

### FR-4: REST API surface

**Description**: All capabilities are exposed over a versioned REST API
authenticated by an API key.

**Acceptance criteria**:
- [ ] `POST /v1/chat` runs the full RAG flow and returns answer + sources.
- [ ] `POST /v1/documents` ingests + chunks + embeds + indexes documents.
- [ ] `POST /v1/retrieve` returns retrieval results without LLM generation
      (used for debugging and integration testing).
- [ ] `GET /health` reports per-component status (Qdrant, LLM gateway,
      available backends, model in use).
- [ ] `GET /metrics` exposes Prometheus scrape format.

**Priority**: Must have.

### FR-5: Multi-cloud deployable

**Description**: The same application image and the same RAG pipeline must
run on either AWS or GCP without cloud-specific changes to the core
business logic.

**Acceptance criteria**:
- [ ] One reference Terraform stack each for AWS and GCP, both producing a
      green `/health` and a passing `POST /v1/chat` round trip.
- [ ] LLM Gateway abstracts each cloud's preferred backend (Gemini on GCP,
      SageMaker on AWS) behind a uniform Provider interface.
- [ ] Documented cost model showing the per-cloud price points
      ([reference-implementation/docs/COST-MODEL.md](./reference-implementation/docs/COST-MODEL.md)).

**Priority**: Must have.
**Dependencies**: ADR-006 (Multi-cloud Deployment).

### FR-6: Caching

**Description**: Repeated or semantically similar prompts must hit a cache
to reduce LLM spend.

**Acceptance criteria**:
- [ ] Prompt-exact cache with ≥ 15% hit rate after stabilisation.
- [ ] Semantic cache (embedding similarity ≥ 0.95) layered on top.

**Priority**: Should have (Phase 2).

### FR-7: Audit logging

**Description**: Every request must be logged with enough detail to
reconstruct what the model saw and produced.

**Acceptance criteria**:
- [ ] Log entry per request: user_id, query, retrieved_doc_ids, model_used,
      safety verdict, latency, cost.
- [ ] Logs retained ≥ 2 years (compliance).
- [ ] Logs queryable for incident response within 5 minutes.

**Priority**: Must have (Compliance gate for GA).

### FR-8: Cost telemetry

**Description**: Per-team and per-use-case cost attribution.

**Acceptance criteria**:
- [ ] Each request carries an attribution label (team / use case).
- [ ] Monthly cost-by-team dashboard.

**Priority**: Should have.

### FR-9: Human-in-the-loop for high-risk use cases

**Description**: Use cases classified as high-risk (finance, legal, medical)
require human approval before delivery.

**Acceptance criteria**:
- [ ] Per-use-case risk classification.
- [ ] High-risk responses queue to a review UI; LLM output is not returned
      to the end user until a reviewer signs off.

**Priority**: Should have (Phase 3).

### FR-10: Model lifecycle

**Description**: Operators can roll out new model versions without downtime.

**Acceptance criteria**:
- [ ] Blue/green deploy for SageMaker endpoint configs.
- [ ] Rolling deploy for the API tier (ECS Fargate / Cloud Run native).

**Priority**: Must have.

## Non-Functional Requirements

### Performance

**NFR-P1: Latency**
- **Requirement**: P95 end-to-end < 800 ms for `/v1/chat`; P50 < 400 ms.
- **Measurement**: Prometheus histogram `rag_query_duration_seconds`.
- **Validation**: Synthetic load test before each release; production
  dashboard reviewed weekly.

**NFR-P2: Throughput**
- **Requirement**: Sustain 10,000 req/sec at peak; absorb 3× burst for 5 min.
- **Measurement**: ALB / Cloud Run request count metric.
- **Validation**: Load test at 2× expected peak in pre-prod.

**NFR-P3: Resource utilisation**
- **Requirement**: API CPU < 70%, GPU > 80% utilisation under steady load.
- **Measurement**: CloudWatch / Cloud Monitoring.

### Scalability

**NFR-S1: Horizontal scaling**
- **Requirement**: Scale API tier from 2 to 10 replicas (matches the HPA
  pattern in ARCHITECTURE.md §Scalability).
- **Trigger**: CPU > 70% or P95 latency > 600 ms.
- **Approach**: ECS Service Auto Scaling (AWS) / Cloud Run autoscaler (GCP).

**NFR-S2: Data volume**
- **Requirement**: Handle 10M documents (≈ 50 GiB after chunking + embedding).
- **Growth**: 30% YoY.
- **Approach**: Qdrant HNSW with scalar quantization; sharding when single-
  node exceeds 30 GiB index.

### Availability

**NFR-A1: Uptime**
- **Requirement**: 99.9% monthly (≤ 43.2 minutes downtime).
- **Measurement**: Synthetic probe + ALB target health.
- **Validation**: Quarterly SLA review.

**NFR-A2: Disaster recovery**
- **RPO**: ≤ 24 h (S3/GCS versioning + nightly Qdrant snapshot).
- **RTO**: ≤ 4 h (re-run `terraform apply` against a clean region; restore
  Qdrant snapshot).

**NFR-A3: Fault tolerance**
- **Requirement**: No single point of failure in the API or vector tier.
- **Approach**: ≥ 2 API replicas behind ALB / Cloud Run native LB; multi-AZ
  subnets; PodDisruptionBudget on EKS path.

### Security

**NFR-SEC1: Authentication and authorisation**
- API-key auth at the edge (sufficient for internal use); OIDC/SAML SSO via
  the company's identity provider for the future web UI.
- Document-level RBAC at retrieval time (see FR-2).

**NFR-SEC2: Data encryption**
- **At rest**: AES-256 — KMS-encrypted EBS for Qdrant, default SSE for S3,
  Google-managed keys for GCS, Secrets Manager / Secret Manager for keys.
- **In transit**: TLS 1.3 between caller and ALB / Cloud Run; ECS task →
  SageMaker / Qdrant kept inside the private VPC.

**NFR-SEC3: Network security**
- ECS tasks live in private subnets, egress only through NAT.
- Qdrant SG allows ingress only from the ECS task SG on 6333/6334.
- SageMaker is invoked over the VPC's AWS PrivateLink-compatible endpoint.

**NFR-SEC4: Audit and logging**
- All API requests, safety verdicts, and model invocations land in
  CloudWatch / Cloud Logging.
- Retention 2 years (compliance).

### Compliance

**NFR-C1: GDPR / CCPA**
- Right to explanation: store query + retrieved docs for 30 days.
- Right to deletion: documented user-data deletion workflow.

**NFR-C2: SOC 2 Type II**
- Access reviews quarterly, change-management evidence captured in Git, IR
  playbook tested annually.

**NFR-C3: EU AI Act high-risk systems**
- Human-in-the-loop for finance, legal, and medical use cases (FR-9).

### Cost

**NFR-COST1: Capital expenditure**
- **Budget**: $8M over Year 1 (build team, GPU reservations, infra).

**NFR-COST2: Operating expenditure**
- **Budget**: ≤ $2M/year after Year 1.
- **Target**: ≥ 70% reduction vs the $500K/month commercial-API baseline.

**NFR-COST3: Cost predictability**
- Monthly variance ≤ 10% via SageMaker Savings Plans / GCP committed-use
  discounts and Spot for non-critical batch.

### Usability

**NFR-U1: Developer experience**
- A new team integrates with the API in < 1 day (self-service API key +
  Python/REST samples).
- Local dev path with `docker compose up` and a Colab notebook for zero-
  cost experimentation.

**NFR-U2: Operations**
- Runbook + dashboards for every alert; on-call resolves typical incidents
  without escalation in < 30 min.
- ≥ 90% of operational tasks automated (Terraform-managed).

## Constraints

### Technical

1. **Clouds**: AWS (production) and GCP (ML / data) are first-class targets;
   Azure is not in scope for this iteration.
2. **Orchestration**: AWS path uses ECS Fargate (EKS optional); GCP path
   uses Cloud Run; both share the same container image.
3. **Inference engine**: Self-hosted Llama 3 70B runs on `ml.p4d.24xlarge`
   (AWS SageMaker / HuggingFace TGI) or 8× A100 (GCP A2 / vLLM).
4. **Vector DB**: Qdrant. (Alternative considered: pgvector, Pinecone — see
   ADR-002.)
5. **Compliance**: GDPR, CCPA, SOC 2 Type II, EU AI Act for high-risk uses.
6. **Integration**: Confluence, SharePoint, GitHub, Zendesk; Slack/Teams
   front-ends in Phase 3.

### Organisational

1. **Timeline**: MVP at Month 6 (pilot teams), GA at Month 12.
2. **Team**: 10 engineers (4 infra, 3 ML, 2 backend, 1 security).
3. **Skills assumption**: Existing in-house Terraform/Python/K8s expertise;
   SageMaker familiarity will be ramped in Months 1–2.
4. **Process**: All changes via PR with CODEOWNERS review and CI gate.

### Financial

1. **Capital budget**: $8M Year 1.
2. **Operating budget**: ≤ $2M / year ongoing.
3. **ROI requirement**: Break-even ≤ 11 months (per business case).

## Assumptions

1. **Llama 3 licence is acceptable** for TechCorp's commercial use — Legal
   has reviewed and approved. *Impact if invalid*: revert to Mistral or
   commercial-only routing; cost model shifts.
2. **SageMaker `ml.p4d.24xlarge` quota** is approvable in our chosen region
   within 2 weeks. *Impact*: schedule slip in Phase 1.
3. **Internal knowledge corpora are crawlable** through their existing APIs
   (Confluence, SharePoint, Zendesk, GitHub). *Impact*: connector work
   becomes the long pole.
4. **10,000-user target traffic profile** (~ 4 req/sec average, 12 req/sec
   peak) holds within ±50%. *Impact*: GPU fleet sizing needs revisiting.
5. **Hybrid 70/30 routing** is achievable without per-team manual
   classification, using a complexity heuristic + PII detector. *Impact*: if
   not, fall back to opt-in commercial routing and accept higher cost.

## Risks

| Risk | Impact | Probability | Mitigation |
|---|---|---|---|
| GPU quota denied or delayed (p4d) | High | Medium | Submit request Day 1; fall back to `ml.g5.48xlarge` (cheaper, slower) as Plan B; document downgrade in ADR-001. |
| Llama 3 licence interpretation changes | High | Low | Maintain Mistral 7B as a fully-Apache-2.0 alternative; keep prompts model-agnostic. |
| Hallucination not adequately reduced by RAG | Medium | Medium | Multi-stage retrieval + reranker (ADR-002); regression suite of high-stakes prompts; mandatory citations. |
| Cost overrun on SageMaker | High | Medium | Default `enable_sagemaker = false` in Terraform; CloudWatch budget alarm at 80% of monthly cap; nightly endpoint pause runbook. |
| Vendor lock-in (SageMaker / Gemini) | Medium | High | Same Python code on both clouds; `kubernetes/vllm/` manifests retained as portable escape hatch (ADR-006). |
| Single-AZ Qdrant data loss | Medium | Low | Daily EBS snapshot via AWS Backup; document re-index path from S3 source-of-truth. |
| Compliance review delays GA | Medium | Medium | Engage CISO Month 1; iterate audit logging design before code freeze. |

## Out of Scope

For this iteration of the platform:

1. **Multimodal inputs** (images, audio) — RAG over text-only knowledge first.
2. **End-user web UI** — REST API only; UI work is a follow-on project.
3. **Fine-tuning pipeline** — Use base Llama 3 / Mistral; LoRA workflow
   deferred to Phase 4.
4. **Cross-region active-active** — Multi-region DR is in scope; active-
   active load balancing is not.
5. **Azure deployment** — May be added later; not in the Year-1 plan.
6. **Streaming responses** (`text/event-stream`) — Phase 2 nice-to-have.

## Requirements Traceability

| Requirement | Business driver | Architecture component | Verification |
|---|---|---|---|
| FR-1 | Cost crisis, compliance blockade | `src/llm/gateway.py`, ADR-001 | Unit test on `route_by_sensitivity`; integration smoke test |
| FR-2 | Quality / trust | `src/rag/pipeline.py`, ADR-002 | RAG accuracy benchmark (≥ 85%) |
| FR-3 | Compliance, brand safety | `src/guardrails/safety.py`, ADR-004 | Guardrails unit suite, OWASP LLM Top-10 fixture |
| FR-4 | Innovation velocity | `src/api/main.py` | OpenAPI conformance test; smoke test in each deployment runbook |
| FR-5 | Multi-cloud constraint | `terraform/aws/`, `terraform/gcp/`, ADR-006 | Green `/health` on both clouds during release gate |
| FR-7 | SOC 2 | CloudWatch / Cloud Logging integration | Audit-log retention audit |
| FR-10 | Operational requirement | ECS rolling deploy, SageMaker blue/green | Pre-prod rollout drill |
| NFR-P1 | UX, business expectation | API tier sizing, vLLM/TGI tuning | Load test report |
| NFR-S1 | 10K-user growth | Auto Scaling target | Load test at peak × 3 |
| NFR-SEC2 | Security baseline | KMS-encrypted EBS, TLS 1.3 ALB listener | Security audit |

## Acceptance Criteria

The solution is considered complete when:

- [ ] All Must-have FRs (FR-1, FR-2, FR-3, FR-4, FR-5, FR-7, FR-10) are
      implemented and have passing automated tests.
- [ ] All NFRs are validated by load test, security audit, and the SLO
      dashboard, with results captured in `runbooks/`.
- [ ] Both reference deployments (AWS and GCP) reach green `/health` and a
      passing `/v1/chat` smoke test in CI.
- [ ] ADR-001 through ADR-006 are merged, peer-reviewed, and dated.
- [ ] Stakeholder materials match the as-built implementation (no claims of
      AWS-only or Llama-only that the code does not support).
- [ ] Pilot teams (5) onboarded, with documented usage telemetry.
- [ ] Cost model within the $8M / $2M envelope, validated against the first
      month of real billing.
- [ ] Handoff to the on-call rotation completed (runbooks rehearsed).

## Appendices

### Appendix A: Use cases (priority order)

1. **Customer support FAQ assistant** — RAG over Zendesk + support KB.
2. **Internal code assistant** — RAG over enterprise GitHub.
3. **Document Q&A for ops** — RAG over Confluence + SharePoint.
4. **Sales engineering proposal helper** — RAG over win/loss library.
5. **Legal document review (human-in-loop)** — RAG over contract templates.

### Appendix B: Data sources and connectors

| Source | Volume | Refresh | Connector |
|---|---|---|---|
| Confluence | ~50K pages | Real-time + nightly | Confluence REST API |
| SharePoint | ~200K docs | Nightly | Microsoft Graph |
| Zendesk | ~1M tickets | Nightly | Zendesk API |
| GitHub (enterprise) | ~10K repos | Webhook | GitHub App |
| Internal wikis (Notion) | ~5K pages | Nightly | Notion API |

### Appendix C: External integrations

- Identity: Okta (SAML / OIDC) — for the future web UI.
- Observability: Prometheus + Grafana (self-hosted) + cloud-native metrics
  (CloudWatch / Cloud Monitoring).
- Alerting: PagerDuty for sev1/sev2; Slack for sev3.

### Appendix D: Glossary

| Term | Definition |
|---|---|
| RAG | Retrieval-Augmented Generation. |
| HNSW | Hierarchical Navigable Small World — the index Qdrant uses. |
| TGI | HuggingFace Text Generation Inference — the inference container AWS SageMaker uses for Llama 3 70B in this project. |
| vLLM | High-throughput LLM serving library (PagedAttention + continuous batching) used on the GCP/EKS path. |
| Self-hosted | Inference runs inside TechCorp's cloud account — tokens never leave the tenancy. Covers both vLLM on GKE/EKS and SageMaker endpoints. |
| IRSA | IAM Roles for Service Accounts — the EKS pattern for granting pod-level AWS permissions. |
| Workload Identity | GCP equivalent of IRSA. |

---

**Next step**: Review these requirements, then read [ARCHITECTURE.md](./ARCHITECTURE.md)
for the design and [reference-implementation/README.md](./reference-implementation/README.md)
for the runnable code.
