# Operations Manual: LLM Platform with RAG

**Version**: 1.0  
**Audience**: Platform Operators, SREs  
**Last Updated**: 2026-01-15  

---

## Daily Operations

### Morning Checks (15 minutes)

```bash
# 1. Check system health
kubectl get pods -n llm-inference
kubectl top nodes

# 2. Review overnight alerts
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
open http://localhost:9090/alerts

# 3. Check cost dashboard
open https://console.aws.amazon.com/cost-management/

# 4. Review error logs
kubectl logs --since=24h -l app=vllm -n llm-inference | grep ERROR
```

**Success Criteria**:
- ✅ All pods in `Running` state
- ✅ No critical alerts firing
- ✅ Daily cost within budget ($3.5K ± 10%)
- ✅ Error rate < 1%

---

## Weekly Tasks

### Monday: Capacity Planning Review

```bash
# Check utilization trends (past 7 days)
# Prometheus query:
avg_over_time(gpu:utilization:average[7d])
avg_over_time(llm:throughput:requests_per_second[7d])

# If GPU utilization > 80% consistently, scale up
# If < 40%, consider scaling down
```

**Action Items**:
- [ ] Review with team if scaling needed
- [ ] Submit change request for next week
- [ ] Update forecast

### Wednesday: Performance Review

```bash
# Generate weekly report
cd scripts/
./generate-weekly-report.sh > reports/week-$(date +%V).md

# Key metrics to review:
# - P95 latency trend
# - Throughput trend
# - Error rate
# - Cost per inference
```

### Friday: Incident Review

- Review incidents from past week
- Update runbooks based on learnings
- Schedule preventive actions

---

## Monthly Tasks

### Cost Optimization

```bash
# 1. Analyze EC2 usage
aws ce get-cost-and-usage \
  --time-period Start=2025-01-01,End=2025-01-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=SERVICE

# 2. Review Spot instance savings
aws ec2 describe-spot-instance-requests \
  --filters "Name=state,Values=active" \
  --query 'SpotInstanceRequests[*].InstanceId' \
  --output text | \
  xargs -I {} aws ec2 describe-instances --instance-ids {} \
  --query 'Reservations[*].Instances[*].[InstanceId,SpotInstanceRequestId,InstanceLifecycle]'

# 3. Identify unused resources
# - EBS volumes not attached
# - Old snapshots (>90 days)
# - Unused load balancers
```

**Actions**:
- [ ] Submit savings recommendations
- [ ] Request budget adjustment if needed
- [ ] Update forecasts

### Security Audit

```bash
# 1. Review IAM policies
aws iam get-policy-version \
  --policy-arn arn:aws:iam::ACCOUNT:policy/LLM-Platform-Policy \
  --version-id v1

# 2. Check for exposed endpoints
kubectl get svc -A --field-selector spec.type=LoadBalancer

# 3. Review safety violations
# Prometheus query:
sum(increase(guardrails_violations_total[30d])) by (violation_type, risk_level)

# 4. Run security scan
trivy image <image-name>:latest
```

**Actions**:
- [ ] Address high-severity findings
- [ ] Update security policies
- [ ] Brief security team

### Model Updates

**Check for new model versions**:
- Llama updates from Meta
- Security patches for vLLM
- Library updates (transformers, sentence-transformers)

**Update procedure**:
1. Test in staging environment
2. Create rollback plan
3. Schedule maintenance window
4. Deploy with canary strategy

---

## Common Operational Tasks

### 1. Scaling Operations

#### Scale Up (Add Capacity)

```bash
# Horizontal scaling (add replicas)
kubectl scale deployment vllm-llama-3-70b --replicas=4 -n llm-inference

# Vertical scaling (add nodes)
aws eks update-nodegroup-config \
  --cluster-name llm-platform-production \
  --nodegroup-name a100-node-group \
  --scaling-config minSize=2,maxSize=6,desiredSize=3

# Wait for new node
kubectl wait --for=condition=ready node \
  -l node-group=a100 \
  --timeout=10m
```

#### Scale Down

```bash
# First, drain traffic
kubectl scale deployment vllm-llama-3-70b --replicas=1 -n llm-inference

# Wait for pods to terminate
kubectl wait --for=delete pod -l app=vllm -n llm-inference --timeout=5m

# Then scale nodes
aws eks update-nodegroup-config \
  --cluster-name llm-platform-production \
  --nodegroup-name a100-node-group \
  --scaling-config desiredSize=1
```

### 2. Deploying Updates

#### Rolling Update (Zero Downtime)

```bash
# Update image tag
kubectl set image deployment/vllm-llama-3-70b \
  vllm-server=vllm/vllm-openai:v0.3.1 \
  -n llm-inference

# Monitor rollout
kubectl rollout status deployment/vllm-llama-3-70b -n llm-inference

# Check new pods
kubectl get pods -n llm-inference -l app=vllm
```

#### Canary Deployment

```bash
# Create canary deployment (10% traffic)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-llama-3-70b-canary
  namespace: llm-inference
spec:
  replicas: 1  # 10% of prod (10 replicas)
  selector:
    matchLabels:
      app: vllm
      version: canary
  template:
    metadata:
      labels:
        app: vllm
        version: canary
    spec:
      # Same as prod, but with new image
      ...
EOF

# Monitor canary metrics
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
# Query: rate(vllm_request_errors_total{version="canary"}[5m])

# If successful, promote canary
kubectl set image deployment/vllm-llama-3-70b \
  vllm-server=<canary-image> \
  -n llm-inference

# Delete canary
kubectl delete deployment vllm-llama-3-70b-canary -n llm-inference
```

### 3. Backup and Restore

#### Backup Vector Database

```bash
# Create Qdrant snapshot
kubectl exec -it qdrant-0 -n llm-inference -- \
  curl -X POST http://localhost:6333/collections/enterprise_knowledge/snapshots

# Download snapshot
kubectl cp llm-inference/qdrant-0:/snapshots/enterprise_knowledge-<timestamp>.snapshot \
  ./backups/qdrant-$(date +%Y%m%d).snapshot

# Upload to S3
aws s3 cp ./backups/qdrant-$(date +%Y%m%d).snapshot \
  s3://llm-platform-backups/qdrant/
```

#### Restore Vector Database

```bash
# Upload snapshot to pod
kubectl cp ./backups/qdrant-20250115.snapshot \
  llm-inference/qdrant-0:/tmp/restore.snapshot

# Restore
kubectl exec -it qdrant-0 -n llm-inference -- \
  curl -X PUT http://localhost:6333/collections/enterprise_knowledge/snapshots/restore \
  -H "Content-Type: application/json" \
  -d '{"location": "/tmp/restore.snapshot"}'
```

### 4. Indexing New Documents

```bash
# Prepare documents (CSV/JSON format)
cat > documents.json <<EOF
[
  {"id": "doc1", "text": "...", "metadata": {"source": "wiki"}},
  {"id": "doc2", "text": "...", "metadata": {"source": "docs"}}
]
EOF

# Index via API
kubectl port-forward svc/rag-service 8080:80 -n llm-inference &
curl -X POST http://localhost:8080/v1/documents \
  -H "Content-Type: application/json" \
  -d @documents.json

# Bulk indexing (large datasets)
kubectl exec -it <rag-service-pod> -n llm-inference -- \
  python -m src.rag.index_bulk --input-file /data/documents.jsonl --batch-size 1000
```

### 5. Monitoring GPU Health

```bash
# Real-time GPU monitoring
kubectl exec -it <vllm-pod> -n llm-inference -- \
  watch -n 1 nvidia-smi

# GPU metrics over time
kubectl exec -it <vllm-pod> -n llm-inference -- \
  nvidia-smi dmon -s pucvmet -c 60

# Export metrics to CSV
kubectl exec -it <vllm-pod> -n llm-inference -- \
  nvidia-smi --query-gpu=timestamp,gpu_name,utilization.gpu,utilization.memory,temperature.gpu \
  --format=csv > gpu-metrics-$(date +%Y%m%d).csv
```

### 6. Managing Safety Guardrails

#### Review Violations

```bash
# Get violation summary (last 24 hours)
kubectl logs --since=24h -l app=rag-service -n llm-inference | \
  grep "Safety violation" | \
  awk '{print $NF}' | sort | uniq -c | sort -rn

# Export violations to file
kubectl logs --since=7d -l app=rag-service -n llm-inference | \
  grep "Safety violation" > safety-violations-$(date +%Y%m%d).log
```

#### Update Safety Rules

```bash
# Edit guardrails configuration
kubectl edit configmap guardrails-config -n llm-inference

# Restart services to apply
kubectl rollout restart deployment/rag-service -n llm-inference
```

### 7. Cost Monitoring

```bash
# Daily cost check
aws ce get-cost-and-usage \
  --time-period Start=$(date -d yesterday +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter file://cost-filter.json

# EC2 instance costs
aws ce get-cost-and-usage \
  --time-period Start=$(date -d "7 days ago" +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=SERVICE \
  --filter '{"Services": ["Amazon Elastic Compute Cloud - Compute"]}'

# Forecast next month
aws ce get-cost-forecast \
  --time-period Start=$(date +%Y-%m-01),End=$(date -d "1 month" +%Y-%m-01) \
  --metric UNBLENDED_COST \
  --granularity MONTHLY
```

---

## Maintenance Windows

### Monthly Maintenance Schedule

**When**: First Saturday of each month, 2:00 AM - 6:00 AM PST

**Tasks**:
1. EKS cluster upgrades
2. Node AMI updates
3. Model version updates
4. Certificate renewals

**Procedure**:
```bash
# 1. Notify users (3 days before)
# Post in #llm-platform channel

# 2. Create maintenance branch
git checkout -b maintenance-$(date +%Y%m)

# 3. Drain traffic
kubectl scale deployment --all --replicas=0 -n llm-inference

# 4. Perform updates
# ... (specific to update type)

# 5. Restore traffic
kubectl scale deployment vllm-llama-3-70b --replicas=2 -n llm-inference
kubectl scale deployment rag-service --replicas=3 -n llm-inference

# 6. Validation
./scripts/smoke-test.sh

# 7. Monitor for 30 minutes
kubectl logs -f -l app=vllm -n llm-inference

# 8. Notify completion
# Post in #llm-platform channel
```

---

## On-Call Responsibilities

### On-Call Rotation
- **Primary**: Responds within 15 minutes
- **Secondary**: Backup, responds within 30 minutes
- **Duration**: 1 week (Monday 9 AM - Monday 9 AM)

### Escalation Matrix

| Severity | Response Time | Escalation Path |
|----------|--------------|-----------------|
| **P0** - Service Down | 15 min | Primary → Secondary → Manager → CTO |
| **P1** - Degraded Performance | 30 min | Primary → Secondary → Team Lead |
| **P2** - Minor Issue | 2 hours | Primary → Team Lead |
| **P3** - Info Only | Next business day | Primary (async) |

### Response Checklist

**P0 - Service Down**:
1. [ ] Acknowledge alert in PagerDuty
2. [ ] Post in #incident-response Slack channel
3. [ ] Run quick diagnostics (see troubleshooting guide)
4. [ ] Implement fix or rollback
5. [ ] Monitor for 30 minutes
6. [ ] Post resolution in Slack
7. [ ] Write incident report (within 24 hours)

**P1 - Degraded Performance**:
1. [ ] Acknowledge alert
2. [ ] Check Grafana dashboards
3. [ ] Identify bottleneck
4. [ ] Scale resources if needed
5. [ ] Monitor for 15 minutes
6. [ ] Document in weekly report

---

## Runbook Maintenance

**Owner**: Platform Engineering Team
**Review Frequency**: Quarterly

**Update Process**:
1. Create PR with changes
2. Get review from 2 team members
3. Test changes in staging
4. Merge to main
5. Announce in #llm-platform

---

## Useful Links

- **Dashboards**:
  - [Grafana](https://grafana.company.com/llm-platform)
  - [Prometheus](https://prometheus.company.com)
  - [AWS Console](https://console.aws.amazon.com)
  - [Cost Explorer](https://console.aws.amazon.com/cost-management/)

- **Documentation**:
  - [Architecture Docs](../ARCHITECTURE.md)
  - [Deployment Guide](./deployment-guide.md)
  - [Troubleshooting Guide](./troubleshooting-guide.md)
  - [Wiki](https://wiki.company.com/llm-platform)

- **Communication**:
  - Slack: #llm-platform, #llm-platform-alerts
  - Email: llm-platform@company.com
  - PagerDuty: LLM Platform

- **Code Repositories**:
  - [Main Repo](https://github.com/company/llm-platform)
  - [Terraform](https://github.com/company/llm-platform-infra)
  - [Monitoring](https://github.com/company/llm-platform-monitoring)

---

**Last Updated**: 2025-01-15
**Next Review**: 2025-04-15
**Maintained By**: AI Infrastructure Team
