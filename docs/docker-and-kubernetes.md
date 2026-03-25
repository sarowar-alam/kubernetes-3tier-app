# How Docker & Kubernetes Fit Together

> Using the **BMI Health Tracker** 3-tier app as a real example.

---

## The Simple Analogy

| Concept | Real-world analogy |
|---|---|
| **Docker** | A shipping container — packages your app and everything it needs into one portable unit |
| **Kubernetes** | A container port / fleet manager — decides where each container runs, restarts it if it crashes, scales it up under load |

Docker builds the container. Kubernetes operates it in production.

---

## Step 1 — Docker: Packaging the App

Before Kubernetes gets involved, Docker turns each tier of the app into a **self-contained image**.

### What a Dockerfile does

A `Dockerfile` is a recipe. It describes:
1. Which base OS/runtime to start from
2. Which files to copy in
3. Which commands to run to install dependencies
4. What process to start when a container launches

### This project's Dockerfiles

**Backend** (`backend/Dockerfile`) — two-stage build:

```
Stage 1 (builder):  node:18-alpine
  └─ COPY package.json
  └─ npm install --only=production
  └─ COPY src/

Stage 2 (runtime):  node:18-alpine  ← clean, minimal image
  └─ Create non-root user (appuser)
  └─ COPY --from=builder /app
  └─ EXPOSE 3000
  └─ CMD ["node", "src/server.js"]
```

**Frontend** (`frontend/Dockerfile`) — two-stage build:

```
Stage 1 (builder):  node:18-alpine
  └─ npm install + vite build → produces /app/dist/

Stage 2 (runtime):  nginx:1.25-alpine  ← only Nginx + static files
  └─ COPY dist/ → /usr/share/nginx/html
  └─ COPY nginx.conf
  └─ EXPOSE 80
```

**Why multi-stage?**  
The build tools (Node, npm, Vite) are only needed to compile the app — they are discarded in the final image. The runtime image is smaller, faster to pull, and has a smaller attack surface.

### The result: Docker Images

After `docker build`, you have two immutable images:

```
bmi-backend:c8f3a21   ← tagged with git short SHA
bmi-frontend:c8f3a21
```

These images are pushed to **AWS ECR** (Elastic Container Registry) — the remote storage that Kubernetes will pull from later.

---

## Step 2 — Kubernetes: Running the App at Scale

Kubernetes picks up where Docker left off. It answers questions Docker doesn't care about:

- On which server (node) should this container run?
- What if the container crashes — restart it?
- How do containers talk to each other?
- How do I expose the app to the internet?
- Where does the database store its data?

### Core Kubernetes concepts used in this project

#### Pods
The smallest unit in Kubernetes. A Pod wraps one (or more) Docker containers and runs on a Node.

```
Pod: bmi-backend-7d4f9c-xk2p1
  └─ Container: bmi-backend (image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:c8f3a21)
```

#### Deployments
A Deployment manages a set of identical Pods. It ensures the desired number of replicas are always running and handles rolling updates.

```yaml
# k8s/backend/deployment.yaml
replicas: 2          ← always keep 2 backend pods running
image: ...bmi-backend:c8f3a21   ← which Docker image to use
```

If one Pod crashes, the Deployment controller immediately starts a replacement.

#### Services
Pods get random IP addresses that change on restarts. A **Service** gives a stable DNS name and load-balances traffic across all matching Pods.

```
bmi-backend-svc (ClusterIP :3000)
  ├─ → Pod bmi-backend-7d4f9c-xk2p1
  └─ → Pod bmi-backend-7d4f9c-m9r3q
```

Three Service types used here:

| Service | Type | Purpose |
|---|---|---|
| `bmi-frontend-svc` | NodePort | Exposes port 30080 to the internet |
| `bmi-backend-svc` | ClusterIP | Internal only — frontend Nginx proxies to it |
| `bmi-postgres-svc` | ClusterIP | Internal only — backend connects to it |

#### StatefulSet
Like a Deployment, but for stateful workloads (databases). It guarantees:
- Stable Pod name (`postgres-0`)
- Stable persistent storage attached to that Pod

Used here for **PostgreSQL** — the database must survive Pod restarts with its data intact.

#### PersistentVolume + PersistentVolumeClaim
Docker containers are ephemeral — their filesystem is wiped when they stop. Kubernetes solves this with volumes.

```
PersistentVolume (postgres-pv)
  └─ hostPath: /data/postgres on k8s-worker-1
       └─ claimed by PersistentVolumeClaim (postgres-pvc)
            └─ mounted into postgres-0 Pod at /var/lib/postgresql/data
```

PostgreSQL data survives Pod restarts and even Node reboots.

#### ConfigMaps & Secrets
Environment variables injected into containers at runtime — no hardcoding in Docker images.

| Object | Used for |
|---|---|
| `backend-config` (ConfigMap) | `NODE_ENV`, `PORT`, `FRONTEND_URL` |
| `backend-secret` (Secret) | `DATABASE_URL` with DB password |
| `postgres-secret` (Secret) | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |

#### Jobs
A one-shot workload that runs to completion. Used here to run SQL migrations after PostgreSQL starts up — guaranteed to run before the backend accepts traffic.

---

## How the Two Work Together — Full Picture

```
┌─────────────────────────────────────────────────────────┐
│  Your machine (development)                             │
│                                                         │
│  docker build → bmi-backend:abc1234                    │
│  docker build → bmi-frontend:abc1234                   │
│  docker push  → AWS ECR                                │
└────────────────────────┬────────────────────────────────┘
                         │  images stored in ECR
                         ▼
┌─────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (AWS EC2)                           │
│                                                         │
│  kubectl apply → Deployment reads image from ECR        │
│                → Schedules Pods on worker node          │
│                → Kubelet pulls Docker image             │
│                → Starts containers                      │
│                                                         │
│  Services  → stable DNS + load balancing between Pods  │
│  Secrets   → DB credentials injected as env vars       │
│  PV/PVC    → PostgreSQL data persisted on disk         │
│  Job       → DB migrations run once on deploy          │
└─────────────────────────────────────────────────────────┘
                         │
                         ▼ NodePort :30080
                    Browser / User
```

---

## The Deployment Pipeline in This Project

```
bash k8s/build-and-push.sh        ← runs on your local machine
  1. docker build (backend + frontend)
  2. docker push → ECR (tagged with git SHA)
  3. sed-patch image tag in deployment YAMLs
  4. git commit + push

bash k8s/deploy.sh                ← runs on the control-plane node
  1. kubectl apply namespace, PV, PVC, secrets
  2. kubectl apply postgres StatefulSet + wait for Ready
  3. kubectl apply migration Job + wait for Complete
  4. kubectl apply backend Deployment + wait for Ready
  5. kubectl apply frontend Deployment + wait for Ready
```

Each deployment is **reproducible and traceable** — the git SHA tag links every running container back to the exact commit that produced it.

---

## Key Takeaways

| Concern | Handled by |
|---|---|
| Packaging app + dependencies | **Docker** (Dockerfile) |
| Storing versioned images | **Docker** + ECR registry |
| Running containers on servers | **Kubernetes** (Pods) |
| Keeping N replicas alive | **Kubernetes** (Deployment) |
| Internal service discovery | **Kubernetes** (ClusterIP Service) |
| External traffic routing | **Kubernetes** (NodePort Service) |
| Persistent database storage | **Kubernetes** (PV + PVC) |
| Config and secrets injection | **Kubernetes** (ConfigMap + Secret) |
| One-time DB setup | **Kubernetes** (Job) |
| Stateful workloads (DB) | **Kubernetes** (StatefulSet) |

**Docker** solves *"how do I package my app?"*  
**Kubernetes** solves *"how do I run it reliably at scale?"*
