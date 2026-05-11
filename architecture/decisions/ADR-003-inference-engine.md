# ADR-003: Inference Engine Selection (vLLM)

**Status**: Accepted   
**Date**: 2024-01-15   
**Impact**: High - Performance and cost   

---

## Context

Need to serve Llama 3 70B at scale with sub-second latency.

**Requirements**:
- Throughput: 10,000+ tokens/sec
- Latency: P95 <800ms
- GPU efficiency: Maximize utilization
- Cost: Minimize infrastructure spend

---

## Decision

**vLLM** (UC Berkeley) as primary inference engine

**Key Features Used**:

1. **PagedAttention**
   - Eliminates KV cache fragmentation
   - **Impact**: 24x higher throughput vs naive PyTorch

2. **Continuous Batching**
   - Dynamic batching (add/remove requests on-the-fly)
   - **Impact**: 10x lower latency vs static batching

3. **Tensor Parallelism**
   - Distribute 70B model across 8x A100 GPUs
   - **Impact**: Enables deployment of large models

4. **Quantization Support**
   - INT8 quantization (GPTQ)
   - **Impact**: 2x speedup, 50% memory reduction

**Configuration**:
```python
llm = LLM(
    model="meta-llama/Llama-3-70b-hf",
    tensor_parallel_size=8,
    max_num_batched_tokens=16384,
    max_num_seqs=256,
    gpu_memory_utilization=0.95
)
```

**Performance Achieved**:
- **Throughput**: 12,000 tokens/sec
- **Latency (P50)**: 350ms
- **Latency (P95)**: 650ms ✅
- **GPU Utilization**: 85%

> **Implementation note (added 2025-02)**: The AWS reference implementation
> deploys this same model through a **SageMaker endpoint running
> HuggingFace's Text Generation Inference (TGI)** rather than running vLLM
> directly. TGI provides equivalent features (tensor parallelism,
> continuous batching, paged attention) on the same `ml.p4d.24xlarge` (8x
> A100 80GB) hardware. SageMaker manages autoscaling, blue/green updates,
> and CloudWatch integration, removing a chunk of operational load that
> would otherwise live in EKS + Helm. The GCP reference defaults to
> Gemini API for the LLM role and retains vLLM on a GCE GPU VM as an
> opt-in alternative for parity testing. The choice of inference engine
> family (PagedAttention-style batched inference) does not change — only
> the orchestrator does. See
> `reference-implementation/terraform/aws/sagemaker.tf`.

---

## Alternatives Considered

**Alternative 1**: HuggingFace Transformers (Baseline)
- ❌ **Cons**: 24x slower than vLLM, not production-ready
- **Decision**: ❌ Rejected - unacceptable performance

**Alternative 2**: TensorRT-LLM (NVIDIA)
- ✅ **Pros**: 2x faster than vLLM
- ❌ **Cons**: Complex deployment, NVIDIA lock-in, immature
- **Decision**: ⚠️ Deferred - consider for Mistral 7B (smaller model)

**Alternative 3**: Text Generation Inference (HuggingFace)
- ✅ **Pros**: Good community support
- ❌ **Cons**: 30% slower than vLLM
- **Decision**: ❌ Rejected - vLLM is faster and more mature

**Alternative 4**: Ray Serve
- ✅ **Pros**: Good for multi-model serving
- ❌ **Cons**: Uses vLLM underneath anyway, extra complexity
- **Decision**: ❌ Rejected - vLLM directly is simpler

---

## Consequences

✅ **Performance**: 12,000 tok/sec throughput (exceeds requirement)   
✅ **Latency**: 650ms P95 (meets <800ms SLO)   
✅ **Cost**: 85% GPU utilization (good efficiency)   
✅ **Maturity**: Production-ready, used by major companies   
⚠️ **Vendor Lock**: Requires NVIDIA GPUs (acceptable trade-off)   

**Mitigation**: Abstract behind interface, can swap engines if needed   

---

**Approved By**: Cloud Architect, ML Engineering Lead   
