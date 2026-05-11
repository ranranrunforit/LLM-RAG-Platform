# ADR-004: Safety and Guardrails Framework

**Status**: Accepted
**Date**: 2024-01-15
**Impact**: Critical - Regulatory compliance, brand risk

---

## Context

**Risks**:
- Toxic/offensive outputs damage brand
- PII leakage violates GDPR/CCPA
- Hallucinations cause user harm (medical, legal, financial)
- Jailbreaks bypass content policies
- Bias in outputs leads to discrimination claims

**Requirements**:
- Block toxic content (100% recall for high-severity)
- Detect and redact PII (99%+ accuracy)
- Prevent hallucinations (<5% rate)
- Stop jailbreak attempts (95%+ detection)

---

## Decision

**Multi-Layered Defense-in-Depth**:

### Layer 1: Input Validation (Pre-LLM)

**PII Detection** (Presidio):
- Detects: SSN, credit cards, emails, phone numbers
- Action: Redact or reject request
- Latency: 15ms

**Jailbreak Detection** (Custom Classifier):
- Training data: 10K jailbreak examples
- Model: Fine-tuned BERT
- Accuracy: 95% F1 score
- Action: Reject request, log incident

**Prompt Injection Detection**:
- Pattern matching + classifier
- Examples: "Ignore previous instructions", "You are now..."
- Action: Reject request

### Layer 2: Guardrails (During Inference)

**NeMo Guardrails** (NVIDIA):
```python
rails = Rails(
    config={
        "rails": {
            "input": [
                {"type": "jailbreak_check"},
                {"type": "topic_boundary", "allowed_topics": ["company_policies"]}
            ],
            "output": [
                {"type": "factuality_check", "sources": "retrieved_docs"},
                {"type": "hallucination_detection"}
            ]
        }
    }
)
```

**Hallucination Detection**:
- Compare LLM output to retrieved documents
- Flag if output contains info not in context
- Action: Regenerate with stricter instructions

### Layer 3: Output Filtering (Post-LLM)

**Toxicity Detection** (Perspective API):
- Threshold: >0.8 toxicity score
- Action: Reject output, log incident
- Latency: 25ms

**Bias Detection** (Custom Classifier):
- Detects: Gender, racial, age bias
- Training: Bias benchmarks (BOLD, StereoSet)
- Action: Flag for review (production), reject (beta)

**Total Safety Latency**: 65ms (15+25+25)

---

## Alternatives Considered

**Alternative 1**: OpenAI Moderation API Only
- ✅ **Pros**: Easy to use
- ❌ **Cons**: Sends data to OpenAI (privacy issue), English only
- **Decision**: ❌ Rejected - use for non-sensitive data only

**Alternative 2**: LlamaGuard (Meta)
- ✅ **Pros**: Self-hosted, multi-lingual
- ⚠️ **Cons**: Slower (200ms), newer/less proven
- **Decision**: ⚠️ Pilot for future adoption

**Alternative 3**: No Guardrails (Trust LLM Fine-Tuning)
- ❌ **Cons**: Unacceptable risk (jailbreaks always possible)
- **Decision**: ❌ Rejected - defense-in-depth required

---

## Consequences

✅ **Safety**: 99.5% toxic content blocked
✅ **Privacy**: 99% PII detection accuracy
✅ **Hallucination**: 15% → 3% rate
✅ **Compliance**: Meets GDPR, SOC 2 requirements
⚠️ **Latency**: +65ms overhead (acceptable, within budget)
⚠️ **False Positives**: 2% of safe requests blocked (tuning needed)

**Validation**: Monthly red-team exercises, quarterly audits

---

**Approved By**: CISO, Legal, VP Product
