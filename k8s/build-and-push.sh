#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh
# Builds Docker images, pushes to ECR, updates K8s manifests, and commits to git.
#
# Re-run this script every time you update the app code.
# Each run produces a uniquely tagged image (git SHA) so deployments are
# fully traceable and rollback is easy with: kubectl rollout undo
#
# Usage:
#   bash k8s/build-and-push.sh
#
# Prerequisites:
#   - Docker Desktop running
#   - AWS CLI installed, profile 'sarowar-ostad' configured
#   - Two ECR repos created: bmi-backend, bmi-frontend
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# CONFIG — edit AWS_ACCOUNT_ID and AWS_REGION
# ──────────────────────────────────────────────
AWS_PROFILE="sarowar-ostad"
AWS_ACCOUNT_ID="388779989543"
AWS_REGION="ap-south-1"
# ──────────────────────────────────────────────

export AWS_PROFILE

ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Use git short SHA as image tag — unique per commit, traceable, rollback-friendly.
# If somehow not in a git repo, fall back to a timestamp.
TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "================================================"
echo " BMI Health Tracker — Build & Push"
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

# ── Step 3: Tag (versioned SHA + latest) ────────────────────────────────────
echo "[3/5] Tagging images..."
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
echo ""

# ── Step 4: Push ─────────────────────────────────────────────────────────────
echo "[4/5] Pushing backend to ECR..."
docker push "${ECR_BASE}/bmi-backend:${TAG}"
docker push "${ECR_BASE}/bmi-backend:latest"

echo ""
echo "      Pushing frontend to ECR..."
docker push "${ECR_BASE}/bmi-frontend:${TAG}"
docker push "${ECR_BASE}/bmi-frontend:latest"
echo ""

# ── Step 5: Update deployment YAMLs ──────────────────────────────────────────
# Pattern matches ANY existing image value for these repos (works on every re-run).
echo "[5/5] Updating deployment manifests..."
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s/backend/deployment.yaml
sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s/frontend/deployment.yaml

# Commit and push the updated manifests so the cluster always gets the latest
git add k8s/backend/deployment.yaml k8s/frontend/deployment.yaml
# Only commit if there's actually a change (first run or new tag)
if git diff --staged --quiet; then
  echo "      Manifests unchanged (same git SHA) — no commit needed."
else
  git commit -m "deploy: image tag ${TAG} (${TIMESTAMP})"
  git push
  echo "      Manifests committed and pushed to git."
fi

echo ""
echo "================================================"
echo " ✅ Done!"
echo ""
echo "   Backend:  ${ECR_BASE}/bmi-backend:${TAG}"
echo "   Frontend: ${ECR_BASE}/bmi-frontend:${TAG}"
echo ""
echo " To roll out on the cluster:"
echo "   ssh ubuntu@10.0.5.64"
echo "   cd kubernetes-3tier-app && git pull"
echo "   kubectl rollout restart deployment/bmi-backend  -n bmi-app"
echo "   kubectl rollout restart deployment/bmi-frontend -n bmi-app"
echo ""
echo " To check rollout status:"
echo "   kubectl rollout status deployment/bmi-backend  -n bmi-app"
echo "   kubectl rollout status deployment/bmi-frontend -n bmi-app"
echo ""
echo " To rollback if something goes wrong:"
echo "   kubectl rollout undo deployment/bmi-backend  -n bmi-app"
echo "   kubectl rollout undo deployment/bmi-frontend -n bmi-app"
echo "================================================"
