#!/usr/bin/env bash
# =============================================================================
# install-ingress-nginx.sh
# Installs (or verifies) the ingress-nginx controller on this kubeadm cluster
# and pins its Service to NodePort 30080 (the same port/SG rule the plain
# NodePort variant in k8s/ already uses), since there is no cloud
# controller-manager here to provision a Service type=LoadBalancer.
#
# Run on the control-plane node. Idempotent — safe to re-run.
#
# Usage:
#   bash k8s-ingress/ingress/install-ingress-nginx.sh
#
# NOTE: pin INGRESS_NGINX_VERSION to a release compatible with your cluster's
# Kubernetes version — check https://github.com/kubernetes/ingress-nginx#supported-versions-table
# =============================================================================

set -euo pipefail

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.3}"
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"
HTTP_NODE_PORT="${HTTP_NODE_PORT:-30080}"

echo "==> Applying ingress-nginx controller (${INGRESS_NGINX_VERSION})..."
kubectl apply -f "${MANIFEST_URL}"

echo "==> Waiting for ingress-nginx-controller rollout..."
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s

echo "==> Pinning Service NodePort http -> ${HTTP_NODE_PORT}..."
# Full ports replace (rather than a single-field patch) keeps the http/https
# pair internally consistent regardless of upstream manifest ordering.
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=merge -p "$(cat <<EOF
{
  "spec": {
    "ports": [
      {"name": "http",  "port": 80,  "targetPort": "http",  "protocol": "TCP", "nodePort": ${HTTP_NODE_PORT}},
      {"name": "https", "port": 443, "targetPort": "https", "protocol": "TCP"}
    ]
  }
}
EOF
)"

echo "✅ ingress-nginx ready — external HTTP entry point: NodePort ${HTTP_NODE_PORT} on every node."
