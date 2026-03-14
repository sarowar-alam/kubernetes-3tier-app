#!/usr/bin/env bash
# =============================================================================
# setup-ecr-on-nodes.sh
# Configures the kubelet ECR credential provider on a Kubernetes node so that
# image pulls from AWS ECR authenticate using the node's EC2 instance profile.
# No imagePullSecrets or static credentials are needed.
#
# Run this script on EACH node (control-plane AND worker-1) as root.
#
# Usage:
#   scp k8s/setup-ecr-on-nodes.sh ubuntu@10.0.5.64:~/
#   scp k8s/setup-ecr-on-nodes.sh ubuntu@10.0.130.111:~/
#   ssh ubuntu@10.0.5.64   "sudo bash ~/setup-ecr-on-nodes.sh"
#   ssh ubuntu@10.0.130.111 "sudo bash ~/setup-ecr-on-nodes.sh"
#
# Prerequisites:
#   - EC2 instance profile with AmazonEC2ContainerRegistryReadOnly attached
#     to BOTH EC2 instances (control-plane + worker-1)
#   - kubeadm cluster (containerd runtime)
# =============================================================================

set -euo pipefail

echo "================================================"
echo " ECR Credential Provider Setup"
echo " Node: $(hostname)"
echo "================================================"
echo ""

# ── 1. Download the ECR credential provider binary ───────────────────────────
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
VERSION="v1.28.3"   # credential provider version matching your K8s version
BIN_DIR="/etc/kubernetes/credential-providers"

echo "[1/4] Downloading ecr-credential-provider binary (${VERSION} ${ARCH})..."
mkdir -p "${BIN_DIR}"

curl -fsSL \
  "https://artifacts.k8s.io/binaries/cloud-provider-aws/${VERSION}/linux/${ARCH}/ecr-credential-provider-linux-${ARCH}" \
  -o "${BIN_DIR}/ecr-credential-provider"

chmod 755 "${BIN_DIR}/ecr-credential-provider"
echo "      Binary installed at ${BIN_DIR}/ecr-credential-provider"
echo ""

# ── 2. Write the credential provider config ──────────────────────────────────
PROVIDER_CONFIG="/etc/kubernetes/credential-provider-config.yaml"

echo "[2/4] Writing credential provider config to ${PROVIDER_CONFIG}..."
cat > "${PROVIDER_CONFIG}" << 'EOF'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr-fips.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF
echo ""

# ── 3. Add credential provider flags to kubelet ──────────────────────────────
KUBELET_FLAGS_FILE="/var/lib/kubelet/kubeadm-flags.env"

echo "[3/4] Updating kubelet flags in ${KUBELET_FLAGS_FILE}..."

# Add flags only if not already present
EXTRA_FLAGS="--image-credential-provider-config=${PROVIDER_CONFIG} --image-credential-provider-bin-dir=${BIN_DIR}"

if grep -q "image-credential-provider-config" "${KUBELET_FLAGS_FILE}"; then
  echo "      Credential provider flags already present — skipping."
else
  # Append flags before the closing quote of KUBELET_KUBEADM_ARGS
  # e.g. KUBELET_KUBEADM_ARGS="--existing-flag=value"
  # becomes: KUBELET_KUBEADM_ARGS="--existing-flag=value --image-credential-provider-config=..."
  sed -i "s|\"$| ${EXTRA_FLAGS}\"|" "${KUBELET_FLAGS_FILE}"
  echo "      Flags added: ${EXTRA_FLAGS}"
fi
echo ""

# ── 4. Restart kubelet ───────────────────────────────────────────────────────
echo "[4/4] Restarting kubelet..."
systemctl daemon-reload
systemctl restart kubelet

# Wait a moment and check status
sleep 5
if systemctl is-active --quiet kubelet; then
  echo "      kubelet is running ✅"
else
  echo "      ⚠️  kubelet failed to start! Check logs: journalctl -xeu kubelet"
  exit 1
fi

echo ""
echo "================================================"
echo " ✅ ECR credential provider configured on $(hostname)"
echo " Nodes will now authenticate ECR image pulls"
echo " using the EC2 instance profile automatically."
echo "================================================"
