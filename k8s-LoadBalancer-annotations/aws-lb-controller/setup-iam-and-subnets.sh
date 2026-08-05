#!/usr/bin/env bash
# =============================================================================
# setup-iam-and-subnets.sh
# One-time AWS-side setup for the AWS Load Balancer Controller, run from your
# LOCAL MACHINE (not the cluster) using the AWS CLI + your admin profile.
#
# Creates the IAM policy the controller needs, attaches it to the EC2
# instance role already used by your 3 nodes, and tags the public subnets so
# the controller knows where it's allowed to place an internet-facing NLB.
#
# Usage:
#   AWS_PROFILE=sarowar-ostad \
#   NODE_ROLE_NAME=<your-node-iam-role-name> \
#   VPC_ID=<your-vpc-id> \
#   CLUSTER_NAME=bmi-k8s-lab \
#   PUBLIC_SUBNET_IDS="subnet-xxxx subnet-yyyy" \
#   bash k8s-LoadBalancer-annotations/aws-lb-controller/setup-iam-and-subnets.sh
#
# Prerequisites:
#   - AWS CLI configured with a profile that has IAM + EC2 admin permissions
#     (this is more privileged than the per-node instance profile — run this
#     from your own machine, not from the cluster).
#   - Find NODE_ROLE_NAME with:
#       aws ec2 describe-instances --instance-ids <any-node-instance-id> \
#         --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
#     then: aws iam list-instance-profiles --query "InstanceProfiles[?Arn=='<arn-above>'].Roles[0].RoleName" --output text
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"
NODE_ROLE_NAME="${NODE_ROLE_NAME:?Set NODE_ROLE_NAME to your EC2 instance role name}"
VPC_ID="${VPC_ID:?Set VPC_ID to your VPC ID}"
CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME — an arbitrary identifier, e.g. bmi-k8s-lab}"
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS:?Set PUBLIC_SUBNET_IDS as a space-separated list, e.g. \"subnet-xxxx subnet-yyyy\"}"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo " AWS Load Balancer Controller — IAM + Subnet Setup"
echo " Region      : ${AWS_REGION}"
echo " Node role   : ${NODE_ROLE_NAME}"
echo " VPC         : ${VPC_ID}"
echo " Cluster tag : ${CLUSTER_NAME}"
echo "================================================"
echo ""

# ── 1. Create (or reuse) the IAM policy ──────────────────────────────────────
echo "[1/3] Ensuring IAM policy '${POLICY_NAME}' exists..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  echo "      Policy already exists: ${POLICY_ARN}"
else
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document "file://${SCRIPT_DIR}/iam-policy.json" \
    --query 'Policy.Arn' --output text)
  echo "      Created policy: ${POLICY_ARN}"
fi
echo ""

# ── 2. Attach the policy to the shared node role ─────────────────────────────
echo "[2/3] Attaching policy to role '${NODE_ROLE_NAME}'..."
aws iam attach-role-policy \
  --role-name "${NODE_ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"
echo "      Attached — the controller pod will authenticate via this node's instance profile."
echo ""

# ── 3. Tag subnets so the controller can auto-discover placement ─────────────
echo "[3/3] Tagging public subnets for ELB auto-discovery..."
for subnet in ${PUBLIC_SUBNET_IDS}; do
  aws ec2 create-tags --resources "${subnet}" --tags \
    "Key=kubernetes.io/role/elb,Value=1" \
    "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned" \
    --region "${AWS_REGION}"
  echo "      Tagged ${subnet}"
done
echo ""

echo "================================================"
echo " ✅ AWS-side setup complete."
echo ""
echo " Next: SSH into the control-plane node and run:"
echo "   CLUSTER_NAME=${CLUSTER_NAME} VPC_ID=${VPC_ID} AWS_REGION=${AWS_REGION} \\"
echo "   bash k8s-LoadBalancer-annotations/aws-lb-controller/install-controller.sh"
echo "================================================"
