#!/usr/bin/env bash
# =============================================================================
# create-nlb.sh
# One-time, AWS-side setup of the manual Network Load Balancer that exposes
# this variant's frontend to the internet.
#
# Targets the 3 nodes' real private IPs on the frontend Service's NodePort
# (target-type ip) -- NOT the MetalLB VIP, which an NLB cannot reach (no ARP
# resolution on a managed service). See README.md section 3 for why.
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
#   export NODEPORT=30526
#   export PUBLIC_SUBNET_IDS="subnet-0b88d7678355c6163 subnet-092082346b72435a2"
#   export MASTER_IP="10.0.2.236"
#   export WORKER1_IP="10.0.143.131"
#   export WORKER2_IP="10.0.142.85"
#   export NODES_SECURITY_GROUP_ID=sg-0daa5c936d47c169a
#   bash k8s-LoadBalancer/create-nlb.sh
#
# Optional overrides:
#   TG_NAME       target group name    (default: bmi-frontend-tg)
#   LB_NAME       load balancer name   (default: bmi-frontend-nlb)
#   LISTENER_PORT public listener port (default: 80)
#   SG_CIDR       ingress rule source  (default: 10.0.0.0/16 -- scope this to
#                 your VPC CIDR rather than 0.0.0.0/0; the internet reaches
#                 the app via the NLB, not via this NodePort directly)
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
NODEPORT="${NODEPORT:?Set NODEPORT to the frontend Service NodePort, see kubectl get svc bmi-frontend-svc -n bmi-app}"
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS:?Set PUBLIC_SUBNET_IDS as a space-separated list, e.g. subnet-xxxx subnet-yyyy}"
MASTER_IP="${MASTER_IP:?Set MASTER_IP to the control-plane node private IP}"
WORKER1_IP="${WORKER1_IP:?Set WORKER1_IP to worker-1 private IP}"
WORKER2_IP="${WORKER2_IP:?Set WORKER2_IP to worker-2 private IP}"
NODES_SECURITY_GROUP_ID="${NODES_SECURITY_GROUP_ID:?Set NODES_SECURITY_GROUP_ID to the nodes shared security group ID}"

TG_NAME="${TG_NAME:-bmi-frontend-tg}"
LB_NAME="${LB_NAME:-bmi-frontend-nlb}"
LISTENER_PORT="${LISTENER_PORT:-80}"
SG_CIDR="${SG_CIDR:-10.0.0.0/16}"

echo "================================================"
echo " Manual AWS NLB Setup (k8s-LoadBalancer variant)"
echo " Region   : ${AWS_REGION}"
echo " VPC      : ${VPC_ID}"
echo " NodePort : ${NODEPORT}"
echo " Subnets  : ${PUBLIC_SUBNET_IDS}"
echo " Targets  : ${MASTER_IP} ${WORKER1_IP} ${WORKER2_IP}"
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
    --target-type ip \
    --vpc-id "${VPC_ID}" \
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
  --targets "Id=${MASTER_IP},Port=${NODEPORT}" "Id=${WORKER1_IP},Port=${NODEPORT}" "Id=${WORKER2_IP},Port=${NODEPORT}" \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}"
echo "      Registered: ${MASTER_IP} ${WORKER1_IP} ${WORKER2_IP}"
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
echo " Wait ~2-3 minutes for target health checks, then check:"
echo "   aws elbv2 describe-target-health --target-group-arn ${TG_ARN} --profile ${AWS_PROFILE} --region ${AWS_REGION}"
echo ""
echo " Test:"
echo "   curl http://${DNS_NAME}/"
echo "================================================"
