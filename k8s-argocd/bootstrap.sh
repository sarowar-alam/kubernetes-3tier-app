#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh
# One-time setup: installs ArgoCD on the cluster, applies secrets, then creates
# the ArgoCD Application which triggers the first automated GitOps sync.
#
# Run ONCE on the control-plane node (10.0.5.64).
#
# Usage:
#   git clone https://github.com/sarowar-alam/kubernetes-3tier-app
#   cd kubernetes-3tier-app
#   bash k8s-argocd/bootstrap.sh
#
# Prerequisites:
#   - kubectl configured and pointing at the cluster
#   - AWS CLI installed with EC2 instance profile attached
#   - k8s-argocd/app/postgres/secret.yaml present locally (gitignored)
#   - k8s-argocd/app/backend/secret.yaml present locally (gitignored)
#   - /data/postgres directory created on k8s-worker-1
# =============================================================================

set -euo pipefail

NAMESPACE_APP="bmi-app"
NAMESPACE_ARGOCD="argocd"

echo "================================================"
echo " BMI Health Tracker — ArgoCD Bootstrap"
echo "================================================"
echo ""

# 1. Create namespaces
echo "[1/7] Creating namespaces..."
kubectl apply -f k8s-argocd/argocd/namespace.yaml
kubectl apply -f k8s-argocd/app/namespace.yaml
echo ""

# 2. Apply gitignored secrets (one-time, manual step)
echo "[2/7] Applying secrets (gitignored — must exist locally)..."
kubectl apply -f k8s-argocd/app/postgres/secret.yaml
kubectl apply -f k8s-argocd/app/backend/secret.yaml
echo "      Secrets applied."
echo ""

# 3. Create PersistentVolume (cluster-scoped, not namespace-scoped)
echo "[3/7] Creating PersistentVolume..."
kubectl apply -f k8s-argocd/app/postgres/pv.yaml
echo ""

# 4. Create worker-1 data directory via SSM (no SSH keys required)
echo "[4/7] Ensuring /data/postgres exists on k8s-worker-1 (via SSM)..."

WORKER1_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-worker-1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null || true)

if [[ -z "${WORKER1_INSTANCE_ID}" || "${WORKER1_INSTANCE_ID}" == "None" ]]; then
  echo "      ⚠️  Could not find k8s-worker-1 instance via AWS CLI."
  echo "         Create the directory manually on worker-1:"
  echo "         sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres"
else
  CMD_ID=$(aws ssm send-command \
    --instance-ids  "${WORKER1_INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --parameters    'commands=["sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres && echo OK"]' \
    --query         'Command.CommandId' \
    --output        text 2>/dev/null || true)

  if [[ -n "${CMD_ID}" ]]; then
    sleep 5
    STATUS=$(aws ssm get-command-invocation \
      --command-id  "${CMD_ID}" \
      --instance-id "${WORKER1_INSTANCE_ID}" \
      --query       'Status' --output text 2>/dev/null || echo "Unknown")
    echo "      SSM command status: ${STATUS} (instance: ${WORKER1_INSTANCE_ID})"
  else
    echo "      ⚠️  SSM command failed. Create directory manually on worker-1:"
    echo "         sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres"
  fi
fi
echo ""

# 5. Install ArgoCD (--server-side avoids CRD annotation size limit)
echo "[5/7] Installing ArgoCD into namespace '${NAMESPACE_ARGOCD}'..."
kubectl apply -n "${NAMESPACE_ARGOCD}" --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "      Waiting for ArgoCD server to be ready (up to 3 minutes)..."
kubectl rollout status deployment/argocd-server \
  -n "${NAMESPACE_ARGOCD}" --timeout=180s
echo ""

# 6. Expose ArgoCD UI via NodePort (no ingress required)
echo "[6/7] Exposing ArgoCD UI as NodePort..."
kubectl patch svc argocd-server -n "${NAMESPACE_ARGOCD}" \
  -p '{"spec":{"type":"NodePort"}}'

ARGOCD_PORT=$(kubectl get svc argocd-server -n "${NAMESPACE_ARGOCD}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
echo "      ArgoCD UI available at: http://10.0.130.111:${ARGOCD_PORT}"
echo ""

# 7. Register the ArgoCD Application — starts automated GitOps sync
echo "[7/7] Creating ArgoCD Application (triggers first sync)..."
kubectl apply -f k8s-argocd/argocd/application.yaml
echo ""

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "${NAMESPACE_ARGOCD}" \
  -o jsonpath="{.data.password}" | base64 -d)

echo "================================================"
echo " Bootstrap complete!"
echo ""
echo "  ArgoCD UI : http://10.0.130.111:${ARGOCD_PORT}"
echo "  Username  : admin"
echo "  Password  : ${ARGOCD_PASSWORD}"
echo ""
echo "  ArgoCD is now watching: k8s-argocd/app/ on branch main"
echo "  Every git push will trigger an automatic sync."
echo ""
echo "  Sync order (waves):"
echo "    Wave 1  → PostgreSQL StatefulSet"
echo "    Wave 2  → Migration Job (PreSync hook)"
echo "    Wave 3  → Backend Deployment"
echo "    Wave 4  → Frontend Deployment"
echo ""
echo "  Next deployment (run locally):"
echo "    bash k8s-argocd/build-and-push.sh"
echo "================================================"
