#!/usr/bin/env bash
# =============================================================================
# teardown.sh (LoadBalancer-annotations variant)
# Removes the app and the AWS Load Balancer Controller from the cluster, in
# the correct order so the *real* AWS resources (NLB, target group, the two
# controller-managed security groups) are cleanly deprovisioned — not
# orphaned. Run this on the CONTROL-PLANE node.
#
# After this finishes, also run aws-lb-controller/teardown-iam-and-subnets.sh
# from your LOCAL MACHINE to remove the IAM policy + subnet tags created by
# setup-iam-and-subnets.sh.
#
# Usage:
#   bash k8s-LoadBalancer-annotations/teardown.sh
# =============================================================================

set -euo pipefail

NAMESPACE="bmi-app"

echo "================================================"
echo " BMI Health Tracker — Teardown (LoadBalancer-annotations variant)"
echo "================================================"
echo ""
read -rp "This deletes the app, the NLB/target group/security groups, and the AWS Load Balancer Controller. Type 'yes' to continue: " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
  echo "Aborted."
  exit 0
fi
echo ""

# ── 1. Delete the frontend Service first — this is what triggers the ────────
#      controller to deprovision the real NLB, target group, and the two
#      security groups it created. Deleting anything else first would leave
#      these AWS resources orphaned.
echo "[1/4] Deleting frontend Service (triggers AWS Load Balancer Controller cleanup)..."
kubectl delete -f k8s-LoadBalancer-annotations/frontend/service.yaml --ignore-not-found=true

echo "      Waiting up to 120s for the NLB/target group/security groups to be deprovisioned..."
for i in $(seq 1 24); do
  # --request-timeout guards against this hanging forever on an unresponsive API server
  REMAINING=$(kubectl get targetgroupbindings -n "${NAMESPACE}" --request-timeout=10s \
    --no-headers 2>/dev/null | wc -l)
  if [ "${REMAINING}" -eq 0 ]; then
    echo "      ✅ AWS resources deprovisioned"
    break
  fi
  sleep 5
done
echo ""

# ── 2. Delete the rest of the app ────────────────────────────────────────────
echo "[2/4] Deleting remaining app resources..."
kubectl delete -f k8s-LoadBalancer-annotations/frontend/deployment.yaml --ignore-not-found=true
kubectl delete job bmi-migrations -n "${NAMESPACE}" --ignore-not-found=true
kubectl delete -R -f k8s-LoadBalancer-annotations/backend/ --ignore-not-found=true
kubectl delete -R -f k8s-LoadBalancer-annotations/postgres/ --ignore-not-found=true
echo "      (PV reclaim policy is Retain — /data/postgres data is preserved)"
echo ""

# ── 3. Uninstall the controller + cert-manager ───────────────────────────────
echo "[3/4] Uninstalling AWS Load Balancer Controller + cert-manager..."
if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  helm uninstall aws-load-balancer-controller -n kube-system
else
  echo "      Controller already uninstalled"
fi
kubectl delete namespace cert-manager --ignore-not-found=true
echo ""

# ── 4. Optionally delete the namespace itself ────────────────────────────────
echo "[4/4] Delete namespace '${NAMESPACE}' (Secrets/ConfigMaps/PVCs; PVs survive via Retain)?"
read -rp "      Type 'yes' to delete the namespace: " CONFIRM_NS
if [ "${CONFIRM_NS}" = "yes" ]; then
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
  echo "      ✅ Namespace deleted"
else
  echo "      Skipped"
fi
echo ""

echo "================================================"
echo " ✅ Cluster-side teardown complete."
echo ""
echo " Next (from your LOCAL machine):"
echo "   AWS_PROFILE=sarowar-ostad NODE_ROLE_NAME=<role-name> \\"
echo "   PUBLIC_SUBNET_IDS=\"<subnet-id-1> <subnet-id-2>\" CLUSTER_NAME=bmi-k8s-lab \\"
echo "   bash k8s-LoadBalancer-annotations/aws-lb-controller/teardown-iam-and-subnets.sh"
echo "================================================"
