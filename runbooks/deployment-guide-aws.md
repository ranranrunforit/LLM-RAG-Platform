# AWS Operations Runbook
**Project 303: Enterprise LLM Platform with RAG — AWS Path**

For first-time setup, follow `reference-implementation/docs/AWS_DEPLOYMENT.md`
end-to-end. This document covers **day-2 operations** for the AWS deployment:
scaling, deployments, monitoring, and incident response.

---

## 1. Architecture Quick Reference

```
Internet
   │
   ▼
ALB (public)
   │
   ▼
ECS Fargate (rag-api, 2-10 tasks)        ────►  SageMaker Endpoint
   │                                              (Llama 3 70B on ml.p4d.24xlarge,
   ▼                                               or Mistral 7B on ml.g5.12xlarge)
EC2 (Qdrant t3.medium, private subnet)
   │
   ▼
S3 (documents) │ Secrets Manager │ CloudWatch
```

Terraform state lives in `reference-implementation/terraform/aws/`. The ECS
service is `project-303-rag-production-rag-api` on cluster
`project-303-rag-production-cluster`.

---

## 2. Deploy a New RAG API Image

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-2
ECR=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/project-303-rag-production-rag-api

cd reference-implementation/python
docker build -f Dockerfile.aws -t rag-api:$(git rev-parse --short HEAD) .
docker tag rag-api:$(git rev-parse --short HEAD) $ECR:latest
docker tag rag-api:$(git rev-parse --short HEAD) $ECR:$(git rev-parse --short HEAD)

aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ECR
docker push $ECR:latest
docker push $ECR:$(git rev-parse --short HEAD)

aws ecs update-service \
  --cluster project-303-rag-production-cluster \
  --service project-303-rag-production-rag-api \
  --force-new-deployment \
  --region $REGION

aws ecs wait services-stable \
  --cluster project-303-rag-production-cluster \
  --services project-303-rag-production-rag-api \
  --region $REGION
```

ECS does a rolling deploy (`maximumPercent=200, minimumHealthyPercent=50`),
so there is no downtime.

---

## 3. Scale the RAG API

Application Auto Scaling drives ECS desired count based on CPU. Manual
override (e.g. before a known traffic spike):

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/project-303-rag-production-cluster/project-303-rag-production-rag-api \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 4 \
  --max-capacity 20
```

Revert via Terraform:

```bash
cd reference-implementation/terraform/aws
terraform apply
```

---

## 4. SageMaker Endpoint Lifecycle

### Pause inference cost overnight

```bash
# Save the current endpoint config
aws sagemaker describe-endpoint --endpoint-name project-303-rag-production-llm \
  --region us-west-2 --query 'EndpointConfigName' --output text > /tmp/endpoint-config

# Delete the endpoint (model + config remain — recreating is cheap)
aws sagemaker delete-endpoint --endpoint-name project-303-rag-production-llm \
  --region us-west-2

# In the morning, recreate from the saved config
aws sagemaker create-endpoint \
  --endpoint-name project-303-rag-production-llm \
  --endpoint-config-name $(cat /tmp/endpoint-config) \
  --region us-west-2
```

> Provisioning a p4d.24xlarge takes ~15 minutes, so this only makes sense for
> overnight pauses, not minute-to-minute scaling.

### Roll out a new model version (blue/green)

1. Create a new `aws_sagemaker_model` (Terraform will pick a new timestamped name).
2. Create a new `aws_sagemaker_endpoint_configuration` referencing it.
3. Update the existing endpoint to point at the new config:
   ```bash
   aws sagemaker update-endpoint \
     --endpoint-name project-303-rag-production-llm \
     --endpoint-config-name <new-config-name> \
     --region us-west-2
   ```
4. SageMaker provisions the new instances, drains the old, and switches
   traffic atomically. Rollback by re-running `update-endpoint` with the
   previous config name.

---

## 5. Monitoring & Alerts

| Signal | Where | Threshold |
|---|---|---|
| RAG API P95 latency | CloudWatch metric `rag_request_duration_seconds` (custom) or ALB `TargetResponseTime` | warn > 2 s |
| RAG API 5xx rate | ALB `HTTPCode_Target_5XX_Count` | warn > 1% |
| ECS task CPU | `AWS/ECS::CPUUtilization` | scale-out > 70% (configured), alert > 90% |
| SageMaker invocation latency | `AWS/SageMaker::ModelLatency` | warn > 1500 ms P95 |
| SageMaker errors | `AWS/SageMaker::Invocation5XXErrors` | warn > 5/min |
| Qdrant instance | EC2 instance status checks + custom CloudWatch agent | any failure |

Prometheus rules in `reference-implementation/monitoring/prometheus/llm-rules.yaml`
are reusable: scrape the `/metrics` endpoint via an EKS Prometheus or AMP
(Amazon Managed Prometheus) deployment. The metrics are identical to those
emitted on GCP.

---

## 6. Incident Playbooks

### RAG API returning 500
1. `aws ecs describe-services --cluster ... --services ... --region $REGION`
2. Tail logs: `aws logs tail /ecs/project-303-rag-production-rag-api --since 10m --follow`
3. If `SageMaker InvokeEndpoint` failures → check endpoint status:
   `aws sagemaker describe-endpoint --endpoint-name project-303-rag-production-llm`
   If `Failed`, look at the SageMaker log group `/aws/sagemaker/Endpoints/...`.
4. If `Qdrant connection refused` → SSM into the Qdrant EC2 box and check Docker:
   ```bash
   aws ssm start-session --target $(aws ec2 describe-instances \
     --filters Name=tag:Name,Values=project-303-rag-production-qdrant \
     --query 'Reservations[0].Instances[0].InstanceId' --output text)
   sudo docker ps
   sudo docker logs qdrant --tail 100
   ```

### SageMaker endpoint in `Failed`
- Almost always means the model container crashed at startup (OOM, missing
  HF token, or invalid `HF_MODEL_ID`).
- Inspect: `aws logs tail /aws/sagemaker/Endpoints/project-303-rag-production-llm --since 30m`.
- Recovery: delete + recreate via `terraform apply` (or the `update-endpoint`
  workflow above).

### Cost spike alert
- The single largest line item is the SageMaker p4d instance (~$32/hr).
- `aws ce get-cost-and-usage` to confirm the source.
- If the spike was unintended, delete the endpoint immediately:
  `aws sagemaker delete-endpoint --endpoint-name project-303-rag-production-llm`.

---

## 7. Backup & DR

- **Vector data**: the Qdrant EC2 instance is single-AZ and not backed up by
  default. For a stateful production deployment, take EBS snapshots on a
  schedule (e.g. AWS Backup with a daily rule) or migrate to a HA Qdrant
  cluster on EKS with PVC backups.
- **Documents**: S3 versioning is enabled (`storage.tf`). Cross-region
  replication is not configured — add an `aws_s3_bucket_replication_configuration`
  if you need it.
- **Configuration**: all infra is Terraform-managed. A full rebuild from an
  empty account takes ~25 minutes (VPC + ECR + ECS + Qdrant), plus ~15 minutes
  for the SageMaker endpoint if enabled. Run `terraform apply` against a fresh
  region for DR.
