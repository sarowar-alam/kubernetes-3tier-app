#!/usr/bin/env bash
# =============================================================================
# setup-ecr-secret.sh
# Creates a Kubernetes imagePullSecret for AWS ECR in the bmi-app namespace.
# Run this on the control-plane node (10.0.5.64) ONCE before deploying.
#
# ECR tokens expire after 12 hours. Re-run this script to refresh the secret.
#
# Usage:
#   chmod +x k8s/setup-ecr-secret.sh
#   ./k8s/setup-ecr-secret.sh
#
# Prerequisites:
#   - AWS CLI installed on the control-plane node
#   - EC2 instance profile (IAM role) attached to the control-plane EC2 instance
#     with the policy: AmazonEC2ContainerRegistryReadOnly
#   - NO static credentials needed — AWS CLI auto-uses the EC2 instance profile
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# CONFIGURE THESE TWO VALUES
# ──────────────────────────────────────────────
AWS_ACCOUNT_ID="YOUR_AWS_ACCOUNT_ID"   # e.g. 123456789012
AWS_REGION="YOUR_REGION"               # e.g. ap-southeast-1
# ──────────────────────────────────────────────
# NOTE: No AWS_PROFILE is set here intentionally.
# This script runs on the EC2 control-plane node which uses its
# attached IAM instance profile for authentication automatically.

ECR_SERVER="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Fetching ECR login token..."
ECR_TOKEN=$(aws ecr get-login-password --region "${AWS_REGION}")

echo "==> Creating/updating imagePullSecret 'ecr-credentials' in namespace bmi-app..."
kubectl create secret docker-registry ecr-credentials \
  --docker-server="${ECR_SERVER}" \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✅ ECR imagePullSecret created/updated successfully."
echo ""
echo "NOTE: This token expires in 12 hours. Re-run this script to refresh it."
