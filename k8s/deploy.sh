#!/usr/bin/env bash
# =============================================================================
# deploy.sh
# Applies all Kubernetes manifests in the correct dependency order.
# Run this on the control-plane node (10.0.5.64).
#
# Usage:
#   bash k8s/deploy.sh
#
# Prerequisites (one-time setup before FIRST deploy):
#   1. Install AWS CLI on control-plane:
#      curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
#      unzip -q /tmp/a.zip -d /tmp && sudo /tmp/aws/install
#   2. Attach IAM role with AmazonEC2ContainerRegistryReadOnly to both EC2 instances
#   3. Create postgres & backend secrets manually (gitignored):
#      kubectl apply -f k8s/namespace.yaml
#      kubectl apply -f k8s/postgres/secret.yaml
#      kubectl apply -f k8s/backend/secret.yaml
#   4. Create hostPath directory on worker-1:
#      ssh ubuntu@10.0.130.111 "sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres"
# =============================================================================

set -euo pipefail

NAMESPACE="bmi-app"

echo "================================================"
echo " BMI Health Tracker — Kubernetes Deployment"
echo "================================================"
echo ""

# 0. Refresh ECR imagePullSecret (token expires every 12h)
echo "[0/6] Refreshing ECR pull secret..."
bash k8s/setup-ecr-secret.sh
echo ""

# 1. Namespace
echo "[1/6] Creating namespace..."
kubectl apply -f k8s/namespace.yaml
echo ""

# 2. PostgreSQL
echo "[2/6] Deploying PostgreSQL (PV, PVC, Secret, StatefulSet, Service)..."
kubectl apply -f k8s/postgres/secret.yaml
kubectl apply -f k8s/postgres/pv.yaml
kubectl apply -f k8s/postgres/pvc.yaml
kubectl apply -f k8s/postgres/statefulset.yaml
kubectl apply -f k8s/postgres/service.yaml

echo ""
echo "      Waiting for postgres pod to be Ready (up to 120s)..."
kubectl wait --for=condition=ready pod \
  -l app=postgres \
  -n "${NAMESPACE}" \
  --timeout=120s
echo ""

# 3. Run database migrations
echo "[3/6] Running database migrations..."
kubectl apply -f k8s/postgres/migrations-configmap.yaml
kubectl delete job bmi-migrations -n "${NAMESPACE}" --ignore-not-found=true
kubectl apply -f k8s/postgres/migration-job.yaml

echo "      Waiting for migration job to complete (up to 90s)..."
kubectl wait --for=condition=complete job/bmi-migrations \
  -n "${NAMESPACE}" \
  --timeout=90s
echo ""

# 4. Backend
echo "[4/6] Deploying backend..."
kubectl apply -f k8s/backend/secret.yaml
kubectl apply -f k8s/backend/configmap.yaml
kubectl apply -f k8s/backend/deployment.yaml
kubectl apply -f k8s/backend/service.yaml

echo "      Waiting for backend pods to be Ready (up to 90s)..."
kubectl rollout status deployment/bmi-backend -n "${NAMESPACE}" --timeout=90s
echo ""

# 5. Frontend
echo "[5/6] Deploying frontend..."
kubectl apply -f k8s/frontend/deployment.yaml
kubectl apply -f k8s/frontend/service.yaml

echo "      Waiting for frontend pods to be Ready (up to 90s)..."
kubectl rollout status deployment/bmi-frontend -n "${NAMESPACE}" --timeout=90s
echo ""

# 6. Summary
echo "[6/6] Deployment complete! Current pod status:"
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "================================================"
echo " ✅ App is live at: http://10.0.130.111:30080"
echo "================================================"
