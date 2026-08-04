#!/usr/bin/env bash
# =============================================================================
# install-metallb.sh
# Installs (or verifies) MetalLB on this kubeadm cluster so that
# Service type=LoadBalancer actually gets an EXTERNAL-IP — there is no cloud
# controller-manager here to fulfil it natively (it would stay Pending forever).
#
# Run on the control-plane node. Idempotent — safe to re-run.
#
# Usage:
#   bash k8s-LoadBalancer/metallb/install-metallb.sh
#
# NOTE: pin METALLB_VERSION to a release compatible with your cluster's
# Kubernetes version — check https://metallb.universe.tf/installation/#installation-with-manifests
# =============================================================================

set -euo pipefail

METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

echo "==> Applying MetalLB (${METALLB_VERSION})..."
kubectl apply -f "${MANIFEST_URL}"

echo "==> Waiting for metallb-system pods to be ready..."
kubectl rollout status deployment/controller -n metallb-system --timeout=120s
kubectl rollout status daemonset/speaker    -n metallb-system --timeout=120s

echo "==> Applying IPAddressPool + L2Advertisement..."
kubectl apply -f "$(dirname "$0")/ipaddresspool.yaml"
kubectl apply -f "$(dirname "$0")/l2advertisement.yaml"

echo "✅ MetalLB ready — Service type=LoadBalancer will now get an EXTERNAL-IP from the pool."
