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
export AWS_PROFILE
AWS_ACCOUNT_ID="388779989543"
AWS_REGION="ap-south-1"
# ──────────────────────────────────────────────

# Replaces the image line in a deployment YAML — works with sed (Git Bash/Linux/WSL) or pwsh (Windows)
patch_image_tag() {
  local file="$1" service="$2" new_image="$3"
  local pattern="image: .*bmi-${service}:.*"
  if command -v sed &>/dev/null; then
    sed -i "s|${pattern}|image: ${new_image}|g" "$file"
  elif command -v pwsh &>/dev/null; then
    pwsh -NoProfile -Command \
      "\$c = Get-Content \"${file}\"; \$c = \$c -replace '${pattern}', 'image: ${new_image}'; \$c | Set-Content \"${file}\""
  else
    echo "ERROR: neither 'sed' nor 'pwsh' found — cannot patch $file" >&2
    exit 1
  fi
}

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

# ── Step 3b: Ensure ECR repos exist (creates them if missing) ────────────────
echo "[3b/5] Ensuring ECR repositories exist..."
for repo in bmi-backend bmi-frontend; do
  if aws ecr describe-repositories --repository-names "$repo" --region "${AWS_REGION}" &>/dev/null; then
    echo "      $repo already exists."
  else
    echo "      Creating $repo..."
    aws ecr create-repository \
      --repository-name "$repo" \
      --region "${AWS_REGION}" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE \
      --output text --query 'repository.repositoryUri'
  fi
done
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
echo "[5/5] Updating deployment manifests..."
patch_image_tag k8s/backend/deployment.yaml  backend  "${ECR_BASE}/bmi-backend:${TAG}"
patch_image_tag k8s/frontend/deployment.yaml frontend "${ECR_BASE}/bmi-frontend:${TAG}"

# Commit and push the updated manifests so the cluster always gets the latest
git add k8s/backend/deployment.yaml k8s/frontend/deployment.yaml
# Only commit if there's actually a change (first run or new tag)
if git diff --staged --quiet; then
  echo "      Manifests unchanged (same git SHA) — no commit needed."
else
  git commit -m "deploy: image tag ${TAG} (${TIMESTAMP})"
  git push origin HEAD
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
