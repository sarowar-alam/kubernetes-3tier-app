#!/usr/bin/env bash
# =============================================================================
# deploy.sh (LoadBalancer-annotations variant)
# Applies all Kubernetes manifests in the correct dependency order, using the
# AWS Load Balancer Controller to provision a real NLB directly from Service
# annotations — no MetalLB, no manual NLB/target-group creation.
# Run this on the control-plane node.
#
# First run  : automatically installs AWS CLI if missing, creates /data/postgres
#              on worker-1 via SSH if missing, and prompts for a DB password to
#              create the postgres and backend secrets.
# Subsequent : skips anything already in place — fully idempotent.
#
# Usage:
#   bash k8s-LoadBalancer-annotations/deploy.sh
#
# Optional environment variables (set to skip interactive prompts):
#   WORKER1_IP   private IP of the worker node that hosts PostgreSQL storage
#                e.g.  export WORKER1_IP=10.0.132.170
#
# Manual prerequisites (cannot be automated by this script — see README.md):
#   1. Attach the IAM role with AmazonEC2ContainerRegistryReadOnly to all 3 EC2
#      instances in the AWS console before the first run.
#   2. Run aws-lb-controller/setup-iam-and-subnets.sh from your LOCAL machine
#      (attaches the controller's IAM policy to the node role, tags subnets).
#   3. Run aws-lb-controller/install-controller.sh on THIS node, once, before
#      step [6/6] below — it installs cert-manager + the controller via Helm.
#   4. Fill in the real subnet IDs in frontend/service.yaml's
#      aws-load-balancer-subnets annotation before the first [6/6] apply.
# =============================================================================

set -euo pipefail

NAMESPACE="bmi-app"

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

check_and_install_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    echo "   ✅ AWS CLI: $(aws --version 2>&1)"
    return
  fi
  echo "   ⚙️  AWS CLI not found — installing..."
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
    -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp/awscli-install
  sudo /tmp/awscli-install/aws/install
  rm -rf /tmp/awscli.zip /tmp/awscli-install
  echo "   ✅ AWS CLI installed: $(aws --version 2>&1)"
}

get_worker1_ip() {
  # Returns $WORKER1_IP from env, or prompts once and exports it for reuse
  if [[ -z "${WORKER1_IP:-}" ]]; then
    read -rp "   Enter Worker-1 private IP (hosts /data/postgres): " WORKER1_IP
    export WORKER1_IP
  fi
}

get_worker1_hostname() {
  # Try to auto-detect the Kubernetes node name from the IP (avoids a second prompt)
  if [[ -z "${WORKER1_HOSTNAME:-}" ]]; then
    WORKER1_HOSTNAME=$(kubectl get nodes -o wide --no-headers 2>/dev/null \
      | grep "${WORKER1_IP}" | awk '{print $1}' || true)
  fi
  if [[ -z "${WORKER1_HOSTNAME:-}" ]]; then
    echo "   Could not auto-detect node name from IP ${WORKER1_IP}."
    kubectl get nodes --no-headers 2>/dev/null | awk '{print "     " $1 "  (" $2 ")"}'  || true
    echo ""
    read -rp "   Enter the Kubernetes node name of Worker-1: " WORKER1_HOSTNAME
    export WORKER1_HOSTNAME
  else
    echo "   ✅ Worker-1 node name: ${WORKER1_HOSTNAME}"
  fi
}

ensure_worker_storage() {
  echo "   Checking /data/postgres on worker-1 (${WORKER1_IP})..."
  if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
       ubuntu@"${WORKER1_IP}" "test -d /data/postgres" 2>/dev/null; then
    echo "   ✅ /data/postgres already exists"
  else
    echo "   ⚙️  Directory missing — creating..."
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      ubuntu@"${WORKER1_IP}" \
      "sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres"
    echo "   ✅ /data/postgres created on worker-1"
  fi
}

create_secrets_if_missing() {
  if kubectl get secret postgres-secret -n "${NAMESPACE}" \
       >/dev/null 2>&1; then
    echo "   ✅ Secrets already exist — skipping"
    return
  fi
  echo "   ⚙️  Secrets not found — first-time setup..."
  local db_pass
  while true; do
    read -rsp "   Enter a PostgreSQL password (min 8 chars): " db_pass
    echo ""
    if [[ ${#db_pass} -ge 8 ]]; then
      break
    fi
    echo "   ⚠️  Password too short — try again"
  done

  kubectl create secret generic postgres-secret \
    --from-literal=POSTGRES_DB=bmidb \
    --from-literal=POSTGRES_USER=bmi_user \
    --from-literal=POSTGRES_PASSWORD="${db_pass}" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic backend-secret \
    --from-literal=DATABASE_URL="postgres://bmi_user:${db_pass}@bmi-postgres-svc:5432/bmidb" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "   ✅ Secrets created"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

echo "================================================"
echo " BMI Health Tracker — Kubernetes Deployment (LoadBalancer-annotations variant)"
echo "================================================"
echo ""

# ── Phase 0: Prerequisites ────────────────────────────────────────────────────
# Each function is a no-op if its condition is already satisfied.
echo "[Phase 0] Checking prerequisites..."
check_and_install_aws_cli

# Namespace must exist before the ECR secret and before any -n bmi-app command
kubectl apply -f k8s-LoadBalancer-annotations/namespace.yaml

get_worker1_ip
ensure_worker_storage
get_worker1_hostname
# Label the node so pv.yaml / statefulset.yaml / migration-job.yaml all schedule
# on the right node without any hardcoded hostname in the YAML files
kubectl label node "${WORKER1_HOSTNAME}" role=postgres-storage --overwrite 2>/dev/null || true
create_secrets_if_missing
echo ""

# ── [1/6] Refresh ECR pull secret ────────────────────────────────────────────
# Namespace is guaranteed to exist now — this call is safe
echo "[1/6] Refreshing ECR pull secret..."
bash k8s-LoadBalancer-annotations/setup-ecr-secret.sh
echo ""

# ── [2/6] PostgreSQL ─────────────────────────────────────────────────────────
# Secrets already applied in Phase 0 — not re-applied here to avoid
# overwriting a live secret with a stale/placeholder YAML value
echo "[2/6] Deploying PostgreSQL (PV, PVC, StatefulSet, Service)..."
kubectl apply -f k8s-LoadBalancer-annotations/postgres/pv.yaml
kubectl apply -f k8s-LoadBalancer-annotations/postgres/pvc.yaml
kubectl apply -f k8s-LoadBalancer-annotations/postgres/statefulset.yaml
kubectl apply -f k8s-LoadBalancer-annotations/postgres/service.yaml

echo ""
echo "      Waiting for postgres pod to be Ready (up to 120s)..."
kubectl wait --for=condition=ready pod \
  -l app=postgres \
  -n "${NAMESPACE}" \
  --timeout=120s
echo ""

# ── [3/6] Database migrations ─────────────────────────────────────────────────
echo "[3/6] Running database migrations..."
kubectl apply -f k8s-LoadBalancer-annotations/postgres/migrations-configmap.yaml
kubectl delete job bmi-migrations -n "${NAMESPACE}" --ignore-not-found=true
kubectl apply -f k8s-LoadBalancer-annotations/postgres/migration-job.yaml

echo "      Waiting for migration job to complete (up to 90s)..."
kubectl wait --for=condition=complete job/bmi-migrations \
  -n "${NAMESPACE}" \
  --timeout=90s
echo ""

# ── [4/6] Backend ─────────────────────────────────────────────────────────────
# Secret already applied in Phase 0 — only configmap, deployment, service here
echo "[4/6] Deploying backend..."
kubectl apply -f k8s-LoadBalancer-annotations/backend/configmap.yaml
kubectl apply -f k8s-LoadBalancer-annotations/backend/deployment.yaml
kubectl apply -f k8s-LoadBalancer-annotations/backend/service.yaml

echo "      Waiting for backend pods to be Ready (up to 90s)..."
kubectl rollout status deployment/bmi-backend -n "${NAMESPACE}" --timeout=90s
echo ""

# ── [5/6] AWS Load Balancer Controller ────────────────────────────────────────
# NOT automated here — requires one-time AWS-side IAM/subnet setup from your
# LOCAL machine first. See README.md and aws-lb-controller/*.sh.
echo "[5/6] AWS Load Balancer Controller check..."
if kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "   ✅ Controller already installed — skipping"
else
  echo "   ⚠️  Controller not found in kube-system."
  echo "      Run these ONE-TIME steps before continuing (see README.md):"
  echo "        1) From your LOCAL machine: aws-lb-controller/setup-iam-and-subnets.sh"
  echo "        2) On this node:            aws-lb-controller/install-controller.sh"
  echo "      Re-run this script after the controller is installed."
  exit 1
fi
echo ""

# ── [6/6] Frontend ─────────────────────────────────────────────────────────────
echo "[6/6] Deploying frontend..."
kubectl apply -f k8s-LoadBalancer-annotations/frontend/deployment.yaml
kubectl apply -f k8s-LoadBalancer-annotations/frontend/service.yaml

echo "      Waiting for frontend pods to be Ready (up to 90s)..."
kubectl rollout status deployment/bmi-frontend -n "${NAMESPACE}" --timeout=90s

echo "      Waiting for the AWS Load Balancer Controller to provision the NLB (up to 180s)..."
for _ in $(seq 1 36); do
  NLB_DNS=$(kubectl get svc bmi-frontend-svc -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${NLB_DNS}" ]] && break
  sleep 5
done
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "[Done] Deployment complete! Current pod status:"
kubectl get pods -n "${NAMESPACE}"
echo ""
if [[ -n "${NLB_DNS:-}" ]]; then
  echo "✅ App URL: http://${NLB_DNS}/"
  echo "   (Real AWS NLB — provisioned automatically, no manual target-group steps needed.)"
else
  echo "⚠️  No NLB hostname assigned yet — check: kubectl get svc bmi-frontend-svc -n ${NAMESPACE}"
  echo "   Also check: kubectl logs -n kube-system deploy/aws-load-balancer-controller"
fi
