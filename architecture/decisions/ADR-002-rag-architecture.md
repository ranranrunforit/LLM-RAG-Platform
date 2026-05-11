# ADR-002: RAG Architecture (2-Stage Retrieval)

**Status**: Accepted
**Date**: 2024-01-15
**Impact**: High - Core capability for reducing hallucinations

---

## Context

**Problem**: LLMs hallucinate (15% error rate without grounding)

**Business Impact**:
- Users don't trust LLM outputs
- Cannot deploy to customer-facing applications
- Legal liability concerns

**Requirements**:
- Reduce hallucination rate to <5%
- Sub-200ms retrieval latency
- 1M+ documents in knowledge base
- Cite sources for auditability

---

## Decision

**2-Stage Retrieval Pipeline**:

### Stage 1: Vector Search (Fast, Broad Recall)
- **Tool**: Qdrant vector database
- **Embedding**: OpenAI text-embedding-3-large (3072 dimensions)
- **Index**: HNSW with scalar quantization
- **Output**: Top 100 candidates
- **Latency**: 45ms P95
- **Recall@100**: 95%

### Stage 2: Reranking (Slow, High Precision)
- **Tool**: Cross-Encoder (ms-marco-MiniLM)
- **Input**: Query + Top 100 candidates
- **Output**: Top 5 most relevant documents
- **Latency**: 95ms P95
- **Relevance**: 92% precision

### Total RAG Latency
- Embedding: 30ms
- Vector search: 45ms
- Reranking: 95ms
- Context construction: 5ms
- **Total: 175ms** (within 200ms budget)

---

## Alternatives Considered

**Alternative 1**: Single-Stage Vector Search Only
- ✅ **Pros**: Faster (50ms total), simpler
- ❌ **Cons**: 87% precision vs 92% with reranking
- **Decision**: ❌ Rejected - 5% accuracy improvement worth 95ms latency

**Alternative 2**: Keyword Search (Elasticsearch) Only
- ✅ **Pros**: Fast, exact match
- ❌ **Cons**: Misses semantic similarity ("refund" ≠ "return")
- **Decision**: ❌ Rejected - semantic search required

**Alternative 3**: Hybrid (Vector + Keyword) Fusion
- ✅ **Pros**: Best of both worlds
- ⚠️ **Cons**: More complexity
- **Decision**: ✅ Partially Accepted - implement as enhancement (5% further improvement)

**Alternative 4**: 3-Stage (Vector → Keyword → Rerank)
- ✅ **Pros**: Highest accuracy (94% precision)
- ❌ **Cons**: 250ms latency (exceeds budget)
- **Decision**: ❌ Rejected - diminishing returns (2% for 75ms)

---

## Consequences

✅ **Hallucination Reduction**: 15% → 3% (80% reduction)
✅ **Answer Accuracy**: 70% → 89%
✅ **User Trust**: Can cite sources
✅ **Latency**: 175ms (within 200ms budget)
⚠️ **Cost**: $3K/month for embedding API
⚠️ **Complexity**: 2-stage pipeline to maintain

**Validation**: A/B test showing 19% improvement in user satisfaction

---

**Approved By**: Cloud Architect, VP Product, Data Science Lead
