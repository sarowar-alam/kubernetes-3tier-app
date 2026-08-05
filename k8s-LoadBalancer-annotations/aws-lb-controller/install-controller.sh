#!/usr/bin/env bash
# =============================================================================
# install-controller.sh
# Installs cert-manager (dependency) + the AWS Load Balancer Controller into
# this kubeadm cluster via Helm. Run on the CONTROL-PLANE node, after
# setup-iam-and-subnets.sh has been run from your local machine.
#
# The controller watches Service (type=LoadBalancer) and Ingress objects and
# calls the AWS API directly to create/update/delete real NLBs/ALBs and keep
# their target groups in sync with cluster nodes — no manual
# register-targets/deregister-targets needed, unlike k8s-LoadBalancer/.
#
# Usage:
#   CLUSTER_NAME=bmi-k8s-lab VPC_ID=vpc-xxxxxxxx AWS_REGION=ap-south-1 \
#   bash k8s-LoadBalancer-annotations/aws-lb-controller/install-controller.sh
#
# Prerequisites:
#   - kubectl configured on this node (control-plane already has this)
#   - Helm 3 installed (installed automatically below if missing)
#   - setup-iam-and-subnets.sh already run from your local machine (node role
#     has the controller's IAM policy attached, subnets tagged)
# =============================================================================

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME to the same value used in setup-iam-and-subnets.sh}"
VPC_ID="${VPC_ID:?Set VPC_ID to your VPC ID}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
# Optional: pin a specific controller image tag (e.g. "3.5.0"). Leave unset to use
# the eks-charts Helm chart's own appVersion default, which is always a valid image.
CONTROLLER_VERSION="${CONTROLLER_VERSION:-}"
# cert-manager 1.20+ requires k8s 1.32+ (CRD selectableFields field) — pin to the
# latest 1.18.x patch, which supports k8s 1.29-1.33. Override if your cluster is newer.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.18.6}"

echo "================================================"
echo " AWS Load Balancer Controller — Cluster-side Install"
echo " Cluster : ${CLUSTER_NAME}"
echo " VPC     : ${VPC_ID}"
echo " Region  : ${AWS_REGION}"
echo "================================================"
echo ""

# ── 1. Install Helm if missing ────────────────────────────────────────────────
echo "[1/5] Checking Helm..."
if command -v helm >/dev/null 2>&1; then
  echo "      ✅ Helm: $(helm version --short)"
else
  echo "      ⚙️  Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo "      ✅ Helm installed: $(helm version --short)"
fi
echo ""

# ── 2. Install cert-manager (webhook TLS dependency) ─────────────────────────
echo "[2/5] Installing cert-manager (${CERT_MANAGER_VERSION})..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
echo "      Waiting for cert-manager pods to be ready (up to 120s)..."
kubectl wait --for=condition=available deployment/cert-manager \
  -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-webhook \
  -n cert-manager --timeout=120s
echo ""

# ── 3. Add the eks-charts Helm repo ───────────────────────────────────────────
echo "[3/5] Adding eks-charts Helm repo..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
echo ""

# ── 4. Install the controller (self-managed cluster — no EKS API to auto-discover) ──
echo "[4/5] Installing/upgrading aws-load-balancer-controller..."
HELM_ARGS=(
  upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller
  --namespace kube-system
  --set clusterName="${CLUSTER_NAME}"
  --set region="${AWS_REGION}"
  --set vpcId="${VPC_ID}"
  --set serviceAccount.create=true
  --set serviceAccount.name=aws-load-balancer-controller
)
if [ -n "${CONTROLLER_VERSION}" ]; then
  HELM_ARGS+=(--set-string "image.tag=v${CONTROLLER_VERSION}")
fi
helm "${HELM_ARGS[@]}"

echo "      Waiting for controller rollout (up to 120s)..."
kubectl rollout status deployment/aws-load-balancer-controller \
  -n kube-system --timeout=120s
echo ""

# ── 5. Verify ──────────────────────────────────────────────────────────────
echo "[5/5] Controller pods:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo ""
echo "================================================"
echo " ✅ AWS Load Balancer Controller installed."
echo ""
echo " Next: apply frontend/service.yaml (with subnet IDs filled in) and watch:"
echo "   kubectl apply -f k8s-LoadBalancer-annotations/frontend/service.yaml"
echo "   kubectl get svc bmi-frontend-svc -n bmi-app -w"
echo "   # EXTERNAL-IP becomes the real NLB's DNS name once provisioned (~2-3 min)"
echo "================================================"
