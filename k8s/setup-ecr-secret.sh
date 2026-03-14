#!/usr/bin/env bash
# =============================================================================
# setup-ecr-secret.sh
# Creates (or refreshes) the ECR imagePullSecret in the bmi-app namespace.
# The ECR token expires every 12 hours — this script is called automatically
# by deploy.sh on every deployment so the secret is always fresh.
#
# Run on the control-plane node (10.0.5.64).
# Requires: AWS CLI installed + EC2 instance profile with
#           AmazonEC2ContainerRegistryReadOnly attached.
#
# Usage (standalone):
#   bash k8s/setup-ecr-secret.sh
# =============================================================================

set -euo pipefail

ECR_ACCOUNT="388779989543"
ECR_REGION="ap-south-1"
ECR_SERVER="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com"
NAMESPACE="bmi-app"
SECRET_NAME="ecr-credentials"

echo "==> Fetching ECR token (via EC2 instance profile)..."
ECR_TOKEN=$(aws ecr get-login-password --region "${ECR_REGION}")

echo "==> Creating/refreshing secret '${SECRET_NAME}' in namespace '${NAMESPACE}'..."
kubectl create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${ECR_SERVER}" \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}" \
  --namespace="${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ ECR secret ready (valid for 12 hours)."
