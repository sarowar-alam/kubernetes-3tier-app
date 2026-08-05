# BMI Health Tracker — Ingress + AWS Load Balancer Variant

This folder is an alternative to [`k8s/`](../k8s/README.md): identical app manifests, but the
frontend is exposed via **ingress-nginx + an Ingress resource** instead of a
frontend `NodePort`, fronted by a manually-created **AWS Load Balancer**.

> **Do not apply `k8s/` and `k8s-ingress/` to the same cluster at the same time.**
> Both use the same namespace (`bmi-app`), the same PostgreSQL hostPath
> (`/data/postgres`) and the same node label (`role=postgres-storage`) — they
> are alternative deployment methods for the same app, not meant to coexist.
>
> For everything not called out below (build/push workflow, secrets, rollback,
> troubleshooting, migrations), see [`k8s/README.md`](../k8s/README.md) — the
> steps are identical, only the folder name changes from `k8s/` to `k8s-ingress/`.

---

## What's different from `k8s/`

| | `k8s/` | `k8s-ingress/` |
|---|---|---|
| Frontend Service | `NodePort` (`80:30080/TCP`) | `ClusterIP` |
| External entry point | Frontend NodePort directly | ingress-nginx controller (NodePort 30080) → Ingress → frontend Service |
| Public access | `http://<MASTER-PUBLIC-IP>:30080` | AWS Load Balancer DNS name (manual, see below) |
| New resources | — | `ingress/bmi-ingress.yaml`, `ingress/install-ingress-nginx.sh` |
| `/api` routing | nginx `proxy_pass` inside the frontend pod (unchanged) | same — Ingress only forwards `/` to the frontend Service |
| TLS | none | none (out of scope for this variant too) |

Traffic flow:
```
Browser → AWS Load Balancer (manual)
  └─ NodePort :30080 on any node → ingress-nginx-controller
       └─ Ingress "bmi-ingress" (path /) → bmi-frontend-svc (ClusterIP) → Nginx pod :80
            └─ /api/* proxied → bmi-backend-svc:3000
                 └─ bmi-postgres-svc:5432 → PostgreSQL StatefulSet
```

---

## Deploy

> **Prerequisite: SSH agent forwarding.** `deploy.sh` SSHes from the master into
> worker-1 (`ensure_worker_storage()`) to create `/data/postgres`. All 3 nodes
> share the same EC2 key pair, but the private key lives on your **local**
> machine, not on the master — so you must forward your local agent when
> connecting, otherwise this step fails with `Permission denied (publickey)`:
> ```bash
> # On your local machine, before SSHing in
> eval "$(ssh-agent -s)"
> ssh-add /path/to/sarowar-ostad-mumbai.pem
> ssh -A ubuntu@<MASTER-PUBLIC-IP>   # -A forwards the agent to the master
> ```

```bash
# On the control-plane node, from the repo root
bash k8s-ingress/deploy.sh
```

This runs the same phases as `k8s/deploy.sh` (prerequisites → ECR secret →
PostgreSQL → migrations → backend), plus two ingress-specific phases:

| Phase | What happens |
|---|---|
| [5/6] Ingress controller | Runs `k8s-ingress/ingress/install-ingress-nginx.sh` — installs the bare-metal ingress-nginx manifest, waits for its rollout, then pins the controller's Service to NodePort **30080** (http) |
| [6/6] Frontend + Ingress | Applies the `ClusterIP` frontend Service and `ingress/bmi-ingress.yaml` |

### Manual deployment (without `deploy.sh`)

Phase 0 and steps `[1/6]`–`[4/6]` (prerequisites, namespace, secrets,
ECR secret, PostgreSQL, migrations, backend) are identical to
[`k8s/README.md`'s Part 2](../k8s/README.md#part-2--deploy-without-automation-scripts-full-manual) —
substitute `k8s/` with `k8s-ingress/` in every file path. Only the two
phases below are unique to this variant:

**`[5/6]` Install ingress-nginx controller**
```bash
INGRESS_NGINX_VERSION=controller-v1.11.3
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"

kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s

# Pin the http port to NodePort 30080 — full ports replace keeps http/https
# internally consistent regardless of upstream manifest ordering
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=merge -p '{
  "spec": {
    "ports": [
      {"name": "http",  "port": 80,  "targetPort": "http",  "protocol": "TCP", "nodePort": 30080},
      {"name": "https", "port": 443, "targetPort": "https", "protocol": "TCP"}
    ]
  }
}'
```

**`[6/6]` Frontend (ClusterIP) + Ingress**
```bash
kubectl apply -f k8s-ingress/frontend/deployment.yaml
kubectl apply -f k8s-ingress/frontend/service.yaml
kubectl rollout status deployment/bmi-frontend -n bmi-app --timeout=90s

kubectl apply -f k8s-ingress/ingress/bmi-ingress.yaml
```

**Verify:**
```bash
kubectl get pods -n ingress-nginx
# Expected: ingress-nginx-controller-xxxxx   1/1   Running

kubectl get svc -n ingress-nginx ingress-nginx-controller
# Expected: TYPE=NodePort   PORT(S)=80:30080/TCP,443:xxxxx/TCP

kubectl get ingress -n bmi-app
# Expected: bmi-ingress   nginx   *   <node-ip(s)>   80

kubectl get svc -n bmi-app bmi-frontend-svc
# Expected: TYPE=ClusterIP (no NodePort)

curl http://<any-node-ip>:30080/
# Expected: frontend HTML
```

---

## Create the AWS Load Balancer (manual, one-time)

There is no cloud-controller-manager on this kubeadm cluster, so a Kubernetes
`Service type=LoadBalancer` cannot auto-provision anything — the AWS Load
Balancer must be created directly via the AWS Console/CLI, the same way the
ECR IAM role is a manual, documented step.

Unlike `k8s-LoadBalancer/` and `k8s-LoadBalancer-annotations/`, this variant
needs only **one** target group/listener pair (port 30080 → 80), because
ingress-nginx's NodePort is the single entry point for all HTTP traffic.

### Option A — AWS CLI (what was actually run)

Replace the IDs/subnets below with your cluster's own (see
`k8s-cluster-state.env` at the repo root, and `aws ec2 describe-instances` to
confirm VPC/subnet/security-group if the cluster was rebuilt).

```bash
VPC_ID=vpc-0fb1f03806261b9ec
SG_ID=sg-0daa5c936d47c169a
# Two subnets with a route to an Internet Gateway (check via
# `aws ec2 describe-route-tables` — the NLB itself needs public subnets,
# even though the worker instances it targets can sit in private subnets)
PUBLIC_SUBNET_A=subnet-0b88d7678355c6163   # ap-south-1a
PUBLIC_SUBNET_B=subnet-092082346b72435a2   # ap-south-1b
MASTER_ID=i-0bd050568c3d523b9
WORKER1_ID=i-01df20fa8c714ef58
WORKER2_ID=i-017fa44c2de4f6a2b

# 1. Open NodePort 30080 on the shared security group (the NLB forwards the
#    client's real source IP straight through — it has no SG of its own).
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 30080 --cidr 0.0.0.0/0

# 2. Target group — type Instance, TCP:30080, HTTP health check on "/".
TG_ARN=$(aws elbv2 create-target-group \
  --name bmi-ingress-tg --protocol TCP --port 30080 --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP --health-check-path / --health-check-port 30080 \
  --query "TargetGroups[0].TargetGroupArn" --output text)

# 3. Register all 3 nodes — NodePort 30080 is open on every node regardless
#    of which one the ingress-nginx pod lands on.
aws elbv2 register-targets --target-group-arn "$TG_ARN" \
  --targets Id=$MASTER_ID Id=$WORKER1_ID Id=$WORKER2_ID

# 4. Internet-facing Network Load Balancer, spanning both public subnets.
LB_ARN=$(aws elbv2 create-load-balancer \
  --name bmi-ingress-nlb --type network --scheme internet-facing \
  --subnets "$PUBLIC_SUBNET_A" "$PUBLIC_SUBNET_B" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

# 5. Listener — TCP port 80 → forward to the target group above.
aws elbv2 create-listener --load-balancer-arn "$LB_ARN" \
  --protocol TCP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"

# 6. Wait for targets to go "healthy" (takes ~1-2 min), then get the DNS name.
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State]" --output table
aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text
```

### Option B — AWS Console

1. **Target group** — type **Instance**, protocol TCP (or HTTP), port **30080**.
   Register all 3 EC2 instances (master, worker-1, worker-2).
2. **Health check** — HTTP, path `/`, expect `200`.
3. **Load balancer** — internet-facing **Network Load Balancer**, placed in the
   public subnet(s).
4. **Listener** — TCP/HTTP port `80` → forward to the target group above.
5. **Security group** — confirm inbound `30080` is allowed on the instances'
   security group (the NLB itself doesn't have one; traffic arrives with the
   client's original source IP).

### Test (either option)

```bash
curl http://<LB-DNS-NAME>/
curl http://<LB-DNS-NAME>/api/measurements
```

Confirmed working example from this cluster:
`http://bmi-ingress-nlb-304db88d013ab401.elb.ap-south-1.amazonaws.com/` →
both `/` and `/api/measurements` return `HTTP 200`, all 3 targets `healthy`.

Optionally update `FRONTEND_URL` in [`backend/configmap.yaml`](backend/configmap.yaml)
to the LB's DNS name — purely cosmetic, CORS is moot since nginx proxies `/api`
same-origin (see `k8s/README.md` design decisions).

---

## Design Decisions (delta from `k8s/README.md`)

**Why ingress-nginx + a manual AWS LB instead of plain NodePort?**
Gives a stable, single DNS-named entry point in front of the cluster and a
foundation for host/path-based routing or TLS later, without needing a cloud
Kubernetes provider. `k8s/`'s original NodePort-only rationale (single worker
node, no LB controller) still applies to that variant, which is kept unchanged
for comparison.

**Why isn't `/api` routed through the Ingress?**
Kept identical to `k8s/`: the frontend's `nginx.conf` already proxies `/api/*`
to `bmi-backend-svc` same-origin. Duplicating that logic as an Ingress path
rule would add a second place to keep in sync for no functional benefit.

**Why is the ingress-nginx manifest applied from a pinned upstream URL instead
of vendored into this repo?**
Keeps the repo lean — the same approach this repo already uses for Calico,
which is installed by `master-init.sh` outside this app's manifests entirely.

---

## Teardown

Reverse order: remove the app + ingress-nginx from the cluster first, then
delete the AWS-side NLB/target group — this avoids leaving dead targets
registered against a target group nothing points to anymore.

### Step 1 — Control-plane: app + ingress-nginx

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
NAMESPACE=bmi-app

kubectl delete -f k8s-ingress/ingress/bmi-ingress.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/frontend/service.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/frontend/deployment.yaml --ignore-not-found=true

# Delete via the SAME manifest URL used to install it, so cluster-scoped
# objects (ClusterRole, ClusterRoleBinding, IngressClass,
# ValidatingWebhookConfiguration) are cleaned up too, not just the namespace
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml --ignore-not-found=true

kubectl delete -f k8s-ingress/backend/service.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/backend/deployment.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/backend/configmap.yaml --ignore-not-found=true

kubectl delete job bmi-migrations -n "$NAMESPACE" --ignore-not-found=true
kubectl delete -f k8s-ingress/postgres/migrations-configmap.yaml --ignore-not-found=true

kubectl delete -f k8s-ingress/postgres/service.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/postgres/statefulset.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/postgres/pvc.yaml --ignore-not-found=true
kubectl delete -f k8s-ingress/postgres/pv.yaml --ignore-not-found=true
# PV reclaim policy is Retain — /data/postgres data on worker-1 is preserved

kubectl delete secret postgres-secret backend-secret ecr-credentials -n "$NAMESPACE" --ignore-not-found=true
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

kubectl label node <WORKER-1-NODE-NAME> role- 2>/dev/null || true
```

### Step 2 — Local machine: delete the NLB, listener, and target group

> **Directory: local machine — kubernetes-3tier-app/**

```bash
# Listener(s) must be deleted before the load balancer
LB_ARN=$(aws elbv2 describe-load-balancers --names bmi-ingress-nlb \
  --profile sarowar-ostad --region ap-south-1 \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
  --profile sarowar-ostad --region ap-south-1 \
  --query "Listeners[].ListenerArn" --output text | \
  xargs -n1 -I{} aws elbv2 delete-listener --profile sarowar-ostad --region ap-south-1 --listener-arn {}

aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" \
  --profile sarowar-ostad --region ap-south-1

# Wait for full deletion before removing the target group (a target group
# still attached to a deleting LB can't be removed)
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$LB_ARN" \
  --profile sarowar-ostad --region ap-south-1

TG_ARN=$(aws elbv2 describe-target-groups --names bmi-ingress-tg \
  --profile sarowar-ostad --region ap-south-1 \
  --query "TargetGroups[0].TargetGroupArn" --output text)
aws elbv2 delete-target-group --target-group-arn "$TG_ARN" \
  --profile sarowar-ostad --region ap-south-1
```

> **Leave the `30080/tcp` security-group rule in place** if you plan to
> deploy the plain `k8s/` NodePort variant next — it reuses the exact same
> port. Only remove it (`aws ec2 revoke-security-group-ingress ...`) once no
> variant using NodePort 30080 is running.

**Verify:**
```bash
aws elbv2 describe-load-balancers --names bmi-ingress-nlb --profile sarowar-ostad --region ap-south-1
# Expected: An error occurred (LoadBalancerNotFound) ...

aws elbv2 describe-target-groups --names bmi-ingress-tg --profile sarowar-ostad --region ap-south-1
# Expected: An error occurred (TargetGroupNotFound) ...
```
