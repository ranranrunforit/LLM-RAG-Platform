# Deployment Guide: Enterprise LLM Platform with RAG

**Version**: 1.0
**Last Updated**: 2025-01-15
**Estimated Time**: 4-6 hours
**Difficulty**: Advanced

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Pre-Deployment Checklist](#pre-deployment-checklist)
3. [Phase 1: Infrastructure Deployment](#phase-1-infrastructure-deployment)
4. [Phase 2: LLM Service Deployment](#phase-2-llm-service-deployment)
5. [Phase 3: RAG Pipeline Deployment](#phase-3-rag-pipeline-deployment)
6. [Phase 4: Monitoring Setup](#phase-4-monitoring-setup)
7. [Phase 5: Validation](#phase-5-validation)
8. [Rollback Procedures](#rollback-procedures)
9. [Post-Deployment](#post-deployment)

---

## Prerequisites

### Access Requirements
- [ ] AWS account access with Administrator permissions
- [ ] GPU quotas approved:
  - `p4d.24xlarge`: 2 instances (16 A100 GPUs)
  - `g5.12xlarge`: 1 instance (4 A10G GPUs)
- [ ] S3 bucket access for model storage
- [ ] ECR repository access
- [ ] GitHub/GitLab access for code

### Tools Required
```bash
# Verify tool versions
terraform version   # >= 1.5.0
kubectl version     # >= 1.28.0
aws --version       # >= 2.13.0
docker --version    # >= 24.0.0
helm version        # >= 3.12.0
python3 --version   # >= 3.11
```

### Cost Budget Approval
- Initial: $110K/month infrastructure
- Ongoing: $150K/month (includes API costs)
- Total Year 1: $1.8M

### Model Files
- [ ] Llama 3 70B weights downloaded (140GB)
- [ ] Mistral 7B weights downloaded (14GB)
- [ ] Uploaded to S3: `s3://my-company-llm-models/`

---

## Pre-Deployment Checklist

### 1. Request GPU Quotas (2-3 weeks lead time)

```bash
# Check current quotas
aws service-quotas list-service-quotas \
  --service-code ec2 \
  --query 'Quotas[?QuotaName contains `p4d`]'

# Request quota increase
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-417A185B \
  --desired-value 2
```

### 2. Download Model Weights

```bash
# Llama 3 70B (requires Meta approval)
git clone https://huggingface.co/meta-llama/Meta-Llama-3-70B
cd Meta-Llama-3-70B

# Upload to S3
aws s3 sync . s3://my-company-llm-models/llama-3-70b/ \
  --exclude "*.git*" \
  --storage-class INTELLIGENT_TIERING

# Mistral 7B
git clone https://huggingface.co/mistralai/Mistral-7B-v0.1
cd Mistral-7B-v0.1
aws s3 sync . s3://my-company-llm-models/mistral-7b/
```

### 3. Configure AWS Credentials

```bash
# Configure AWS CLI
aws configure --profile llm-platform

# Set environment
export AWS_PROFILE=llm-platform
export AWS_REGION=us-west-2
```

### 4. Clone Repository

```bash
git clone https://github.com/company/llm-platform.git
cd llm-platform/project-303-llm-rag-platform
```

---

## Phase 1: Infrastructure Deployment

**Duration**: 45-60 minutes
**Objective**: Deploy EKS cluster with GPU nodes

### Step 1.1: Initialize Terraform

```bash
cd reference-implementation/terraform/environments/production

# Initialize
terraform init

# Validate configuration
terraform validate
```

**Expected Output**:
```
Success! The configuration is valid.
```

### Step 1.2: Review Plan

```bash
# Generate plan
terraform plan -out=tfplan

# Review resources (should show ~50 resources)
terraform show -json tfplan | jq '.resource_changes | length'
```

**Key Resources**:
- VPC with 6 subnets (3 public, 3 private)
- EKS cluster (v1.28)
- 2x A100 node groups
- 1x L40S node group
- S3 buckets (models, logs)
- IAM roles and policies
- Security groups

### Step 1.3: Apply Infrastructure

```bash
# Apply (takes 30-45 minutes)
terraform apply tfplan

# Save outputs
terraform output -json > outputs.json
```

**Critical Outputs**:
```json
{
  "cluster_endpoint": "https://ABC123.gr7.us-west-2.eks.amazonaws.com",
  "cluster_name": "llm-platform-production",
  "a100_node_group_id": "...",
  "l40s_node_group_id": "..."
}
```

### Step 1.4: Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig \
  --name llm-platform-production \
  --region us-west-2

# Verify connection
kubectl get nodes

# Expected: 3 nodes (2 A100, 1 L40S)
```

**Verify Node Labels**:
```bash
kubectl get nodes --show-labels | grep gpu-type
```

Expected output:
```
ip-10-0-1-100   Ready   <none>   5m   gpu-type=a100
ip-10-0-1-101   Ready   <none>   5m   gpu-type=a100
ip-10-0-2-100   Ready   <none>   5m   gpu-type=l40s
```

### Step 1.5: Install NVIDIA Device Plugin

```bash
# Deploy GPU device plugin (already in Terraform, verify)
kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system

# Verify GPUs are detected
kubectl describe node <a100-node-name> | grep nvidia.com/gpu
```

Expected:
```
nvidia.com/gpu: 8
nvidia.com/gpu: 8
```

---

## Phase 2: LLM Service Deployment

**Duration**: 60-90 minutes
**Objective**: Deploy vLLM with Llama 3 70B and Mistral 7B

### Step 2.1: Create Namespace

```bash
kubectl create namespace llm-inference

# Create service account with IRSA
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: llm-inference-sa
  namespace: llm-inference
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/llm-inference-s3-role
EOF
```

### Step 2.2: Create ConfigMap

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: llm-config
  namespace: llm-inference
data:
  model_bucket: "my-company-llm-models"
  aws_region: "us-west-2"
  llama_70b_path: "llama-3-70b"
  mistral_7b_path: "mistral-7b"
EOF
```

### Step 2.3: Deploy vLLM for Llama 3 70B

```bash
# Deploy
kubectl apply -f reference-implementation/kubernetes/vllm/llama-3-70b-deployment.yaml

# Monitor deployment (model download takes 15-20 minutes)
kubectl get pods -n llm-inference -w

# Check init container logs (model download)
kubectl logs -f vllm-llama-3-70b-<pod-id> -n llm-inference -c model-downloader
```

**Expected Progress**:
```
Downloading Llama 3 70B model from S3...
download: s3://my-company-llm-models/llama-3-70b/pytorch_model-00001-of-00015.bin
...
Model download complete (140GB)
```

### Step 2.4: Wait for Readiness

```bash
# Wait for pods to be ready (10-15 minutes after model download)
kubectl wait --for=condition=ready pod \
  -l app=vllm,model=llama-3-70b \
  -n llm-inference \
  --timeout=30m

# Check pod status
kubectl get pods -n llm-inference -l model=llama-3-70b
```

Expected output:
```
NAME                               READY   STATUS    RESTARTS   AGE
vllm-llama-3-70b-5d9c4b6f7-abcde  2/2     Running   0          25m
vllm-llama-3-70b-5d9c4b6f7-fghij  2/2     Running   0          25m
```

### Step 2.5: Verify vLLM Health

```bash
# Port-forward for testing
kubectl port-forward svc/vllm-llama-3-70b 8000:80 -n llm-inference &

# Health check
curl http://localhost:8000/health

# Expected: {"status": "ok"}

# Test inference
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3-70b",
    "messages": [{"role": "user", "content": "Hello, what is 2+2?"}],
    "temperature": 0.7,
    "max_tokens": 50
  }'
```

**Expected Response**:
```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "created": 1705334400,
  "model": "llama-3-70b",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "2 + 2 equals 4."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 8,
    "total_tokens": 20
  }
}
```

### Step 2.6: Deploy Mistral 7B (Optional)

```bash
kubectl apply -f reference-implementation/kubernetes/vllm/mistral-7b-deployment.yaml
```

---

## Phase 3: RAG Pipeline Deployment

**Duration**: 30-45 minutes
**Objective**: Deploy vector database and RAG service

### Step 3.1: Deploy Qdrant (Vector Database)

```bash
# Deploy Qdrant
kubectl apply -f reference-implementation/kubernetes/vector-db/qdrant-deployment.yaml

# Wait for readiness
kubectl wait --for=condition=ready pod \
  -l app=qdrant \
  -n llm-inference \
  --timeout=5m

# Verify
kubectl get svc qdrant -n llm-inference
```

### Step 3.2: Build RAG Service Image

```bash
cd reference-implementation/python

# Build Docker image
docker build -t rag-service:1.0 -f Dockerfile .

# Tag for ECR
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="$ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/rag-service"
docker tag rag-service:1.0 $ECR_REPO:1.0
docker tag rag-service:1.0 $ECR_REPO:latest

# Push to ECR
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin $ECR_REPO
docker push $ECR_REPO:1.0
docker push $ECR_REPO:latest
```

### Step 3.3: Deploy RAG Service

```bash
# Update image in deployment manifest
sed -i "s|<account-id>|$ACCOUNT_ID|g" \
  reference-implementation/kubernetes/rag-pipeline/rag-service-deployment.yaml

# Deploy
kubectl apply -f reference-implementation/kubernetes/rag-pipeline/rag-service-deployment.yaml

# Wait for readiness
kubectl wait --for=condition=ready pod \
  -l app=rag-service \
  -n llm-inference \
  --timeout=5m
```

### Step 3.4: Index Sample Documents

```bash
# Port-forward RAG service
kubectl port-forward svc/rag-service 8080:80 -n llm-inference &

# Index documents
curl -X POST http://localhost:8080/v1/documents \
  -H "Content-Type: application/json" \
  -d '{
    "documents": [
      {
        "id": "doc1",
        "text": "Machine learning is a subset of artificial intelligence...",
        "metadata": {"source": "ML Handbook", "chapter": 1}
      }
    ]
  }'
```

### Step 3.5: Test RAG Query

```bash
# Query
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What is machine learning?",
    "return_sources": true
  }'
```

**Expected Response**:
```json
{
  "answer": "Machine learning is a subset of artificial intelligence that...",
  "model": "llama-3-70b",
  "latency_ms": 1250,
  "sources": [...]
}
```

---

## Phase 4: Monitoring Setup

**Duration**: 30 minutes

### Step 4.1: Deploy Prometheus

```bash
# Add Prometheus Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install Prometheus
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values reference-implementation/monitoring/prometheus/values.yaml

# Wait for deployment
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n monitoring \
  --timeout=5m
```

### Step 4.2: Apply Custom Rules

```bash
kubectl apply -f reference-implementation/monitoring/prometheus/llm-rules.yaml
```

### Step 4.3: Access Grafana

```bash
# Get Grafana password
kubectl get secret prometheus-grafana \
  -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode
echo

# Port-forward
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring &

# Open browser: http://localhost:3000
# Username: admin
# Password: <from above>
```

### Step 4.4: Import Dashboards

1. Navigate to Dashboards → Import
2. Upload dashboards from `reference-implementation/monitoring/grafana/`
3. Select Prometheus data source
4. Import

---

## Phase 5: Validation

### 5.1: Smoke Tests

```bash
# Run test suite
cd reference-implementation/python
pytest tests/integration/test_deployment.py -v
```

### 5.2: Performance Tests

```bash
# Load test (requires locust)
locust -f tests/load/locustfile.py \
  --host=http://localhost:8000 \
  --users=100 \
  --spawn-rate=10 \
  --run-time=5m
```

**Success Criteria**:
- ✅ P95 latency < 800ms
- ✅ Throughput > 100 req/sec
- ✅ Error rate < 1%
- ✅ GPU utilization 60-80%

### 5.3: Safety Tests

```bash
# Test PII detection
curl -X POST http://localhost:8080/v1/query \
  -H "Content-Type: application/json" \
  -d '{"query": "My SSN is 123-45-6789"}'

# Should return error: PII detected
```

---

## Rollback Procedures

### Rollback Kubernetes Deployment

```bash
# Check deployment history
kubectl rollout history deployment/vllm-llama-3-70b -n llm-inference

# Rollback to previous version
kubectl rollout undo deployment/vllm-llama-3-70b -n llm-inference

# Rollback to specific revision
kubectl rollout undo deployment/vllm-llama-3-70b \
  -n llm-inference \
  --to-revision=2
```

### Rollback Terraform

```bash
cd reference-implementation/terraform/environments/production

# Revert to previous state
terraform state pull > current-state.json
cp terraform.tfstate.backup terraform.tfstate
terraform plan
terraform apply
```

### Emergency Shutdown

```bash
# Scale down all deployments
kubectl scale deployment --all --replicas=0 -n llm-inference

# Stop node groups (saves cost)
aws eks update-nodegroup-config \
  --cluster-name llm-platform-production \
  --nodegroup-name a100-node-group \
  --scaling-config minSize=0,maxSize=0,desiredSize=0
```

---

## Post-Deployment

### 1. Update Documentation

- [ ] Update runbook with any deviations
- [ ] Document custom configurations
- [ ] Update architecture diagrams

### 2. Enable Backups

```bash
# Enable EBS snapshots
aws dlm create-lifecycle-policy \
  --execution-role-arn arn:aws:iam::ACCOUNT:role/DLMRole \
  --description "Daily EBS snapshots" \
  --state ENABLED \
  --policy-details file://backup-policy.json
```

### 3. Set Up Alerts

- [ ] Configure PagerDuty integration
- [ ] Set up Slack notifications
- [ ] Test alert routing

### 4. Team Training

- [ ] Schedule runbook walkthrough
- [ ] Assign on-call rotation
- [ ] Share access credentials (1Password/Vault)

### 5. Go-Live Checklist

- [ ] Load balancer DNS updated
- [ ] Monitoring dashboards shared
- [ ] Incident response process documented
- [ ] Stakeholders notified

---

## Troubleshooting

See [troubleshooting-guide.md](./troubleshooting-guide.md) for common issues.

**Quick Fixes**:

**Problem**: Pods stuck in Pending
**Solution**: Check GPU availability
```bash
kubectl describe pod <pod-name> -n llm-inference | grep -A 5 Events
```

**Problem**: Model download timeout
**Solution**: Increase init container timeout
```bash
kubectl edit deployment vllm-llama-3-70b -n llm-inference
# Set initContainers[0].timeoutSeconds: 3600
```

**Problem**: OOM (Out of Memory)
**Solution**: Reduce batch size
```bash
# Edit deployment, change --max-num-batched-tokens from 16384 to 8192
kubectl edit deployment vllm-llama-3-70b -n llm-inference
kubectl rollout restart deployment/vllm-llama-3-70b -n llm-inference
```

---

## Support

- **Slack**: #llm-platform
- **Email**: llm-platform-oncall@company.com
- **PagerDuty**: LLM Platform - Critical
- **Wiki**: https://wiki.company.com/llm-platform

---

**Deployment Completed**: ✅
**Sign-off**: _________________
**Date**: _________________
