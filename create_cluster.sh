#!/usr/bin/env bash
# =============================================================================
# create_cluster.sh
#
# Provisions EC2 instances for a self-managed Kubernetes cluster on AWS.
# Creates one control-plane node and N worker nodes, wires up hostnames,
# and bootstraps workers with the kubeadm join command via user-data.
#
# Usage:
#   bash create_cluster.sh                        # 1 control-plane + 1 worker (default)
#   WORKER_COUNT=3 bash create_cluster.sh         # 1 control-plane + 3 workers
#   WORKER_COUNT=0 bash create_cluster.sh         # control-plane only (no workers)
#   INSTANCE_TYPE=t3.large bash create_cluster.sh # use a larger instance type
#   KEY_NAME=my-key bash create_cluster.sh        # attach an EC2 key pair for SSH access
#
#   # Override multiple options at once:
#   WORKER_COUNT=2 INSTANCE_TYPE=t3.large KEY_NAME=my-key bash create_cluster.sh
#
#   # Scale out after initial launch (source first to load functions):
#   source create_cluster.sh
#   scale_workers 2 2   # add k8s-worker-2 and k8s-worker-3 to existing cluster
#
# Post-launch steps (run on control-plane unless noted):
#
#   Step 1 — Verify all nodes joined successfully (allow ~2 min after launch):
#       kubectl get nodes
#
#   Step 2 — If a worker shows NotReady or failed to join, reset and rejoin it:
#       # On the affected worker node:
#       kubeadm reset -f
#       rm -rf /etc/cni/net.d /etc/kubernetes
#       iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
#
#       # Get a fresh join command from the control-plane:
#       kubeadm token create --print-join-command
#       # Then paste and run the output on the worker.
#
#   Step 3 — Monitor worker join progress (on each worker node):
#       tail -f /var/log/kubeadm-join.log
#
#   Step 4 — Monitor token registration on the control-plane:
#       cat /var/log/kubeadm-token.log
#       kubeadm token list
#
#   Step 5 — Deploy the app (from the control-plane):
#       bash k8s/deploy.sh          # existing manual deployment
#       bash k8s-argocd/bootstrap.sh  # ArgoCD GitOps deployment
#
# Prerequisites:
#   - AWS CLI v2 with profile 'sarowar-ostad' configured
#   - jq installed (brew install jq / apt install jq)
#   - Your key pair name set in KEY_NAME below (default: sarowar-ostad-mumbai)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# CONFIGURATION — edit here or export as env vars
# ─────────────────────────────────────────────

AWS_PROFILE="${AWS_PROFILE:-sarowar-ostad}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# Instance sizing
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
KEY_NAME="${KEY_NAME:-sarowar-ostad-mumbai}"     # EC2 key pair name for SSH access
IAM_INSTANCE_PROFILE="arn:aws:iam::388779989543:instance-profile/SSM"  # IAM instance profile (SSM + ECR)

# How many worker nodes to create (default: 1)
WORKER_COUNT="${WORKER_COUNT:-1}"

# AMIs
CP_AMI="ami-0836605e18bf84038"                  # sarowar-k8s-control-plane
WORKER_AMI="ami-0e4d1e2b336ac2357"              # sarowar-k8s-worker-1

# Networking
# All three resources below are confirmed in the same VPC: vpc-05e583835aeaa6ad4
PUBLIC_SUBNET="subnet-0880772cfbeb8bb6f"        # Control-plane subnet (public)  — vpc-05e583835aeaa6ad4
PRIVATE_SUBNET="subnet-054147291dc0bf764"       # Worker subnet (private)         — vpc-05e583835aeaa6ad4
SECURITY_GROUP="sg-097d6afb08616ba09"           # Security group                  — vpc-05e583835aeaa6ad4

# Control-plane static private IP
CP_PRIVATE_IP="10.0.5.64"

# Workers start at this IP and increment (10.0.130.111, .112, .113 …)
WORKER_IP_BASE="10.0.130"
WORKER_IP_START=111

# Kubernetes join credentials
K8S_API_ENDPOINT="10.0.5.64:6443"
# Token is generated fresh at script runtime (format: [a-z0-9]{6}.[a-z0-9]{16})
# so it is never stale — it will be registered on the control-plane with TTL=0.
KUBEADM_TOKEN="$(printf '%s.%s' \
  "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c6)" \
  "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c16)")"
DISCOVERY_TOKEN_CA_CERT_HASH="sha256:b00b15f584873ea18856763dff8ea3e85bf4317df1f0a7b43cc0a77ddcf01e84"

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────

export AWS_PROFILE AWS_REGION

log()  { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Verify required tools
check_deps() {
  command -v aws  >/dev/null 2>&1 || die "AWS CLI v2 not found. Install from https://aws.amazon.com/cli/"
  command -v jq   >/dev/null 2>&1 || die "jq not found. Install with: brew install jq  OR  apt install jq"
  aws --version | grep -q "aws-cli/2" || die "AWS CLI v2 required. Found: $(aws --version)"
}

# Verify the AWS profile exists and has valid credentials
check_aws_auth() {
  log "Verifying AWS credentials for profile '${AWS_PROFILE}'..."
  aws sts get-caller-identity --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    --query 'Arn' --output text \
    || die "AWS authentication failed. Check profile '${AWS_PROFILE}'."
}

# ─────────────────────────────────────────────
# INSTANCE CREATION FUNCTION
# ─────────────────────────────────────────────
#
# create_instance <ami> <subnet> <private-ip> <assoc-public-ip> <hostname-tag> <role-tag> <user-data>
#
#   ami               : AMI ID to launch from
#   subnet            : Subnet ID
#   private-ip        : Static private IP to assign
#   assoc-public-ip   : "true" or "false"
#   hostname-tag      : Value for the Name tag
#   role-tag          : Value for the Role tag (e.g. control-plane, worker)
#   user-data         : Shell script injected as EC2 user-data (base64-encoded internally)
#
create_instance() {
  local ami="$1"
  local subnet="$2"
  local private_ip="$3"
  local assoc_public_ip="$4"
  local hostname_tag="$5"
  local role_tag="$6"
  local user_data="$7"

  log "Launching instance '${hostname_tag}' (${private_ip})..."

  # Build the key-pair argument only if KEY_NAME is set
  local key_arg=()
  if [[ -n "${KEY_NAME}" ]]; then
    key_arg=(--key-name "${KEY_NAME}")
  fi

  local instance_id
  instance_id=$(aws ec2 run-instances \
    --profile        "${AWS_PROFILE}" \
    --region         "${AWS_REGION}" \
    --image-id       "${ami}" \
    --instance-type  "${INSTANCE_TYPE}" \
    --subnet-id      "${subnet}" \
    --security-group-ids "${SECURITY_GROUP}" \
    --private-ip-address "${private_ip}" \
    $([ "${assoc_public_ip}" = "true" ] && echo "--associate-public-ip-address" || echo "--no-associate-public-ip-address") \
    "${key_arg[@]}" \
    --iam-instance-profile "Arn=${IAM_INSTANCE_PROFILE}" \
    --user-data      "${user_data}" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${hostname_tag}},{Key=Role,Value=${role_tag}},{Key=Project,Value=bmi-health-tracker},{Key=ManagedBy,Value=create_cluster.sh}]" \
    --query          'Instances[0].InstanceId' \
    --output         text) \
    || die "Failed to launch instance '${hostname_tag}'"

  echo "${instance_id}"
}

# Wait until all given instance IDs reach 'running' state
wait_for_instances() {
  local ids=("$@")
  log "Waiting for instances to reach 'running' state: ${ids[*]}"
  aws ec2 wait instance-running \
    --profile   "${AWS_PROFILE}" \
    --region    "${AWS_REGION}" \
    --instance-ids "${ids[@]}" \
    || die "Timed out waiting for instances to start."
  log "All instances are running."
}

# Print a summary row for a given instance ID
print_instance_info() {
  local instance_id="$1"
  local info
  info=$(aws ec2 describe-instances \
    --profile    "${AWS_PROFILE}" \
    --region     "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].{ID:InstanceId,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,State:State.Name,Name:Tags[?Key==`Name`].Value|[0]}' \
    --output json)

  local name       ; name=$(echo       "${info}" | jq -r '.Name       // "—"')
  local private_ip ; private_ip=$(echo "${info}" | jq -r '.PrivateIP  // "—"')
  local public_ip  ; public_ip=$(echo  "${info}" | jq -r '.PublicIP   // "—"')
  local state      ; state=$(echo      "${info}" | jq -r '.State      // "—"')

  printf "  %-30s  %-21s  %-25s  %-15s  %s\n" \
    "${name}" "${instance_id}" "${private_ip}" "${public_ip}" "${state}"
}

# ─────────────────────────────────────────────
# USER-DATA SCRIPTS
# ─────────────────────────────────────────────

# Control-plane user-data: sets the hostname and injects the full cluster
# hosts block so every node can resolve all peers by name.
#
# Args: <hostname> <hosts-block>
#   hosts-block: multi-line string of "IP  hostname" entries for all nodes
control_plane_userdata() {
  local hostname="$1"
  local hosts_block="$2"
  cat <<EOF
#!/bin/bash
set -e
hostnamectl set-hostname "${hostname}"

# Loopback alias for this node's own hostname
echo "127.0.1.1 ${hostname}" >> /etc/hosts

# Cluster-wide host entries so all nodes resolve each other by name
cat >> /etc/hosts <<'HOSTS'
# --- Kubernetes cluster nodes ---
${hosts_block}
# --- end cluster nodes ---
HOSTS

# Register the join token with no expiry so workers can join at any time
echo "Registering kubeadm join token (TTL=0)..."
kubeadm token create ${KUBEADM_TOKEN} --ttl 0 >> /var/log/kubeadm-token.log 2>&1 && \
  echo "Token ${KUBEADM_TOKEN} registered." >> /var/log/kubeadm-token.log || \
  echo "Token registration failed (may already exist)." >> /var/log/kubeadm-token.log
EOF
}

# Worker user-data: sets hostname, injects cluster hosts, runs kubeadm join.
# The join command is retried with backoff because the control-plane
# may not be fully initialised when the worker boots.
#
# Args: <hostname> <hosts-block>
worker_userdata() {
  local hostname="$1"
  local hosts_block="$2"
  cat <<EOF
#!/bin/bash
set -e

# Set hostname
hostnamectl set-hostname "${hostname}"

# Loopback alias for this node's own hostname
echo "127.0.1.1 ${hostname}" >> /etc/hosts

# Cluster-wide host entries so all nodes resolve each other by name
cat >> /etc/hosts <<'HOSTS'
# --- Kubernetes cluster nodes ---
${hosts_block}
# --- end cluster nodes ---
HOSTS

# Reset any pre-existing K8s state baked into the AMI so kubeadm join runs clean
echo "Resetting any pre-existing Kubernetes state..."
kubeadm reset -f 2>/dev/null || true
rm -rf /etc/cni/net.d /etc/kubernetes
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
echo "Reset complete."

# Wait for the Kubernetes API server to be reachable before joining
echo "Waiting for Kubernetes API at ${K8S_API_ENDPOINT}..."
for i in \$(seq 1 30); do
  if nc -z ${K8S_API_ENDPOINT%:*} ${K8S_API_ENDPOINT#*:} 2>/dev/null; then
    echo "API server reachable."
    break
  fi
  echo "Attempt \$i/30 — retrying in 10s..."
  sleep 10
done

# Run kubeadm join
kubeadm join ${K8S_API_ENDPOINT} \\
  --token                     ${KUBEADM_TOKEN} \\
  --discovery-token-ca-cert-hash ${DISCOVERY_TOKEN_CA_CERT_HASH} \\
  >> /var/log/kubeadm-join.log 2>&1

echo "kubeadm join completed. See /var/log/kubeadm-join.log for details."
EOF
}

# ─────────────────────────────────────────────
# SCALE-OUT FUNCTION (add more workers later)
# ─────────────────────────────────────────────
#
# Usage: scale_workers <additional-count> <start-index>
# Example: scale_workers 2 3   → creates k8s-worker-3 and k8s-worker-4
#
scale_workers() {
  local count="$1"
  local start_index="$2"
  local new_ids=()

  log "Scaling: adding ${count} worker(s) starting at index ${start_index}..."

  for (( i=0; i<count; i++ )); do
    local idx=$(( start_index + i ))
    local ip_last=$(( WORKER_IP_START + idx - 1 ))
    local worker_ip="${WORKER_IP_BASE}.${ip_last}"
    local worker_name="k8s-worker-${idx}"
    # Build an updated hosts block that includes this new worker
    local scale_hosts_block
    scale_hosts_block="${CP_PRIVATE_IP}  k8s-control-plane"
    for (( j=1; j<idx+i; j++ )); do
      local jip=$(( WORKER_IP_START + j - 1 ))
      scale_hosts_block+=$'\n'"${WORKER_IP_BASE}.${jip}  k8s-worker-${j}"
    done
    local ud
    ud=$(worker_userdata "${worker_name}" "${scale_hosts_block}")

    local id
    id=$(create_instance \
      "${WORKER_AMI}" \
      "${PRIVATE_SUBNET}" \
      "${worker_ip}" \
      "false" \
      "${worker_name}" \
      "worker" \
      "${ud}")

    new_ids+=("${id}")
    log "  Queued: ${worker_name} (${worker_ip}) → ${id}"
  done

  wait_for_instances "${new_ids[@]}"

  echo ""
  log "New worker(s) ready:"
  printf "  %-30s  %-21s  %-25s  %-15s  %s\n" "NAME" "INSTANCE ID" "PRIVATE IP" "PUBLIC IP" "STATE"
  for id in "${new_ids[@]}"; do
    print_instance_info "${id}"
  done
}

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────

main() {
  echo "============================================================"
  echo "  Kubernetes Cluster Provisioner"
  echo "  Profile : ${AWS_PROFILE}"
  echo "  Region  : ${AWS_REGION}"
  echo "  Type    : ${INSTANCE_TYPE}"
  echo "  Workers : ${WORKER_COUNT}"
  echo "============================================================"
  echo ""

  check_deps
  check_aws_auth

  local all_ids=()

  # ── Build the cluster /etc/hosts block ───────────────────────────
  # All nodes receive this block so they can resolve each other by hostname
  # without relying on DNS. Built before any instances are launched because
  # the IPs are statically defined in the config section above.
  local hosts_block
  hosts_block="${CP_PRIVATE_IP}  k8s-control-plane"
  for (( i=1; i<=WORKER_COUNT; i++ )); do
    local ip_last=$(( WORKER_IP_START + i - 1 ))
    hosts_block+=$'\n'"${WORKER_IP_BASE}.${ip_last}  k8s-worker-${i}"
  done

  log "Cluster /etc/hosts block that will be injected into every node:"
  while IFS= read -r line; do
    log "   ${line}"
  done <<< "${hosts_block}"
  echo ""

  # ── Control Plane ────────────────────────────────────────────────
  log "--- Provisioning Control Plane ---"
  local cp_ud
  cp_ud=$(control_plane_userdata "k8s-control-plane" "${hosts_block}")

  local cp_id
  cp_id=$(create_instance \
    "${CP_AMI}" \
    "${PUBLIC_SUBNET}" \
    "${CP_PRIVATE_IP}" \
    "true" \
    "k8s-control-plane" \
    "control-plane" \
    "${cp_ud}")

  all_ids+=("${cp_id}")
  log "  Control plane instance ID: ${cp_id}"
  echo ""

  # ── Worker Nodes ─────────────────────────────────────────────────
  log "--- Provisioning ${WORKER_COUNT} Worker Node(s) ---"
  local worker_ids=()

  for (( i=1; i<=WORKER_COUNT; i++ )); do
    local ip_last=$(( WORKER_IP_START + i - 1 ))
    local worker_ip="${WORKER_IP_BASE}.${ip_last}"
    local worker_name="k8s-worker-${i}"
    local ud
    ud=$(worker_userdata "${worker_name}" "${hosts_block}")

    local wid
    wid=$(create_instance \
      "${WORKER_AMI}" \
      "${PRIVATE_SUBNET}" \
      "${worker_ip}" \
      "false" \
      "${worker_name}" \
      "worker" \
      "${ud}")

    worker_ids+=("${wid}")
    all_ids+=("${wid}")
    log "  Worker ${i}: ${worker_name} (${worker_ip}) → ${wid}"
  done

  echo ""

  # ── Wait for all instances ────────────────────────────────────────
  wait_for_instances "${all_ids[@]}"

  # ── Summary ──────────────────────────────────────────────────────
  echo ""
  echo "============================================================"
  echo "  Cluster instances are running"
  echo "============================================================"
  printf "  %-30s  %-21s  %-25s  %-15s  %s\n" "NAME" "INSTANCE ID" "PRIVATE IP" "PUBLIC IP" "STATE"
  printf "  %-30s  %-21s  %-25s  %-15s  %s\n" "-----" "-----------" "----------" "---------" "-----"
  for id in "${all_ids[@]}"; do
    print_instance_info "${id}"
  done

  echo ""
  echo "------------------------------------------------------------"
  echo "  Next steps:"
  echo ""
  echo "  1. SSH into the control-plane:"
  echo "       ssh ubuntu@<CONTROL_PLANE_PUBLIC_IP>"
  echo ""
  echo "  2. Initialise Kubernetes (if not baked into the AMI):"
  echo "       sudo kubeadm init --apiserver-advertise-address=${CP_PRIVATE_IP} \\"
  echo "         --pod-network-cidr=192.168.0.0/16"
  echo ""
  echo "  3. Workers will join automatically via kubeadm join in user-data."
  echo "     Monitor join progress on each worker:"
  echo "       sudo cat /var/log/kubeadm-join.log"
  echo ""
  echo "  4. Attach IAM role 'k8s-node-ecr-role' to all instances"
  echo "     for ECR image pull access."
  echo ""
  echo "  To add more workers later:"
  echo "     source ${BASH_SOURCE[0]}"
  echo "     scale_workers <count> <start-index>"
  echo "     Example: scale_workers 2 3   # adds k8s-worker-3 and k8s-worker-4"
  echo "------------------------------------------------------------"
}

main "$@"
