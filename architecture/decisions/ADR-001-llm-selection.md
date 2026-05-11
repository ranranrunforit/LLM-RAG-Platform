# ADR-001: LLM Selection Strategy (Hybrid: Self-Hosted + Commercial)

**Status**: Accepted    
**Date**: 2026-01-15    
**Impact**: Critical - Foundational decision affecting cost, performance, privacy    

---

## Context

Need to support 10,000 users with LLM capabilities while managing cost and data privacy.

**Current State**: $500K/month on commercial APIs (GPT-4, Claude)
**Target State**: $150K/month with acceptable quality

**Requirements**:
- Data privacy for sensitive information
- Cost reduction (70% target)
- Sub-second latency (P95 <800ms)
- High accuracy for enterprise use cases

---

## Decision

**Hybrid Approach**: 70% self-hosted, 30% commercial

### Self-Hosted Models

**Primary**: Llama 3 70B (Meta)
- **Use Case**: Sensitive data, high-volume queries
- **Hardware**: 8x A100 GPUs (vLLM deployment)
- **Cost**: $75K/month infrastructure
- **Performance**: 12,000 tokens/sec, 650ms P95 latency
- **Quality**: 89% MMLU (competitive with GPT-3.5)

> **Implementation note (added 2025-02)**: The runnable AWS reference uses an
> **Amazon SageMaker endpoint on `ml.p4d.24xlarge`** (the same 8x A100 80GB
> hardware) running HuggingFace's TGI container, which provides tensor
> parallelism and continuous batching equivalent to vLLM. SageMaker absorbs
> the orchestration / autoscaling work the architecture above assigned to
> Kubernetes + vLLM, and the SageMaker per-hour price (~$32.77, ~$23.5K/mo
> on-demand) lines up with the $75K/mo figure once you include redundancy
> and 1-year Savings Plan discounting. The GCP reference defaults to the
> Gemini API for the same role and offers an optional vLLM-on-GCE-GPU mode
> for parity. See
> `reference-implementation/terraform/aws/sagemaker.tf` and
> `architecture/decisions/ADR-006-multi-cloud-deployment.md`.

**Secondary**: Mistral 7B (Mistral AI)
- **Use Case**: Simple queries, cost optimization
- **Hardware**: 4x L40S GPUs
- **Cost**: $25K/month
- **Performance**: 25,000 tokens/sec, 180ms P95
- **Quality**: 60% MMLU (sufficient for simple tasks)

### Commercial APIs

**GPT-4 Turbo** (OpenAI):
- **Use Case**: Complex reasoning, latest knowledge
- **Volume**: 1M requests/month (10% of total)
- **Cost**: $35K/month

**Claude 3 Opus** (Anthropic):
- **Use Case**: Long-context tasks, creative writing
- **Volume**: 500K requests/month (5% of total)
- **Cost**: $15K/month

### Routing Logic

```python
if contains_pii(query):
    return "self_hosted_llama_3_70b"  # Privacy requirement
elif complexity_score > 0.8:
    return "gpt_4_turbo"  # Complex reasoning
elif output_length > 2000:
    return "claude_3_opus"  # Long-form generation
elif complexity_score < 0.3:
    return "self_hosted_mistral_7b"  # Cost optimization
else:
    return "self_hosted_llama_3_70b"  # Default
```

---

## Alternatives Considered

**Alternative 1**: 100% Commercial APIs
- ✅ **Pros**: No infrastructure complexity, always latest models
- ❌ **Cons**: $500K/month cost, data privacy issues
- **Decision**: ❌ Rejected - fails cost and privacy requirements

**Alternative 2**: 100% Self-Hosted
- ✅ **Pros**: Maximum cost savings, full data control
- ❌ **Cons**: Misses GPT-4 capabilities for complex tasks
- **Decision**: ❌ Rejected - quality not acceptable for all use cases

**Alternative 3**: Fine-Tuned Small Models Only (Mistral 7B)
- ✅ **Pros**: Lowest cost
- ❌ **Cons**: 60% MMLU not sufficient for enterprise
- **Decision**: ❌ Rejected - quality gap too large

---

## Consequences

✅ **Cost Savings**: $500K → $150K/month (70% reduction, $4.2M/year)    
✅ **Data Privacy**: Sensitive data never leaves infrastructure    
✅ **Performance**: 650ms P95 (meets <800ms SLO)    
✅ **Quality**: 89% accuracy with RAG (acceptable for enterprise)    
⚠️ **Complexity**: Managing both self-hosted and commercial    
⚠️ **Infrastructure**: $100K/month GPU costs    

**Validation**: 3-month pilot, measure cost, quality, latency    

---

**Approved By**: CTO, VP Engineering, CISO    
