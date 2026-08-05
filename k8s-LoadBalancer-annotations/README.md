# BMI Health Tracker — LoadBalancer (AWS Load Balancer Controller) Variant

This folder is an alternative to [`k8s-LoadBalancer/`](../k8s-LoadBalancer/README.md):
same app, same `Service type=LoadBalancer` frontend, but instead of
**MetalLB + a manually-created AWS NLB**, this variant installs the
**[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)**
in-cluster. The controller watches the Service's annotations and calls the
AWS API directly — `kubectl apply` alone provisions a *real* NLB, and
`kubectl delete` tears it down. No manual target-group work, ever.

> **Do not apply `k8s/`, `k8s-argocd/`, `k8s-ingress/`, `k8s-LoadBalancer/` and
> `k8s-LoadBalancer-annotations/` to the same cluster at the same time.**
> They share the same namespace (`bmi-app`), PostgreSQL hostPath
> (`/data/postgres`) and node label (`role=postgres-storage`).

---

## Why this variant exists

[`k8s-LoadBalancer/`](../k8s-LoadBalancer/README.md) works, but required a
real production troubleshooting session to get there:

- MetalLB's L2/ARP-announced VIP is reachable from **EC2 instances** (their
  kernels do real ARP resolution), but an **AWS NLB cannot route to it** — the
  NLB only knows about real, ENI-registered IPs. Pointing an NLB target group
  at the MetalLB VIP leaves the target permanently `unhealthy`.
- The working fix was to bypass MetalLB for the *public* path entirely:
  register the 3 nodes' real private IPs on the frontend `NodePort` as NLB
  targets instead — which then has to be **kept in sync by hand** whenever a
  node is replaced.

This variant removes that whole class of problem: the **AWS Load Balancer
Controller** manages the NLB and its target group automatically, adding and
removing real node IPs as the cluster changes — no MetalLB, no manual
`register-targets`/`deregister-targets`, no VIP-vs-NLB ARP mismatch.

Traffic flow:
```
Browser → AWS NLB (auto-provisioned by the controller, real public DNS name)
  └─ target group (type: instance, auto-managed) → node NodePort
       └─ kube-proxy on whichever node received the packet
            └─ bmi-frontend-svc (LoadBalancer, NodePort) → Nginx pod :80
                 └─ /api/* proxied → bmi-backend-svc:3000
                      └─ bmi-postgres-svc:5432 → PostgreSQL StatefulSet
```

---

## What's different from `k8s-LoadBalancer/`

| | `k8s-LoadBalancer/` | `k8s-LoadBalancer-annotations/` |
|---|---|---|
| LB provisioning | Manual (AWS Console/CLI, one-time) | Automatic (`kubectl apply` triggers it) |
| Component providing `EXTERNAL-IP` | MetalLB (private VIP only) | AWS Load Balancer Controller (real NLB) |
| NLB target group upkeep | Manual — re-run `register-targets` if a node changes | Automatic — controller reconciles targets continuously |
| Extra cluster components | MetalLB (`metallb-system`) | AWS Load Balancer Controller + cert-manager (`kube-system`/`cert-manager`) |
| Extra AWS setup | None beyond manual NLB creation | IAM policy on node role + subnet tagging (one-time) |
| Failure mode this avoids | NLB→VIP ARP mismatch (see above) | N/A — targets real node IPs from the start |

---

## Prerequisites

Everything from [`k8s-LoadBalancer/README.md`'s Prerequisites](../k8s-LoadBalancer/README.md#prerequisites)
section applies here too (Docker, AWS CLI, ECR repos, IAM role for ECR
pulls, `/data/postgres` on a worker node, etc.) — refer to it for those
steps. This section only covers what's **additionally** required for the
AWS Load Balancer Controller.

### 1. Find your node IAM role name

```bash
aws ec2 describe-instances --instance-ids <any-node-instance-id> \
  --profile sarowar-ostad --region ap-south-1 \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
# arn:aws:iam::388779989543:instance-profile/<profile-name>

aws iam get-instance-profile --instance-profile-name <profile-name> \
  --profile sarowar-ostad \
  --query 'InstanceProfile.Roles[0].RoleName' --output text
```

### 2. Find your public subnet IDs and VPC ID

```bash
aws ec2 describe-subnets --region ap-south-1 --profile sarowar-ostad \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
  --query "Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" --output table
```
Pick the subnet(s) your control-plane node (and any node you want the NLB
reachable from) actually lives in.

---

## Part 1 — One-time AWS Load Balancer Controller setup

### Step 1 — Local machine: IAM policy + subnet tagging

> **Directory: local machine — kubernetes-3tier-app/**

```bash
AWS_PROFILE=sarowar-ostad \
NODE_ROLE_NAME=<role-name-from-prerequisites> \
VPC_ID=<your-vpc-id> \
CLUSTER_NAME=bmi-k8s-lab \
PUBLIC_SUBNET_IDS="<subnet-id-1> <subnet-id-2>" \
bash k8s-LoadBalancer-annotations/aws-lb-controller/setup-iam-and-subnets.sh
```

This creates the `AWSLoadBalancerControllerIAMPolicy` IAM policy (from
[`aws-lb-controller/iam-policy.json`](aws-lb-controller/iam-policy.json)),
attaches it to your existing node role (the same role all 3 EC2 instances
already use for ECR pulls), and tags your public subnets with
`kubernetes.io/role/elb=1` + `kubernetes.io/cluster/<name>=owned` so the
controller can auto-discover where to place the NLB.

### Step 2 — Control-plane: install the controller

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
git pull
CLUSTER_NAME=bmi-k8s-lab VPC_ID=<your-vpc-id> AWS_REGION=ap-south-1 \
bash k8s-LoadBalancer-annotations/aws-lb-controller/install-controller.sh
```

This installs Helm (if missing), cert-manager (the controller's webhook TLS
dependency), and the controller itself via the `eks-charts` Helm repo —
using manual `clusterName`/`vpcId`/`region` flags since this is a
self-managed kubeadm cluster, not real EKS (no control-plane API to
auto-discover these values from).

**Verify:**
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
# Expect 2 Running pods
```

### Step 3 — Fill in your subnet IDs

Edit [`frontend/service.yaml`](frontend/service.yaml) and replace the
placeholder in the `aws-load-balancer-subnets` annotation with your real
public subnet IDs from the Prerequisites step:
```yaml
service.beta.kubernetes.io/aws-load-balancer-subnets: "subnet-XXXXXXXX,subnet-YYYYYYYY"
```
Commit this change before running `deploy.sh` — the controller reads it
directly from the Service object at apply time.

---

## Part 2 — Deploy the app

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
bash k8s-LoadBalancer-annotations/deploy.sh
```

`deploy.sh` follows the same 6-phase flow as `k8s-LoadBalancer/deploy.sh`
(Phase 0 prerequisites, then `[1/6]`–`[6/6]`), except:
- `[5/6]` **checks** that the AWS Load Balancer Controller is installed
  (fails fast with instructions if it isn't — it doesn't install it, since
  that requires the local-machine IAM step first).
- `[6/6]` applies the frontend `Service`/`Deployment` and polls
  `status.loadBalancer.ingress[0].hostname` (a real DNS name, not an IP) for
  up to 180s while the controller provisions the NLB.

**Expected final output:**
```
✅ App URL: http://<generated>-<hash>.elb.ap-south-1.amazonaws.com/
```
That URL is immediately internet-reachable — no NLB/target-group step needed.

---

## Update Workflow (Every Code Change)

Same as [`k8s-LoadBalancer/`'s Update Workflow](../k8s-LoadBalancer/README.md#update-workflow-every-code-change):

```bash
# Local machine
bash k8s-LoadBalancer-annotations/build-and-push.sh

# Control-plane
git pull && bash k8s-LoadBalancer-annotations/deploy.sh
```

The NLB and its target group are **fully managed by the controller** — no
manual re-registration ever needed, even if a node is replaced.

---

## Useful Commands

```bash
# Controller health and logs (check here first if the NLB never appears)
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=100

# Frontend Service — hostname appears once the NLB is provisioned
kubectl get svc bmi-frontend-svc -n bmi-app -w

# Describe the Service — shows controller reconcile events if something's wrong
kubectl describe svc bmi-frontend-svc -n bmi-app
```

**NLB never gets a hostname?** Check, in order: (1) controller pods are
`Running` (`kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`),
(2) controller logs for IAM permission errors (`AccessDenied` means the
policy from Step 1 isn't attached to the right role), (3) the subnet IDs in
`frontend/service.yaml`'s annotation actually exist and are tagged
(`kubernetes.io/role/elb=1`), (4) `kubectl describe svc bmi-frontend-svc -n bmi-app`
for reconcile error events.

---

## Design Decisions

**Why the AWS Load Balancer Controller instead of fixing `k8s-LoadBalancer/`'s
manual NLB?**
Both reach the same end state (a real, internet-facing NLB fronting the
app), but this variant demonstrates the more "cloud-native" pattern closer
to what EKS gives you by default — the controller is the same one EKS users
install (or get pre-installed via EKS add-ons). Keeping `k8s-LoadBalancer/`
unchanged preserves it as the "manual, understand every AWS API call"
teaching variant; this folder is the "automate it properly" follow-up.

**Why `aws-load-balancer-nlb-target-type: instance` instead of `ip`?**
`instance` target type registers the actual EC2 instances on the Service's
NodePort automatically — conceptually identical to the manual fix applied
in `k8s-LoadBalancer/` (register real node IPs, not a floating VIP), except
the controller keeps it in sync automatically as nodes join/leave.

**Why is MetalLB not used here at all?**
It's unnecessary — the controller talks to the real AWS API to provision a
real NLB directly, so there's no need for an in-cluster VIP mechanism to
bridge the "no cloud-controller-manager" gap. MetalLB's job (giving
`type=LoadBalancer` Services a working `EXTERNAL-IP`) is fully replaced by
the controller's own reconciliation.

**Why is IAM policy attachment a separate, local-machine-only script?**
Attaching a permissive IAM policy to a role is itself a privileged
operation — it should be done with your own admin AWS credentials, not
from a script running on the cluster nodes.

---

## Reference

| Item | Value |
|---|---|
| App URL | Real AWS NLB DNS name — appears automatically in `kubectl get svc bmi-frontend-svc -n bmi-app` |
| ECR registry | 388779989543.dkr.ecr.ap-south-1.amazonaws.com |
| Kubernetes namespace | bmi-app |
| PostgreSQL data path | `/data/postgres` on the node labelled `role=postgres-storage` |
| PV reclaim policy | Retain — data not deleted on pod/PVC deletion |
| Image tag strategy | git short SHA — unique per commit |
| ECR token lifetime | 12 hours — must refresh before deploying |
| Extra IAM policy | `AWSLoadBalancerControllerIAMPolicy`, attached to the shared node role |
| Extra cluster components | cert-manager, aws-load-balancer-controller (both in scope beyond `k8s-LoadBalancer/`) |
| NLB target group | type `instance`, auto-managed by the controller — no manual updates ever |

---

## Project Lead

Sarowar Alam — Ostad DevOps Mastering Program
