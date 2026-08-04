# BMI Health Tracker — LoadBalancer (MetalLB) Variant

This folder is an alternative to [`k8s/`](../k8s/README.md) and
[`k8s-ingress/`](../k8s-ingress/README.md): identical app manifests, but the
frontend `Service` is `type: LoadBalancer`, fulfilled by **MetalLB** (since
this kubeadm cluster has no cloud-controller-manager to satisfy it natively —
see the comments in `service-loadbalancer.yaml` in the kubernetes-fundamentals
lab repo), fronted by a manually-created **AWS Network Load Balancer**.

> **Do not apply `k8s/`, `k8s-argocd/`, `k8s-ingress/` and `k8s-LoadBalancer/`
> to the same cluster at the same time.** They all use the same namespace
> (`bmi-app`), the same PostgreSQL hostPath (`/data/postgres`) and the same
> node label (`role=postgres-storage`) — these are alternative deployment
> methods for the same app, not meant to coexist.
>
> For everything not called out below (build/push workflow, secrets, rollback,
> troubleshooting, migrations), see [`k8s/README.md`](../k8s/README.md) — the
> steps are identical, only the folder name changes from `k8s/` to `k8s-LoadBalancer/`.

---

## Why MetalLB?

A plain `Service type=LoadBalancer` (see the referenced
`service-loadbalancer.yaml`) only works out of the box on managed Kubernetes
(EKS/GKE/AKS) where a cloud controller-manager watches for `LoadBalancer`
Services and provisions a real cloud LB. On a self-managed kubeadm cluster
there is no such controller — the Service would stay `Pending` forever.
**MetalLB** plugs that gap: it watches for `LoadBalancer` Services and assigns
each one a virtual IP (VIP) from a configured address pool, then announces
that VIP on the local network (Layer 2 / ARP mode here) so traffic to it
reaches whichever node is currently the "leader" for that VIP.

**Important caveat:** the VIP MetalLB assigns is a **private IP inside your
VPC subnet** — it is NOT internet-reachable by itself. To expose it publicly,
this variant pairs MetalLB with a manually-created **AWS NLB using a
target group of type `ip`**, pointing directly at the MetalLB VIP. The NLB
gives you a real public DNS name; MetalLB's automatic node failover happens
transparently underneath it (the NLB just keeps hitting the same VIP,
regardless of which node currently owns it).

Traffic flow:
```
Browser → AWS NLB (manual, public DNS name)
  └─ target group (type: ip) → MetalLB VIP (private, e.g. 10.0.10.24x)
       └─ whichever node's speaker currently owns the VIP (L2/ARP)
            └─ bmi-frontend-svc (LoadBalancer) → Nginx pod :80
                 └─ /api/* proxied → bmi-backend-svc:3000
                      └─ bmi-postgres-svc:5432 → PostgreSQL StatefulSet
```

---

## What's different from `k8s/`

| | `k8s/` | `k8s-LoadBalancer/` |
|---|---|---|
| Frontend Service | `NodePort` (`80:30080/TCP`) | `LoadBalancer` |
| External IP source | none (NodePort on node IPs) | MetalLB (`metallb-system` namespace, L2 mode) |
| Public access | `http://<MASTER-PUBLIC-IP>:30080` | AWS NLB DNS name (manual, see below) |
| New resources | — | `metallb/install-metallb.sh`, `metallb/ipaddresspool.yaml`, `metallb/l2advertisement.yaml` |
| `/api` routing | nginx `proxy_pass` inside the frontend pod (unchanged) | same, unchanged |
| TLS | none | none (out of scope for this variant too) |

---

## Deploy

```bash
# On the control-plane node, from the repo root
bash k8s-LoadBalancer/deploy.sh
```

This runs the same phases as `k8s/deploy.sh` (prerequisites → ECR secret →
PostgreSQL → migrations → backend), plus two LoadBalancer-specific phases:

| Phase | What happens |
|---|---|
| [5/6] MetalLB | Runs `k8s-LoadBalancer/metallb/install-metallb.sh` — installs the MetalLB native manifest, waits for `controller`/`speaker` rollout, then applies the `IPAddressPool` and `L2Advertisement` |
| [6/6] Frontend | Applies the `LoadBalancer` frontend Service, waits for rollout, then polls for an `EXTERNAL-IP` (up to 60s) |

**Verify:**
```bash
kubectl get pods -n metallb-system
# Expected: controller-xxxxx 1/1 Running, speaker-xxxxx (one per node) 1/1 Running

kubectl get ipaddresspool,l2advertisement -n metallb-system
# Expected: bmi-pool, bmi-l2adv

kubectl get svc bmi-frontend-svc -n bmi-app
# Expected: TYPE=LoadBalancer   EXTERNAL-IP=<an IP from your pool>   PORT(S)=80:xxxxx/TCP

curl http://<EXTERNAL-IP>/
# Expected: frontend HTML (only reachable from inside the VPC at this point)
```

---

## Choosing the address pool range

[`metallb/ipaddresspool.yaml`](metallb/ipaddresspool.yaml) ships with a
**guessed placeholder range** (`10.0.10.240-10.0.10.250`, based on the
`10.0.10.34` master IP referenced in `k8s/README.md`'s cluster topology
table). **Verify it's actually free in your subnet before deploying:**

```bash
# List every private IP already in use in your VPC (instances + ENIs)
aws ec2 describe-network-interfaces --region ap-south-1 --profile sarowar-ostad \
  --query 'NetworkInterfaces[].PrivateIpAddress' --output table

# Confirm your master/worker subnet CIDR
aws ec2 describe-subnets --region ap-south-1 --profile sarowar-ostad \
  --subnet-ids <PUBLIC_SUBNET_ID> --query 'Subnets[0].CidrBlock' --output text
```

Pick a range inside that CIDR that appears in neither list, avoiding the
first 4 and last 1 addresses of the CIDR block (AWS reserves those). Update
`metallb/ipaddresspool.yaml` accordingly before running `deploy.sh`.

---

## Create the AWS Network Load Balancer (manual, one-time)

Once `bmi-frontend-svc` has an `EXTERNAL-IP` from MetalLB:

1. **Target group** — type **IP**, protocol TCP (or HTTP), port **80**.
   Register the MetalLB `EXTERNAL-IP` itself as the single target (not the
   EC2 instances — the VIP already floats between nodes via MetalLB's own
   failover, so the NLB doesn't need to know which node currently owns it).
2. **Health check** — HTTP, path `/`, expect `200`.
3. **Load balancer** — internet-facing **Network Load Balancer**, placed in
   the public subnet (same VPC as the cluster — NLB target type `ip` requires
   targets to be reachable from the LB's subnets).
4. **Listener** — TCP/HTTP port `80` → forward to the target group above.
5. **Security group** — ensure the instances' SG allows inbound TCP `80` from
   the NLB (same VPC traffic, or the NLB's subnet CIDR if using a dedicated SG).
6. **Test:**
   ```bash
   curl http://<NLB-DNS-NAME>/
   curl http://<NLB-DNS-NAME>/api/measurements
   ```

> If the MetalLB `EXTERNAL-IP` ever changes (e.g. pool edited, Service
> recreated), the NLB target group's registered IP must be updated to match.

Optionally update `FRONTEND_URL` in [`backend/configmap.yaml`](backend/configmap.yaml)
to the NLB's DNS name — purely cosmetic, CORS is moot since nginx proxies
`/api` same-origin (see `k8s/README.md` design decisions).

---

## Design Decisions (delta from `k8s/README.md`)

**Why MetalLB instead of NodePort or ingress-nginx?**
Demonstrates the native `Service type=LoadBalancer` workflow on a self-managed
cluster — the closest bare-metal equivalent to what EKS/GKE/AKS give you
automatically. `k8s/`'s NodePort and `k8s-ingress/`'s ingress-nginx variants
are kept unchanged for comparison.

**Why Layer 2 mode instead of BGP?**
BGP requires a BGP-speaking router peer, which plain AWS EC2 doesn't provide
without extra infrastructure. L2 mode works out of the box on any flat subnet,
including AWS VPC subnets, using ARP-based failover between nodes.

**Why target type `ip` (pointing at the MetalLB VIP) instead of target type
`instance` + NodePort (like `k8s-ingress/`)?**
The MetalLB VIP already floats between nodes automatically — targeting it
directly means the NLB target group never needs to know which physical node
is currently serving traffic, matching how `Service type=LoadBalancer` is
meant to behave.
