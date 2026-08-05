#!/usr/bin/env bash
# =============================================================================
# patch-node-provider-ids.sh
# kubeadm/self-managed clusters run no cloud-controller-manager, so kubelet
# never sets Node.spec.providerID. The AWS Load Balancer Controller's
# TargetGroupBinding reconciler needs providerID to resolve a Node -> EC2
# instance (for target registration AND backend security-group rule
# management) — without it you get zero registered targets and reconciler
# errors like "providerID is not specified for node: <name>".
#
# This script matches each Node's InternalIP to its EC2 instance (via the
# node's own IAM instance-profile credentials — no AWS CLI config needed) and
# patches spec.providerID accordingly. Idempotent: already-patched nodes are
# skipped. Run on the CONTROL-PLANE node (needs kubectl cluster-admin access).
#
# Usage:
#   AWS_REGION=ap-south-1 bash k8s-LoadBalancer-annotations/aws-lb-controller/patch-node-provider-ids.sh
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"

# ── Ensure AWS CLI is present ─────────────────────────────────────────────────
if ! command -v aws >/dev/null 2>&1; then
  echo "⚙️  Installing AWS CLI v2..."
  TMP_DIR="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "${TMP_DIR}/awscliv2.zip"
  unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}"
  sudo "${TMP_DIR}/aws/install" >/dev/null
  rm -rf "${TMP_DIR}"
  echo "✅ AWS CLI installed: $(aws --version)"
fi

echo "Patching Node providerID fields (region: ${AWS_REGION})..."
NODE_NAMES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in ${NODE_NAMES}; do
  EXISTING_PROVIDER_ID=$(kubectl get node "${NODE}" -o jsonpath='{.spec.providerID}')
  if [ -n "${EXISTING_PROVIDER_ID}" ]; then
    echo "  ✅ ${NODE}: already has providerID (${EXISTING_PROVIDER_ID})"
    continue
  fi

  INTERNAL_IP=$(kubectl get node "${NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  if [ -z "${INTERNAL_IP}" ]; then
    echo "  ⚠️  ${NODE}: no InternalIP found, skipping"
    continue
  fi

  read -r INSTANCE_ID AZ <<< "$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=private-ip-address,Values=${INTERNAL_IP}" \
    --query "Reservations[0].Instances[0].[InstanceId,Placement.AvailabilityZone]" \
    --output text)"

  if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" = "None" ]; then
    echo "  ⚠️  ${NODE}: no EC2 instance found for IP ${INTERNAL_IP}, skipping"
    continue
  fi

  PROVIDER_ID="aws:///${AZ}/${INSTANCE_ID}"
  kubectl patch node "${NODE}" --type merge -p "{\"spec\":{\"providerID\":\"${PROVIDER_ID}\"}}" >/dev/null
  echo "  ✅ ${NODE}: patched providerID=${PROVIDER_ID}"
done

echo ""
echo "Done. The AWS Load Balancer Controller will pick up the change on its next"
echo "reconcile (usually within seconds) and register targets automatically."
