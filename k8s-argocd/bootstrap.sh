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

# Fetch the public IP of this node (control-plane) via IMDSv2
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Detected public IP: ${PUBLIC_IP}"

echo "================================================"
echo " BMI Health Tracker — ArgoCD Bootstrap"
echo "================================================"
echo ""

# ── Step 0: ensure AWS CLI is installed (required for ECR token refresh) ─────
if ! command -v aws >/dev/null 2>&1; then
  echo "[0/8] AWS CLI not found — installing..."
  apt-get install -y unzip 2>/dev/null || true
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
    -o /tmp/aws-cli.zip
  unzip -q /tmp/aws-cli.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/aws-cli.zip /tmp/aws
  echo "      ✅  AWS CLI $(aws --version 2>&1) installed."
else
  echo "[0/8] AWS CLI already present: $(aws --version 2>&1)"
fi
echo ""

# ── Pre-flight: verify all required local files exist ────────────────────────
echo "[pre-flight] Checking required local files..."
FILES_OK=true
for f in \
  k8s-argocd/argocd/namespace.yaml \
  k8s-argocd/argocd/application.yaml \
  k8s-argocd/app/namespace.yaml \
  k8s-argocd/app/postgres/secret.yaml \
  k8s-argocd/app/postgres/pv.yaml \
  k8s-argocd/app/postgres/pvc.yaml \
  k8s-argocd/app/postgres/service.yaml \
  k8s-argocd/app/postgres/statefulset.yaml \
  k8s-argocd/app/postgres/migrations-configmap.yaml \
  k8s-argocd/app/postgres/migration-job.yaml \
  k8s-argocd/app/backend/secret.yaml \
  k8s-argocd/app/backend/configmap.yaml \
  k8s-argocd/app/backend/deployment.yaml \
  k8s-argocd/app/backend/service.yaml \
  k8s-argocd/app/frontend/deployment.yaml \
  k8s-argocd/app/frontend/service.yaml \
  k8s-argocd/setup-ecr-secret.sh; do
  if [[ -f "$f" ]]; then
    echo "  ✅  $f"
  else
    echo "  ❌  MISSING: $f"
    FILES_OK=false
  fi
done
if [[ "${FILES_OK}" == "false" ]]; then
  echo ""
  echo "[ERROR] One or more required files are missing. Fix the above before continuing."
  exit 1
fi
echo "  All required files present."
echo ""

# 1. Create namespaces
echo "[1/8] Creating namespaces..."
kubectl apply -f k8s-argocd/argocd/namespace.yaml
kubectl apply -f k8s-argocd/app/namespace.yaml
echo ""

# 2. Apply gitignored secrets (one-time, manual step)
echo "[2/8] Applying secrets (gitignored — must exist locally)..."
kubectl apply -f k8s-argocd/app/postgres/secret.yaml
kubectl apply -f k8s-argocd/app/backend/secret.yaml
echo "      Secrets applied."
echo ""

# 3. Create PersistentVolume (cluster-scoped, not namespace-scoped)
echo "[3/8] Creating PersistentVolume..."
kubectl apply -f k8s-argocd/app/postgres/pv.yaml
echo ""

# 4. Create worker-1 data directory via a temporary pod (no SSH or IAM required)
echo "[4/8] Ensuring /data/postgres exists on k8s-worker-1 (via kubectl pod)..."
kubectl run mkdir-postgres -n "${NAMESPACE_APP}" --restart=Never \
  --image=busybox \
  --overrides='{
    "spec": {
      "nodeSelector": {"kubernetes.io/hostname": "k8s-worker-1"},
      "containers": [{
        "name": "mkdir-postgres",
        "image": "busybox",
        "command": ["sh", "-c", "mkdir -p /host/postgres && chmod 777 /host/postgres && echo DONE"],
        "volumeMounts": [{"name": "host-data", "mountPath": "/host"}],
        "securityContext": {"runAsUser": 0}
      }],
      "volumes": [{"name": "host-data", "hostPath": {"path": "/data"}}]
    }
  }' 2>/dev/null || true

kubectl wait pod/mkdir-postgres -n "${NAMESPACE_APP}" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null \
  && echo "      /data/postgres created on k8s-worker-1." \
  || echo "      ⚠️  Pod did not complete — check: kubectl logs mkdir-postgres -n ${NAMESPACE_APP}"
kubectl delete pod mkdir-postgres -n "${NAMESPACE_APP}" --ignore-not-found 2>/dev/null
echo ""

# 4.5 Create the ECR pull secret (required before pods can pull images from ECR)
echo "[4.5/8] Creating ECR pull secret 'ecr-credentials'..."
bash k8s-argocd/setup-ecr-secret.sh
echo ""

# 5. Install ArgoCD (--server-side --force-conflicts handles both fresh installs
#    and re-runs where client-side apply was used previously)
echo "[5/8] Installing ArgoCD into namespace '${NAMESPACE_ARGOCD}'..."
kubectl apply -n "${NAMESPACE_ARGOCD}" --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "      Waiting for ArgoCD server to be ready (up to 3 minutes)..."
kubectl rollout status deployment/argocd-server \
  -n "${NAMESPACE_ARGOCD}" --timeout=180s
echo ""

# 6. Expose ArgoCD UI via NodePort (no ingress required)
echo "[6/8] Exposing ArgoCD UI as NodePort..."
kubectl patch svc argocd-server -n "${NAMESPACE_ARGOCD}" \
  -p '{"spec":{"type":"NodePort"}}'

ARGOCD_PORT=$(kubectl get svc argocd-server -n "${NAMESPACE_ARGOCD}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
echo "      ArgoCD UI available at: http://${PUBLIC_IP}:${ARGOCD_PORT}"
echo ""

# 7. Register the ArgoCD Application — starts automated GitOps sync
echo "[7/8] Creating ArgoCD Application (triggers first sync)..."
kubectl apply -f k8s-argocd/argocd/application.yaml
echo ""

# 8. Final summary of what was applied
echo "[8/8] Verifying applied resources..."
echo "  Namespaces  : $(kubectl get ns ${NAMESPACE_APP} ${NAMESPACE_ARGOCD} --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo "  Secrets     : $(kubectl get secret postgres-secret backend-secret ecr-credentials -n ${NAMESPACE_APP} --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo "  PV          : $(kubectl get pv postgres-pv --no-headers 2>/dev/null | awk '{print $1" ("$5")"}')"
echo "  ArgoCD app  : $(kubectl get application bmi-health-tracker -n ${NAMESPACE_ARGOCD} --no-headers 2>/dev/null | awk '{print $1" sync="$2" health="$3}')"

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "${NAMESPACE_ARGOCD}" \
  -o jsonpath="{.data.password}" | base64 -d)

echo "================================================"
echo " Bootstrap complete!"
echo ""
echo "  ArgoCD UI : http://${PUBLIC_IP}:${ARGOCD_PORT}"
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
