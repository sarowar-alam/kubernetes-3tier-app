# Kubernetes Manifests — BMI Health Tracker

A production-ready 3-tier application deployed on a self-managed Kubernetes cluster on AWS EC2.

**Live app:** http://13.127.88.162:30080  
**Repository:** https://github.com/sarowar-alam/kubernetes-3tier-app

---

## Architecture

```
Internet
    │
    ▼
NodePort :30080
    │
    ▼
┌─────────────────────┐
│   Frontend Pod      │  Nginx — serves React SPA
│   (x2 replicas)     │  proxies /api → bmi-backend-svc
└────────┬────────────┘
         │ ClusterIP :3000
         ▼
┌─────────────────────┐
│   Backend Pod       │  Node.js / Express API
│   (x2 replicas)     │  calculates BMI, BMR, calories
└────────┬────────────┘
         │ ClusterIP :5432
         ▼
┌─────────────────────┐
│   PostgreSQL Pod    │  StatefulSet — postgres:14
│   (1 replica)       │  data persisted on worker-1
└─────────────────────┘
```

| Node | IP | Role |
|---|---|---|
| k8s-control-plane | 10.0.5.64 | Kubernetes API, scheduler, etcd |
| k8s-worker-1 | 10.0.130.111 | Runs all application pods |

---

## Directory Structure

```
k8s/
├── namespace.yaml               # bmi-app namespace
├── build-and-push.sh            # LOCAL: build images, push to ECR, commit manifests
├── deploy.sh                    # CLUSTER: deploy all manifests in order
├── setup-ecr-secret.sh          # CLUSTER: create/refresh ECR imagePullSecret
├── setup-ecr-on-nodes.sh        # CLUSTER: install kubelet ECR credential provider
├── postgres/
│   ├── secret.yaml              # DB credentials (gitignored — apply manually)
│   ├── pv.yaml                  # PersistentVolume (hostPath on worker-1)
│   ├── pvc.yaml                 # PersistentVolumeClaim
│   ├── statefulset.yaml         # postgres:14 StatefulSet
│   ├── service.yaml             # ClusterIP service: bmi-postgres-svc:5432
│   ├── migrations-configmap.yaml # SQL migration scripts as ConfigMap
│   └── migration-job.yaml       # One-time Job to run DB migrations
├── backend/
│   ├── secret.yaml              # DATABASE_URL (gitignored — apply manually)
│   ├── configmap.yaml           # NODE_ENV, PORT, FRONTEND_URL
│   ├── deployment.yaml          # Node.js deployment (2 replicas)
│   └── service.yaml             # ClusterIP service: bmi-backend-svc:3000
└── frontend/
    ├── deployment.yaml          # Nginx deployment (2 replicas)
    └── service.yaml             # NodePort service → :30080
```

---

## One-Time Setup

### Step 1 — AWS: Create IAM role and attach to both EC2 instances

**Create the role (AWS Console → IAM → Roles → Create role):**

| Field | Value |
|---|---|
| Trusted entity type | AWS service |
| Use case | EC2 |
| Policy 1 | `AmazonEC2ContainerRegistryReadOnly` — ECR image pulls |
| Policy 2 | `AmazonEC2ReadOnlyAccess` — optional, for debugging |
| Role name | `k8s-node-ecr-role` |

**Attach to both instances:**  
EC2 → Instances → select instance → Actions → Security → Modify IAM role → select `k8s-node-ecr-role`

> Repeat for both `k8s-control-plane` and `k8s-worker-1`.  
> The control-plane needs it to call `aws ecr get-login-password`.  
> Worker nodes need it so kubelet can pull images from ECR.

---

### Step 2 — Worker node: Create postgres data directory

```bash
ssh ubuntu@10.0.130.111
sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres
exit
```

---

### Step 3 — Control-plane: Install AWS CLI

```bash
ssh ubuntu@10.0.5.64
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
unzip -q /tmp/a.zip -d /tmp && sudo /tmp/aws/install
aws --version   # verify
```

---

### Step 4 — Control-plane: Clone repo and apply secrets

```bash
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app

# Apply namespace first, then secrets (these files are gitignored)
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/postgres/secret.yaml   # POSTGRES_PASSWORD
kubectl apply -f k8s/backend/secret.yaml    # DATABASE_URL (password must match above)
```

> **Secret format reference:**
> ```yaml
> # k8s/postgres/secret.yaml
> stringData:
>   POSTGRES_DB:       "bmidb"
>   POSTGRES_USER:     "bmi_user"
>   POSTGRES_PASSWORD: "your-password-here"
>
> # k8s/backend/secret.yaml
> stringData:
>   DATABASE_URL: "postgres://bmi_user:your-password-here@bmi-postgres-svc:5432/bmidb"
> ```

---

### Step 5 — Control-plane: Deploy

```bash
bash k8s/deploy.sh
```

`deploy.sh` runs these steps automatically:

| Step | Action |
|---|---|
| 0 | Refresh ECR imagePullSecret |
| 1 | Create namespace |
| 2 | Deploy PostgreSQL (PV → PVC → StatefulSet → Service) |
| 3 | Run DB migrations (Kubernetes Job) |
| 4 | Deploy backend |
| 5 | Deploy frontend |
| 6 | Print pod status |

---

## Update Workflow

Whenever you change the application code:

**1. Local machine — build and push:**
```bash
bash k8s/build-and-push.sh
```
- Builds both Docker images
- Tags with git SHA (e.g. `bmi-backend:c8c6291`) + `latest`
- Pushes both tags to ECR
- Updates image URLs in deployment YAMLs
- Commits and pushes changes to git automatically

**2. Control-plane — roll out:**
```bash
cd kubernetes-3tier-app && git pull
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app

# Monitor
kubectl rollout status deployment/bmi-backend  -n bmi-app
kubectl rollout status deployment/bmi-frontend -n bmi-app
```

---

## Rollback

```bash
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app
```

---

## Useful Commands

```bash
# Pod status
kubectl get pods -n bmi-app

# Logs
kubectl logs -n bmi-app deploy/bmi-backend
kubectl logs -n bmi-app deploy/bmi-frontend
kubectl logs -n bmi-app postgres-0

# Debug a specific pod
kubectl describe pod -n bmi-app <pod-name>

# Get all resources in the namespace
kubectl get all -n bmi-app

# Manually refresh ECR pull secret (valid 12h, auto-refreshed by deploy.sh)
bash k8s/setup-ecr-secret.sh

# Check backend health
curl http://13.127.88.162:30080/api/measurements
```

---

## Reference

| Item | Value |
|---|---|
| App URL | http://13.127.88.162:30080 |
| AWS Region | ap-south-1 |
| ECR Registry | 388779989543.dkr.ecr.ap-south-1.amazonaws.com |
| ECR Repos | `bmi-backend`, `bmi-frontend` |
| Kubernetes namespace | `bmi-app` |
| DB storage path | `/data/postgres` on k8s-worker-1 |
| ECR token lifetime | 12 hours (auto-refreshed by `deploy.sh`) |
| Secrets in git | Never — apply manually on cluster |

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, Hogarth Worldwide  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
