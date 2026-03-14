#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh
# Builds Docker images and pushes them to AWS ECR.
#
# Usage:
#   chmod +x k8s/build-and-push.sh
#   ./k8s/build-and-push.sh
#
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - Docker installed and running
#   - Two ECR repos already created: bmi-backend, bmi-frontend
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# CONFIGURE THESE THREE VALUES
# ──────────────────────────────────────────────
AWS_PROFILE="sarowar-ostad"            # AWS CLI profile to use on your local machine
AWS_ACCOUNT_ID="388779989543"   # e.g. 123456789012
AWS_REGION="ap-south-1"               # e.g. ap-southeast-1
# ──────────────────────────────────────────────

# Export so all aws CLI sub-commands pick it up automatically
export AWS_PROFILE

ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_BASE}"

echo ""
echo "==> Building backend image..."
docker build -t bmi-backend:latest ./backend

echo ""
echo "==> Building frontend image..."
docker build -t bmi-frontend:latest ./frontend

echo ""
echo "==> Tagging images..."
docker tag bmi-backend:latest  "${ECR_BASE}/bmi-backend:latest"
docker tag bmi-frontend:latest "${ECR_BASE}/bmi-frontend:latest"

echo ""
echo "==> Pushing backend to ECR..."
docker push "${ECR_BASE}/bmi-backend:latest"

echo ""
echo "==> Pushing frontend to ECR..."
docker push "${ECR_BASE}/bmi-frontend:latest"

echo ""
echo "==> Updating deployment manifests with ECR image URLs..."
sed -i "s|YOUR_AWS_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/bmi-backend:latest|${ECR_BASE}/bmi-backend:latest|g" \
  k8s/backend/deployment.yaml
sed -i "s|YOUR_AWS_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/bmi-frontend:latest|${ECR_BASE}/bmi-frontend:latest|g" \
  k8s/frontend/deployment.yaml

echo ""
echo "✅ Done! Images pushed to ECR."
echo "   Backend:  ${ECR_BASE}/bmi-backend:latest"
echo "   Frontend: ${ECR_BASE}/bmi-frontend:latest"
echo ""
echo "Next steps:"
echo "  1. git add k8s/backend/deployment.yaml k8s/frontend/deployment.yaml"
echo "  2. git commit -m 'Set ECR image URLs' && git push"
echo "  3. SSH into control-plane and run: bash k8s/deploy.sh"
