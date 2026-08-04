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
Balancer must be created directly in the AWS Console/CLI, the same way the
ECR IAM role is a manual, documented step.

1. **Target group** — type **Instance**, protocol TCP (or HTTP), port **30080**.
   Register all 3 EC2 instances (master, worker-1, worker-2) — NodePort 30080
   is open on every node regardless of which one the ingress-nginx pod lands on.
2. **Health check** — HTTP, path `/`, expect `200`.
3. **Load balancer** — internet-facing **Network Load Balancer**, placed in the
   public subnet.
4. **Listener** — TCP/HTTP port `80` → forward to the target group above.
5. **Security group** — confirm inbound `30080` is already allowed (it is, since
   NodePort 30080 is the same port the `k8s/` variant already uses for direct access).
6. **Test:**
   ```bash
   curl http://<LB-DNS-NAME>/
   curl http://<LB-DNS-NAME>/api/measurements
   ```

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
