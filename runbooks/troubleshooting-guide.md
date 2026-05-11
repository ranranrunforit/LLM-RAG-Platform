# Troubleshooting Guide: LLM Platform with RAG

**Version**: 1.0  
**Last Updated**: 2026-01-15  

---

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Common Issues](#common-issues)
3. [Performance Issues](#performance-issues)
4. [GPU Problems](#gpu-problems)
5. [Network Issues](#network-issues)
6. [Data Issues](#data-issues)
7. [Safety/Security Issues](#safetysecurity-issues)
8. [Emergency Procedures](#emergency-procedures)

---

## Quick Diagnostics

### Health Check Commands

```bash
# Overall system status
kubectl get pods -n llm-inference
kubectl top nodes
kubectl top pods -n llm-inference

# vLLM service health
curl http://vllm-llama-3-70b/health

# GPU status
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi

# Prometheus alerts
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
curl http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'
```

### Log Locations

```bash
# vLLM logs
kubectl logs -f deployment/vllm-llama-3-70b -n llm-inference -c vllm-server

# GPU metrics logs
kubectl logs -f deployment/vllm-llama-3-70b -n llm-inference -c metrics-exporter

# RAG service logs
kubectl logs -f deployment/rag-service -n llm-inference

# CloudWatch Logs
aws logs tail /aws/eks/llm-platform-production/cluster --follow
```

---

## Common Issues

### Issue 1: Pods Stuck in Pending

**Symptoms**:
```
NAME                             READY   STATUS    RESTARTS   AGE
vllm-llama-3-70b-abc123-xyz     0/2     Pending   0          5m
```

**Diagnosis**:
```bash
kubectl describe pod vllm-llama-3-70b-abc123-xyz -n llm-inference | grep -A 10 Events
```

**Common Causes**:

#### Cause 1.1: Insufficient GPU Resources
**Error**: `0/3 nodes are available: insufficient nvidia.com/gpu`

**Solution**:
```bash
# Check GPU availability
kubectl describe nodes | grep -A 5 "nvidia.com/gpu"

# Scale up node group
aws eks update-nodegroup-config \
  --cluster-name llm-platform-production \
  --nodegroup-name a100-node-group \
  --scaling-config desiredSize=3

# Wait for new node
kubectl get nodes -w
```

#### Cause 1.2: Node Taints Not Tolerated
**Error**: `0/3 nodes are available: 3 node(s) had taint that the pod didn't tolerate`

**Solution**:
```bash
# Verify pod has GPU toleration
kubectl get pod vllm-llama-3-70b-abc123-xyz -n llm-inference -o yaml | grep -A 5 tolerations

# If missing, add toleration:
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Add:
# tolerations:
# - key: nvidia.com/gpu
#   operator: Equal
#   value: "true"
#   effect: NoSchedule
```

#### Cause 1.3: PVC Not Bound
**Error**: `pod has unbound immediate PersistentVolumeClaims`

**Solution**:
```bash
# Check PVC status
kubectl get pvc -n llm-inference

# If pending, check storage class
kubectl get storageclass

# Manually create PV if needed
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: model-storage-pv
spec:
  capacity:
    storage: 200Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  ...
EOF
```

---

### Issue 2: High Latency (P95 > 2s)

**Symptoms**:
- Prometheus alert: `HighLLMLatency`
- User complaints about slow responses
- Grafana dashboard shows red latency

**Diagnosis**:
```bash
# Check current latency
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
curl 'http://localhost:9090/api/v1/query?query=llm:request_duration_seconds:p95' | jq

# Check queue length
curl 'http://localhost:8000/metrics' | grep vllm_num_requests_waiting

# Check GPU utilization
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi
```

**Common Causes**:

#### Cause 2.1: High Queue Length
**Symptoms**: `vllm_num_requests_waiting > 50`

**Solution 1**: Scale horizontally
```bash
# Increase replicas
kubectl scale deployment vllm-llama-3-70b --replicas=4 -n llm-inference

# Or update HPA max replicas
kubectl edit hpa vllm-llama-3-70b-hpa -n llm-inference
# Change maxReplicas: 6
```

**Solution 2**: Optimize batch size
```bash
# Increase max-num-seqs for higher throughput
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Change: --max-num-seqs=512 (from 256)
kubectl rollout restart deployment/vllm-llama-3-70b -n llm-inference
```

#### Cause 2.2: Cold Start
**Symptoms**: First request after idle period is slow (10-20s)

**Solution**: Implement request warmer
```bash
# Deploy cron job to send periodic requests
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vllm-warmer
  namespace: llm-inference
spec:
  schedule: "*/5 * * * *"  # Every 5 minutes
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: curl
            image: curlimages/curl:latest
            command:
            - curl
            - -X
            - POST
            - http://vllm-llama-3-70b/v1/chat/completions
            - -H
            - "Content-Type: application/json"
            - -d
            - '{"model":"llama-3-70b","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
          restartPolicy: OnFailure
EOF
```

#### Cause 2.3: Slow Model Loading
**Symptoms**: Pods take 15+ minutes to become ready

**Solution**: Use model caching
```bash
# Create persistent volume for model cache
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache-pvc
  namespace: llm-inference
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 200Gi
EOF

# Update deployment to use PVC instead of emptyDir
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Change volume from emptyDir to persistentVolumeClaim
```

---

### Issue 3: GPU Not Detected

**Symptoms**:
```
Error: RuntimeError: No CUDA GPUs are available
```

**Diagnosis**:
```bash
# Check if GPU device plugin is running
kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system

# Check node has GPU label
kubectl get nodes --show-labels | grep nvidia.com/gpu

# SSH into node and check NVIDIA driver
kubectl debug node/<node-name> -it --image=ubuntu
chroot /host
nvidia-smi
```

**Common Causes**:

#### Cause 3.1: Device Plugin Not Running
**Solution**:
```bash
# Restart device plugin daemonset
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n kube-system

# Check logs
kubectl logs -f daemonset/nvidia-device-plugin-daemonset -n kube-system
```

#### Cause 3.2: CUDA Driver Mismatch
**Symptoms**: `CUDA driver version is insufficient for CUDA runtime version`

**Solution**:
```bash
# Check versions
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi

# If mismatch, update node AMI
# 1. Drain node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Update launch template with latest EKS GPU AMI
aws eks describe-addon-versions \
  --kubernetes-version 1.28 \
  --addon-name nvidia-device-plugin

# 3. Terminate instance (ASG will create new one)
aws ec2 terminate-instances --instance-ids <instance-id>
```

#### Cause 3.3: GPU in Use by Another Process
**Solution**:
```bash
# Find process using GPU
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi

# Kill zombie processes
kubectl exec -it <vllm-pod> -n llm-inference -- pkill -9 python

# Restart pod
kubectl delete pod <vllm-pod> -n llm-inference
```

---

### Issue 4: Out of Memory (OOM)

**Symptoms**:
```
OOMKilled
Exit Code: 137
```

**Diagnosis**:
```bash
# Check pod memory usage
kubectl top pod vllm-llama-3-70b-abc123-xyz -n llm-inference

# Check GPU memory
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi

# Check OOM events
kubectl get events -n llm-inference | grep OOM
```

**Solutions**:

#### Solution 4.1: Increase Memory Limits
```bash
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Change:
# resources:
#   limits:
#     memory: "1000Gi"  # Increase from 800Gi
```

#### Solution 4.2: Reduce Batch Size
```bash
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Change:
# - --max-num-batched-tokens=8192  # Reduce from 16384
# - --max-num-seqs=128              # Reduce from 256
```

#### Solution 4.3: Reduce GPU Memory Utilization
```bash
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Change:
# - --gpu-memory-utilization=0.85  # Reduce from 0.95
```

---

### Issue 5: RAG Returns No Results

**Symptoms**:
- Query returns: "I couldn't find any relevant information"
- No documents retrieved

**Diagnosis**:
```bash
# Check if documents are indexed
kubectl port-forward svc/qdrant 6333:6333 -n llm-inference &
curl http://localhost:6333/collections/enterprise_knowledge

# Check vector count
curl http://localhost:6333/collections/enterprise_knowledge/points/count

# Test query directly
curl -X POST http://localhost:6333/collections/enterprise_knowledge/points/search \
  -H "Content-Type: application/json" \
  -d '{"vector": [0.1, 0.2, ...], "limit": 10}'
```

**Solutions**:

#### Solution 5.1: No Documents Indexed
```bash
# Index sample documents
kubectl exec -it <rag-service-pod> -n llm-inference -- python -c "
from src.rag.pipeline import RAGPipeline, Document, RAGConfig
import asyncio

async def index():
    pipeline = RAGPipeline(RAGConfig())
    docs = [
        Document(id='doc1', text='Sample document', metadata={})
    ]
    await pipeline.add_documents(docs)

asyncio.run(index())
"
```

#### Solution 5.2: Embedding Model Not Loaded
```bash
# Check logs for embedding errors
kubectl logs -f deployment/rag-service -n llm-inference | grep embedding

# Restart service
kubectl rollout restart deployment/rag-service -n llm-inference
```

#### Solution 5.3: Low Relevance Threshold
```bash
# Lower min_relevance_score
kubectl edit configmap rag-config -n llm-inference
# Change: min_relevance_score: 0.5  # From 0.7
kubectl rollout restart deployment/rag-service -n llm-inference
```

---

## Performance Issues

### Low Throughput (<100 req/s)

**Diagnosis**:
```bash
# Check current throughput
curl 'http://localhost:9090/api/v1/query?query=llm:throughput:requests_per_second' | jq

# Check bottleneck
kubectl top pods -n llm-inference
```

**Solutions**:
1. Enable continuous batching (should be default)
2. Increase `--max-num-seqs`
3. Add more replicas
4. Use smaller model for simple queries (routing logic)

---

## GPU Problems

### GPU Utilization Low (<50%)

**Symptoms**: GPUs underutilized, but latency still high

**Diagnosis**:
```bash
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi dmon -s u
```

**Causes**:
1. **CPU bottleneck**: Increase CPU allocation
2. **Memory bandwidth**: Check `nvidia-smi dmon -s m`
3. **PCIe bottleneck**: Verify NVLink is active

**Solutions**:
```bash
# Enable NVLink
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi nvlink -s

# If disabled, check NCCL configuration
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Add env:
# - name: NCCL_P2P_LEVEL
#   value: "NVL"
```

---

## Network Issues

### Cannot Connect to vLLM Service

**Diagnosis**:
```bash
# Check service
kubectl get svc vllm-llama-3-70b -n llm-inference

# Check endpoints
kubectl get endpoints vllm-llama-3-70b -n llm-inference

# Test connectivity from another pod
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://vllm-llama-3-70b.llm-inference.svc.cluster.local/health
```

**Solutions**:
1. Check NetworkPolicies: `kubectl get networkpolicies -n llm-inference`
2. Verify service selector matches pod labels
3. Check load balancer health

---

## Safety/Security Issues

### High PII Detection Rate

**Symptoms**: Prometheus alert `HighSafetyViolationRate` for PII

**Diagnosis**:
```bash
# Check violation rate
curl 'http://localhost:9090/api/v1/query?query=rate(guardrails_violations_total{violation_type="pii"}[5m])'

# Check logs for patterns
kubectl logs -f deployment/rag-service -n llm-inference | grep "PII detected"
```

**Solutions**:
1. **Expected**: If users are querying sensitive data, this is working as intended
2. **False positives**: Tune PII detection thresholds
3. **User education**: Inform users not to include PII in queries

---

### Prompt Injection Detected

**Symptoms**: Users getting "prompt injection detected" errors

**Diagnosis**:
```bash
# Check blocked patterns
kubectl logs -f deployment/rag-service -n llm-inference | grep "Prompt injection"
```

**Solutions**:
1. **True positive**: Block is working correctly
2. **False positive**: Review and update regex patterns in `safety.py`

---

## Emergency Procedures

### Emergency Shutdown

```bash
# Scale down all services (stops cost)
kubectl scale deployment --all --replicas=0 -n llm-inference

# Stop node groups
for ng in a100-node-group l40s-node-group; do
  aws eks update-nodegroup-config \
    --cluster-name llm-platform-production \
    --nodegroup-name $ng \
    --scaling-config minSize=0,maxSize=0,desiredSize=0
done
```

### Disaster Recovery

**Scenario**: Entire cluster lost

```bash
# 1. Restore from Terraform state
cd terraform/environments/production
terraform init
terraform apply

# 2. Restore from EBS snapshots
aws ec2 describe-snapshots --owner-id self \
  --filters "Name=tag:Purpose,Values=model-storage"

# 3. Redeploy services
kubectl apply -f kubernetes/vllm/
kubectl apply -f kubernetes/rag-pipeline/
```

---

## Escalation

**L1 (Operator)**: Use this runbook
**L2 (Engineer)**: Modify configurations, scale resources
**L3 (Architect)**: Infrastructure changes, code fixes

**Contact**:
- Slack: #llm-platform-oncall
- PagerDuty: Escalate to "LLM Platform - Critical"
- Email: llm-platform-oncall@company.com

---

## Useful Commands Reference

```bash
# Quick health check
kubectl get pods -n llm-inference && kubectl top nodes

# Tail all logs
kubectl logs -f -l app=vllm -n llm-inference --all-containers=true

# Restart all services
kubectl rollout restart deployment -n llm-inference

# Emergency scale down
kubectl scale deployment --all --replicas=0 -n llm-inference

# Drain node for maintenance
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Get GPU metrics
kubectl exec -it <vllm-pod> -n llm-inference -- nvidia-smi dmon -s pucvmet -c 10
```

---

**Last Updated**: 2026-01-15  
**Maintained By**: AI Infrastructure Team  
