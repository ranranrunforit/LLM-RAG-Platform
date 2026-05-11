# ADR-005: Cost Optimization Strategy

**Status**: Accepted
**Date**: 2024-01-15
**Impact**: Critical - $4.2M/year savings target

---

## Context

**Current Baseline**: $500K/month (100% commercial APIs)
**Target**: $150K/month (70% reduction)
**Constraint**: Maintain quality and performance

---

## Decision

**5-Pronged Optimization Strategy**:

### 1. Hybrid Deployment (Self-Hosted + Commercial)

**Self-Hosted** (70% of requests):
- Llama 3 70B: $75K/month (8x A100)
- Mistral 7B: $25K/month (4x L40S)
- Total: $100K/month infrastructure
- Cost per request: $0.002

**Commercial** (30% of requests):
- GPT-4: $35K/month (1M requests)
- Claude: $15K/month (500K requests)
- Cost per request: $0.033

**Blended Cost**: $0.005/request (vs $0.05 baseline)
**Savings**: $350K/month

### 2. Intelligent Request Routing

```python
def route_by_cost(query):
    """Route to cheapest model meeting quality requirements"""

    if complexity < 0.3:
        return "mistral-7b"  # $0.001/request

    elif complexity < 0.7:
        return "llama-3-70b"  # $0.002/request

    else:
        return "gpt-4"  # $0.035/request

# Distribution: 30% Mistral, 40% Llama, 30% GPT-4
# Savings: $20K/month vs routing all to Llama 3
```

### 3. Multi-Level Caching

**L1: Prompt Cache** (Redis, exact match):
- Hit rate: 15%
- TTL: 1 hour
- Savings: $20K/month

**L2: Semantic Cache** (Vector DB, similarity >0.95):
- Hit rate: 25%
- TTL: 24 hours
- Savings: $30K/month

**L3: KV Cache** (vLLM, prefix reuse):
- Hit rate: 60% (system prompt reused)
- Savings: 40% compute reduction

**Total Cache Savings**: $50K/month + 40% compute reduction

### 4. Prompt Compression

**Technique**: Summarize retrieved context before LLM
- Before: 3,000 tokens/request
- After: 2,000 tokens/request
- Reduction: 33%
- **Savings**: $30K/month

### 5. Batch Processing

**Non-Real-Time Requests** (weekly reports, analytics):
- Run overnight in batch mode
- Use spot instances (70% discount)
- **Savings**: $10K/month

---

## Cost Breakdown

| Strategy | Monthly Savings |
|----------|-----------------|
| Hybrid deployment | $350K |
| Intelligent routing | $20K |
| Caching | $50K |
| Prompt compression | $30K |
| Batch processing | $10K |
| **Total** | **$460K** |

**Actual Target**: $350K savings (from $500K to $150K)
**Headroom**: $110K (allows for optimization tuning)

---

## Alternatives Considered

**Alternative 1**: 100% Self-Hosted (Maximum Savings)
- ✅ **Savings**: $450K/month
- ❌ **Quality**: Misses GPT-4 for complex tasks
- **Decision**: ❌ Rejected - quality gap unacceptable

**Alternative 2**: Smaller Models Only (Mistral 7B)
- ✅ **Savings**: $480K/month
- ❌ **Quality**: 60% MMLU insufficient
- **Decision**: ❌ Rejected - fails quality requirements

**Alternative 3**: Serverless (AWS Lambda, modal.com)
- ✅ **Pros**: Pay-per-use, no idle cost
- ❌ **Cons**: Cold start latency (5+ seconds), more expensive at scale
- **Decision**: ❌ Rejected - latency and cost worse at our scale

---

## Consequences

✅ **Savings**: $4.2M/year (70% reduction)
✅ **Quality**: Maintained (89% accuracy with RAG)
✅ **Performance**: 650ms P95 (within SLO)
⚠️ **Complexity**: Managing 5 optimization strategies
⚠️ **Monitoring**: Need detailed cost tracking per request

**Validation**: Monthly FinOps review, cost per request tracking

---

**Approved By**: CFO, CTO, VP Engineering
