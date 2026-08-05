#!/usr/bin/env bash
# =============================================================================
# teardown-iam-and-subnets.sh
# Reverses setup-iam-and-subnets.sh: detaches/deletes the controller's IAM
# policy and removes the ELB-discovery tags from the public subnets. Run
# from your LOCAL MACHINE using the AWS CLI + your admin profile, AFTER
# teardown.sh has finished on the control-plane node.
#
# Usage:
#   AWS_PROFILE=sarowar-ostad \
#   NODE_ROLE_NAME=<your-node-iam-role-name> \
#   CLUSTER_NAME=bmi-k8s-lab \
#   PUBLIC_SUBNET_IDS="subnet-xxxx subnet-yyyy" \
#   bash k8s-LoadBalancer-annotations/aws-lb-controller/teardown-iam-and-subnets.sh
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"
NODE_ROLE_NAME="${NODE_ROLE_NAME:?Set NODE_ROLE_NAME to your EC2 instance role name}"
CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME to the same value used in setup-iam-and-subnets.sh}"
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS:?Set PUBLIC_SUBNET_IDS as a space-separated list, e.g. \"subnet-xxxx subnet-yyyy\"}"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"

echo "================================================"
echo " AWS Load Balancer Controller — IAM + Subnet Teardown"
echo " Region      : ${AWS_REGION}"
echo " Node role   : ${NODE_ROLE_NAME}"
echo " Cluster tag : ${CLUSTER_NAME}"
echo "================================================"
echo ""
read -rp "This detaches/deletes '${POLICY_NAME}' and untags subnets. Type 'yes' to continue: " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
  echo "Aborted."
  exit 0
fi
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

# ── 1. Detach the policy from the shared node role ──────────────────────────
echo "[1/3] Detaching policy from role '${NODE_ROLE_NAME}'..."
if aws iam list-attached-role-policies --role-name "${NODE_ROLE_NAME}" \
     --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}']" --output text | grep -q .; then
  aws iam detach-role-policy --role-name "${NODE_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
  echo "      Detached"
else
  echo "      Already detached"
fi
echo ""

# ── 2. Delete the policy, but only if nothing else still uses it ────────────
echo "[2/3] Deleting policy '${POLICY_NAME}' (only if unused elsewhere)..."
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  STILL_ATTACHED=$(aws iam list-entities-for-policy --policy-arn "${POLICY_ARN}" \
    --query "length(PolicyRoles) + length(PolicyUsers) + length(PolicyGroups)" --output text)
  if [ "${STILL_ATTACHED}" = "0" ]; then
    aws iam delete-policy --policy-arn "${POLICY_ARN}"
    echo "      Deleted"
  else
    echo "      Still attached elsewhere — leaving the policy in place"
  fi
else
  echo "      Policy does not exist — nothing to delete"
fi
echo ""

# ── 3. Remove the ELB-discovery tags from public subnets ────────────────────
echo "[3/3] Removing subnet tags..."
for subnet in ${PUBLIC_SUBNET_IDS}; do
  aws ec2 delete-tags --resources "${subnet}" \
    --tags "Key=kubernetes.io/role/elb" "Key=kubernetes.io/cluster/${CLUSTER_NAME}" \
    --region "${AWS_REGION}"
  echo "      Untagged ${subnet}"
done
echo ""

echo "================================================"
echo " ✅ AWS-side teardown complete."
echo "================================================"
