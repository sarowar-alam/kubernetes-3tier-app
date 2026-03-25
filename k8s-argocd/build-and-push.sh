#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh  (ArgoCD variant)
#
# Builds Docker images, pushes to ECR, patches k8s-argocd/app/ deployment
# manifests with the new image tag, then commits and pushes to git.
#
# ArgoCD detects the manifest diff on the main branch and automatically
# syncs to the cluster — no SSH to the control-plane is needed.
#
# Usage:
#   bash k8s-argocd/build-and-push.sh
#
# Prerequisites:
#   - Docker Desktop running locally
#   - AWS CLI installed, profile 'sarowar-ostad' configured
#   - Two ECR repos exist: bmi-backend, bmi-frontend
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# CONFIG
# ──────────────────────────────────────────────
AWS_PROFILE="sarowar-ostad"
AWS_ACCOUNT_ID="388779989543"
AWS_REGION="ap-south-1"
# ──────────────────────────────────────────────

export AWS_PROFILE

ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "================================================"
echo " BMI Health Tracker — Build & Push (ArgoCD)"
echo " Image tag : ${TAG}"
echo " Timestamp : ${TIMESTAMP}"
echo " Registry  : ${ECR_BASE}"
echo "================================================"
echo ""

# ── Step 1: ECR login ────────────────────────────────────────────────────────
echo "[1/5] Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_BASE}"
echo ""

# ── Step 2: Build ────────────────────────────────────────────────────────────
echo "[2/5] Building backend image..."
docker build -t "bmi-backend:${TAG}" ./backend

echo ""
echo "      Building frontend image..."
docker build -t "bmi-frontend:${TAG}" ./frontend
echo ""

# ── Step 3: Tag ─────────────────────────────────────────────────────────────
echo "[3/5] Tagging images..."
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
echo ""

# ── Step 4: Push ─────────────────────────────────────────────────────────────
echo "[4/5] Pushing to ECR..."
docker push "${ECR_BASE}/bmi-backend:${TAG}"
docker push "${ECR_BASE}/bmi-backend:latest"
docker push "${ECR_BASE}/bmi-frontend:${TAG}"
docker push "${ECR_BASE}/bmi-frontend:latest"
echo ""

# ── Step 5: Patch k8s-argocd/app/ manifests and commit ──────────────────────
echo "[5/5] Patching k8s-argocd/app/ manifests with new image tag..."
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s-argocd/app/backend/deployment.yaml
sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s-argocd/app/frontend/deployment.yaml

git add k8s-argocd/app/backend/deployment.yaml \
        k8s-argocd/app/frontend/deployment.yaml

if git diff --staged --quiet; then
  echo "      Manifests unchanged (same git SHA) — no commit needed."
else
  git commit -m "deploy(argocd): image tag ${TAG} (${TIMESTAMP})"
  git push
  echo "      Manifests committed and pushed."
  echo "      ArgoCD will detect the diff and sync within ~3 minutes."
fi

echo ""
echo "================================================"
echo " Done!"
echo ""
echo "   Backend  : ${ECR_BASE}/bmi-backend:${TAG}"
echo "   Frontend : ${ECR_BASE}/bmi-frontend:${TAG}"
echo ""
echo " ArgoCD auto-sync will deploy in ~3 minutes."
echo " Check status at the ArgoCD UI or run:"
echo "   kubectl get pods -n bmi-app"
echo ""
echo " To rollback:"
echo "   kubectl rollout undo deployment/bmi-backend  -n bmi-app"
echo "   kubectl rollout undo deployment/bmi-frontend -n bmi-app"
echo "================================================"
