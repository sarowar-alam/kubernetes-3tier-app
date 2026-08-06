#!/usr/bin/env bash
# =============================================================================
# create-nlb.sh
# One-time, AWS-side setup of the manual Network Load Balancer that exposes
# this variant's ingress-nginx NodePort to the internet.
#
# Targets the 3 nodes' EC2 instance IDs directly (target-type instance) on
# the ingress-nginx controller's NodePort -- kube-proxy on whichever node
# receives the packet forwards it to a healthy ingress-nginx pod regardless
# of which node it landed on. See README.md section 3 for why.
#
# Run from your LOCAL MACHINE (not the cluster) using the AWS CLI + your
# admin profile. Idempotent -- safe to re-run: reuses an existing target
# group / load balancer / listener / security-group rule instead of failing.
#
# Usage -- export each var first (plain VAR=val assignments are NOT
# inherited by the script since it runs as a separate process):
#   export AWS_PROFILE=sarowar-ostad
#   export AWS_REGION=ap-south-1
#   export VPC_ID=vpc-0fb1f03806261b9ec
#   export NODEPORT=30080
#   export PUBLIC_SUBNET_IDS="subnet-0b88d7678355c6163 subnet-092082346b72435a2"
#   export MASTER_ID=i-0bd050568c3d523b9
#   export WORKER1_ID=i-01df20fa8c714ef58
#   export WORKER2_ID=i-017fa44c2de4f6a2b
#   export NODES_SECURITY_GROUP_ID=sg-0daa5c936d47c169a
#   bash k8s-ingress/create-nlb.sh
#
# Optional overrides:
#   TG_NAME       target group name    (default: bmi-ingress-tg)
#   LB_NAME       load balancer name   (default: bmi-ingress-nlb)
#   LISTENER_PORT public listener port (default: 80)
#   SG_CIDR       ingress rule source  (default: 0.0.0.0/0 -- the NLB has no
#                 security group of its own and forwards the client's real
#                 source IP straight through, so the NodePort must be open
#                 to the internet directly)
#
# Find NODES_SECURITY_GROUP_ID with:
#   aws ec2 describe-instances --instance-ids <any-node-instance-id> \
#     --profile sarowar-ostad --region ap-south-1 \
#     --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text
# =============================================================================

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:?Set AWS_PROFILE to your admin CLI profile}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
VPC_ID="${VPC_ID:?Set VPC_ID to your cluster VPC ID}"
NODEPORT="${NODEPORT:?Set NODEPORT to the ingress-nginx controller NodePort, default 30080}"
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS:?Set PUBLIC_SUBNET_IDS as a space-separated list, e.g. subnet-xxxx subnet-yyyy}"
MASTER_ID="${MASTER_ID:?Set MASTER_ID to the control-plane node instance ID}"
WORKER1_ID="${WORKER1_ID:?Set WORKER1_ID to worker-1 instance ID}"
WORKER2_ID="${WORKER2_ID:?Set WORKER2_ID to worker-2 instance ID}"
NODES_SECURITY_GROUP_ID="${NODES_SECURITY_GROUP_ID:?Set NODES_SECURITY_GROUP_ID to the nodes shared security group ID}"

TG_NAME="${TG_NAME:-bmi-ingress-tg}"
LB_NAME="${LB_NAME:-bmi-ingress-nlb}"
LISTENER_PORT="${LISTENER_PORT:-80}"
SG_CIDR="${SG_CIDR:-0.0.0.0/0}"

echo "================================================"
echo " Manual AWS NLB Setup (k8s-ingress variant)"
echo " Region   : ${AWS_REGION}"
echo " VPC      : ${VPC_ID}"
echo " NodePort : ${NODEPORT}"
echo " Subnets  : ${PUBLIC_SUBNET_IDS}"
echo " Targets  : ${MASTER_ID} ${WORKER1_ID} ${WORKER2_ID}"
echo "================================================"
echo ""

# ── 1. Create (or reuse) the target group ────────────────────────────────────
echo "[1/4] Ensuring target group '${TG_NAME}' exists..."
TG_ARN=$(aws elbv2 describe-target-groups --names "${TG_NAME}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

if [[ -z "${TG_ARN}" || "${TG_ARN}" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol TCP --port "${NODEPORT}" \
    --target-type instance \
    --vpc-id "${VPC_ID}" \
    --health-check-protocol HTTP --health-check-path / --health-check-port "${NODEPORT}" \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "      Created: ${TG_ARN}"
else
  echo "      Already exists: ${TG_ARN}"
fi
echo ""

# ── 2. Register the 3 nodes on the NodePort ───────────────────────────────────
echo "[2/4] Registering targets on NodePort ${NODEPORT}..."
aws elbv2 register-targets \
  --target-group-arn "${TG_ARN}" \
  --targets "Id=${MASTER_ID}" "Id=${WORKER1_ID}" "Id=${WORKER2_ID}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}"
echo "      Registered: ${MASTER_ID} ${WORKER1_ID} ${WORKER2_ID}"
echo ""

# ── 3. Create (or reuse) the load balancer + listener ─────────────────────────
echo "[3/4] Ensuring load balancer '${LB_NAME}' exists..."
LB_ARN=$(aws elbv2 describe-load-balancers --names "${LB_NAME}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)

if [[ -z "${LB_ARN}" || "${LB_ARN}" == "None" ]]; then
  LB_ARN=$(aws elbv2 create-load-balancer \
    --name "${LB_NAME}" \
    --type network \
    --scheme internet-facing \
    --subnets ${PUBLIC_SUBNET_IDS} \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  echo "      Created: ${LB_ARN}"
else
  echo "      Already exists: ${LB_ARN}"
fi

EXISTING_LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn "${LB_ARN}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --query "Listeners[?Port==\`${LISTENER_PORT}\`].ListenerArn" --output text 2>/dev/null || true)

if [[ -z "${EXISTING_LISTENER}" || "${EXISTING_LISTENER}" == "None" ]]; then
  aws elbv2 create-listener \
    --load-balancer-arn "${LB_ARN}" \
    --protocol TCP --port "${LISTENER_PORT}" \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" >/dev/null
  echo "      Created listener on port ${LISTENER_PORT}"
else
  echo "      Listener on port ${LISTENER_PORT} already exists"
fi
echo ""

# ── 4. Open the NodePort in the nodes' security group ─────────────────────────
echo "[4/4] Authorizing inbound TCP ${NODEPORT} from ${SG_CIDR} on ${NODES_SECURITY_GROUP_ID}..."
set +e
SG_OUTPUT=$(aws ec2 authorize-security-group-ingress \
  --group-id "${NODES_SECURITY_GROUP_ID}" \
  --protocol tcp --port "${NODEPORT}" --cidr "${SG_CIDR}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" 2>&1)
SG_EXIT=$?
set -e
if [[ ${SG_EXIT} -eq 0 ]]; then
  echo "      Rule added"
elif echo "${SG_OUTPUT}" | grep -q "InvalidPermission.Duplicate"; then
  echo "      Rule already present -- skipping"
else
  echo "${SG_OUTPUT}" >&2
  exit 1
fi
echo ""

DNS_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "${LB_ARN}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "================================================"
echo " NLB ready."
echo " TG_ARN : ${TG_ARN}"
echo " LB_ARN : ${LB_ARN}"
echo " DNS    : ${DNS_NAME}"
echo ""
echo " Wait ~1-2 minutes for target health checks, then check:"
echo "   aws elbv2 describe-target-health --target-group-arn ${TG_ARN} --profile ${AWS_PROFILE} --region ${AWS_REGION}"
echo ""
echo " Test:"
echo "   curl http://${DNS_NAME}/"
echo "   curl http://${DNS_NAME}/api/measurements"
echo "================================================"
