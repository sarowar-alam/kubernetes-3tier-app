# BMI Health Tracker — Complete Deployment Guide (V2)

**Repo:** https://github.com/sarowar-alam/kubernetes-3tier-app  
**App URL:** http://13.127.88.162:30080  
**Namespace:** `bmi-app`

This document covers the **full deployment from zero** — AWS setup, Kubernetes cluster prerequisites, building and pushing images, and deploying all application tiers. Follow every step in order.

---

## Table of Contents

1. [Infrastructure Overview](#1-infrastructure-overview)
2. [AWS Prerequisites (One-Time)](#2-aws-prerequisites-one-time)
3. [Local Machine Prerequisites (One-Time)](#3-local-machine-prerequisites-one-time)
4. [Control-Plane Node Setup (One-Time)](#4-control-plane-node-setup-one-time)
5. [Worker Node Setup (One-Time)](#5-worker-node-setup-one-time)
6. [Clone Repo and Prepare Secrets](#6-clone-repo-and-prepare-secrets)
7. [Build and Push Docker Images — `build-and-push.sh`](#7-build-and-push-docker-images--build-and-pushsh)
8. [Deploy to Kubernetes — `deploy.sh`](#8-deploy-to-kubernetes--deploysh)
9. [Verify the Deployment](#9-verify-the-deployment)
10. [Update Workflow (Every Code Change)](#10-update-workflow-every-code-change)
11. [Rollback](#11-rollback)
12. [Useful Commands](#12-useful-commands)
13. [Reference](#13-reference)

---

## 1. Infrastructure Overview

```
Browser → http://13.127.88.162:30080  (NodePort on control-plane — public subnet)
  └─ bmi-frontend-svc  → Nginx pod :80
       └─ /api/*  proxied  → bmi-backend-svc:3000
            └─ bmi-postgres-svc:5432  → PostgreSQL StatefulSet
```

> **Network topology:** The control-plane is in a **public subnet** and is the external entry point. The worker node is in a **private subnet** — it has no public IP and is not directly reachable from the internet. Kubernetes NodePort is exposed on **all** cluster nodes, so the public IP of the control-plane serves external traffic on port 30080.

| Node | Private IP | Public IP | Subnet | Role |
|---|---|---|---|---|
| k8s-control-plane | 10.0.5.64 | 13.127.88.162 | Public | API server, scheduler, etcd, NodePort entry |
| k8s-worker-1 | 10.0.130.111 | — (none) | Private | Runs all pods, PostgreSQL storage |

| Resource | Value |
|---|---|
| ECR registry | `388779989543.dkr.ecr.ap-south-1.amazonaws.com` |
| ECR repos | `bmi-backend`, `bmi-frontend` |
| AWS region | `ap-south-1` |
| AWS profile (local) | `sarowar-ostad` |
| Image tag strategy | git short SHA per commit |
| ECR token lifetime | 12 hours (auto-refreshed by `deploy.sh`) |

---

## 2. AWS Prerequisites (One-Time)

### 2.1 Create ECR Repositories

> Must be done **before** running `build-and-push.sh` for the first time.

1. Go to **AWS Console → ECR → Create repository**
2. Create repository: `bmi-backend`
   - Visibility: **Private**
   - Tag immutability: off (we overwrite `latest` on each push)
3. Create repository: `bmi-frontend`
   - Same settings as above

### 2.2 Create IAM Role for EC2 Nodes

> This role allows both EC2 instances to pull images from ECR without static credentials.

1. Go to **AWS Console → IAM → Roles → Create role**
2. **Trusted entity type:** AWS service
3. **Use case:** EC2
4. **Attach these policies:**

   | Policy | Purpose |
   |---|---|
   | `AmazonEC2ContainerRegistryReadOnly` | Lets EC2 nodes pull images from ECR |
   | `AmazonEC2ReadOnlyAccess` | Optional — useful for debugging with `aws sts get-caller-identity` |

5. **Role name:** `k8s-node-ecr-role`
6. Click **Create role**

### 2.3 Attach the IAM Role to Both EC2 Instances

Repeat for **both** `k8s-control-plane` and `k8s-worker-1`:

1. **AWS Console → EC2 → Instances** → select the instance
2. **Actions → Security → Modify IAM role**
3. Select `k8s-node-ecr-role` → **Update IAM role**

> **Why both nodes?**  
> The control-plane needs the role to run `aws ecr get-login-password` (called by `deploy.sh`).  
> The worker node needs it so `kubelet` can pull ECR images when scheduling pods.

---

## 3. Local Machine Prerequisites (One-Time)

These tools must be installed on the machine where you will run `build-and-push.sh`.

### 3.1 Docker Desktop

- Download and install: https://www.docker.com/products/docker-desktop/
- Start Docker Desktop and ensure it shows **"Engine running"**

### 3.2 AWS CLI

```bash
# macOS (Homebrew)
brew install awscli

# Windows
winget install Amazon.AWSCLI

# Verify
aws --version
```

### 3.3 Configure AWS Named Profile

`build-and-push.sh` uses the profile name `sarowar-ostad`.

```bash
aws configure --profile sarowar-ostad
```

Enter when prompted:

| Prompt | Value |
|---|---|
| AWS Access Key ID | your IAM user access key |
| AWS Secret Access Key | your IAM user secret key |
| Default region | `ap-south-1` |
| Default output format | `json` |

Verify the profile works:

```bash
aws sts get-caller-identity --profile sarowar-ostad
```

Expected: a JSON response with your account ID `388779989543`.

### 3.4 Git

```bash
git --version   # must be installed
```

---

## 4. Control-Plane Node Setup (One-Time)

SSH into the control-plane using its **public IP** (it is in the public subnet):

```bash
ssh ubuntu@13.127.88.162
```

### 4.1 Install AWS CLI

```bash
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
unzip -q /tmp/a.zip -d /tmp
sudo /tmp/aws/install
aws --version
```

### 4.2 Clone the Repository

```bash
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app
```

---

## 5. Worker Node Setup (One-Time)

The worker node is in a **private subnet** — it has no public IP and cannot be reached directly from the internet. SSH to it by **jumping through the control-plane** (which is in the public subnet):

```bash
ssh -J ubuntu@13.127.88.162 ubuntu@10.0.130.111
```

Alternatively, SSH to the control-plane first and then hop to the worker from there:

```bash
ssh ubuntu@13.127.88.162          # step 1: land on control-plane
ssh ubuntu@10.0.130.111           # step 2: hop to worker via private IP
```

Once on the worker, create the PostgreSQL data directory. The PersistentVolume uses `hostPath: /data/postgres` — this directory must exist before the PostgreSQL pod starts.

```bash
sudo mkdir -p /data/postgres
sudo chmod 777 /data/postgres
exit
```

> The PersistentVolume uses `persistentVolumeReclaimPolicy: Retain`, so data survives pod deletions and redeployments.

---

## 6. Clone Repo and Prepare Secrets

Back on the control-plane (`ssh ubuntu@13.127.88.162`):

### 6.1 Apply the Namespace First

```bash
cd kubernetes-3tier-app
kubectl apply -f k8s/namespace.yaml
```

### 6.2 Edit and Apply the PostgreSQL Secret

The file `k8s/postgres/secret.yaml` contains the database credentials.

> **Change the password** from the default before applying — use a strong password in production.

```bash
nano k8s/postgres/secret.yaml
```

The file looks like this:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: bmi-app
type: Opaque
stringData:
  POSTGRES_DB:       "bmidb"
  POSTGRES_USER:     "bmi_user"
  POSTGRES_PASSWORD: "CHANGE_ME_before_applying"
```

Save and apply:

```bash
kubectl apply -f k8s/postgres/secret.yaml
```

### 6.3 Edit and Apply the Backend Secret

The file `k8s/backend/secret.yaml` contains the `DATABASE_URL` used by Node.js.

> **The password in `DATABASE_URL` must match `POSTGRES_PASSWORD` you set above.**

```bash
nano k8s/backend/secret.yaml
```

The file looks like this:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: backend-secret
  namespace: bmi-app
type: Opaque
stringData:
  DATABASE_URL: "postgres://bmi_user:CHANGE_ME_before_applying@bmi-postgres-svc:5432/bmidb"
```

Save and apply:

```bash
kubectl apply -f k8s/backend/secret.yaml
```

> **Security note:** These two files are `.gitignore`d — never commit them to git. They are applied manually on the cluster once and persist in the Kubernetes secret store.

---

## 7. Build and Push Docker Images — `build-and-push.sh`

Run this on your **local machine** from the repo root every time you change application code.

```bash
bash k8s/build-and-push.sh
```

### What the script does — step by step

**[1/5] ECR Login**

```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin \
    388779989543.dkr.ecr.ap-south-1.amazonaws.com
```

Authenticates Docker to ECR using the `sarowar-ostad` AWS profile. The token is valid for 12 hours.

---

**[2/5] Build Docker Images**

```bash
docker build -t bmi-backend:<SHA>  ./backend
docker build -t bmi-frontend:<SHA> ./frontend
```

- Backend: multi-stage Node.js 18 Alpine build, runs as non-root user `appuser`
- Frontend: multi-stage Vite build → served by Nginx 1.25 Alpine

`<SHA>` is the current git short commit hash (e.g. `3fcc322`). If not in a git repo, falls back to a timestamp.

---

**[3/5] Tag Images**

Each image gets **two tags**:

| Tag | Purpose |
|---|---|
| `<ECR>/<repo>:<SHA>` | Immutable — identifies the exact commit, used in Kubernetes manifests |
| `<ECR>/<repo>:latest` | Convenience — always points to the most recent push |

---

**[4/5] Push to ECR**

All four tags (2 images × 2 tags) are pushed:

```
388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:<SHA>
388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:latest
388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:<SHA>
388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:latest
```

---

**[5/5] Patch Deployment YAMLs + Git Commit**

The script updates the image field in both deployment manifests using `sed`:

```
k8s/backend/deployment.yaml  → image: <ECR>/bmi-backend:<SHA>
k8s/frontend/deployment.yaml → image: <ECR>/bmi-frontend:<SHA>
```

It then runs:

```bash
git add k8s/backend/deployment.yaml k8s/frontend/deployment.yaml
git commit -m "deploy: image tag <SHA> (<timestamp>)"
git push
```

If the manifests already contain the same SHA (re-running without new commits), the `git diff --staged --quiet` check detects no change and skips the commit.

---

**Expected output on success:**

```
================================================
 BMI Health Tracker — Build & Push
 Image tag : 3fcc322
 Timestamp : 2026-04-13 10:00:00
 Registry  : 388779989543.dkr.ecr.ap-south-1.amazonaws.com
================================================

[1/5] Logging in to ECR...
Login Succeeded
[2/5] Building backend image...
...
[3/5] Tagging images...
[4/5] Pushing backend to ECR...
...
[5/5] Updating deployment manifests...
      Manifests committed and pushed to git.
================================================
```

---

## 8. Deploy to Kubernetes — `deploy.sh`

Run this on the **control-plane node** (public IP `13.127.88.162`) after `build-and-push.sh` has completed.

```bash
cd kubernetes-3tier-app
git pull          # pull the manifest changes committed by build-and-push.sh
bash k8s/deploy.sh
```

### What the script does — step by step

---

**[0/6] Refresh ECR Pull Secret**

```bash
bash k8s/setup-ecr-secret.sh
```

The ECR auth token expires every **12 hours**. This step runs on every deployment to ensure the `ecr-credentials` imagePullSecret in the `bmi-app` namespace is always valid. Without a valid secret, kubelet cannot pull images from ECR.

Under the hood, `setup-ecr-secret.sh` runs:

```bash
kubectl create secret docker-registry ecr-credentials \
  --docker-server=388779989543.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region ap-south-1) \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client -o yaml | kubectl apply` pattern is idempotent — it creates the secret if missing or overwrites it if it exists.

---

**[1/6] Namespace**

```bash
kubectl apply -f k8s/namespace.yaml
```

Creates the `bmi-app` namespace. `kubectl apply` is idempotent — safe to run again if the namespace already exists.

---

**[2/6] PostgreSQL**

Applied in dependency order:

```bash
kubectl apply -f k8s/postgres/secret.yaml      # DB credentials (postgres-secret)
kubectl apply -f k8s/postgres/pv.yaml          # 5Gi hostPath PV on worker-1 (/data/postgres)
kubectl apply -f k8s/postgres/pvc.yaml         # PVC bound to the above PV
kubectl apply -f k8s/postgres/statefulset.yaml # postgres:14 pod, pinned to worker-1
kubectl apply -f k8s/postgres/service.yaml     # ClusterIP :5432 → bmi-postgres-svc
```

The script then waits up to **120 seconds** for the PostgreSQL pod to pass its readiness probe:

```bash
kubectl wait --for=condition=ready pod \
  -l app=postgres -n bmi-app --timeout=120s
```

The readiness probe runs `pg_isready -U bmi_user -d bmidb` every 10 seconds. The pod is not marked Ready until PostgreSQL is fully accepting connections.

---

**[3/6] Database Migrations**

```bash
kubectl apply  -f k8s/postgres/migrations-configmap.yaml
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
kubectl apply  -f k8s/postgres/migration-job.yaml
```

The old migration Job is deleted before re-applying because completed Kubernetes Jobs are immutable — you must delete and recreate to run them again.

The Job runs two SQL migration files mounted from the `postgres-migrations` ConfigMap:

| Migration | Description |
|---|---|
| `001_create_measurements.sql` | Creates the `measurements` table with all columns, constraints, and indexes — uses `CREATE TABLE IF NOT EXISTS` (idempotent) |
| `002_add_measurement_date.sql` | Adds `measurement_date` column if it does not exist — idempotent guard inside the SQL |

An `initContainer` (busybox) waits for `bmi-postgres-svc:5432` to be reachable before running `psql` — prevents race conditions if this job is applied before the postgres pod is fully ready.

The script waits up to **90 seconds** for the job to complete:

```bash
kubectl wait --for=condition=complete job/bmi-migrations -n bmi-app --timeout=90s
```

---

**[4/6] Backend**

```bash
kubectl apply -f k8s/backend/secret.yaml     # DATABASE_URL (backend-secret)
kubectl apply -f k8s/backend/configmap.yaml  # NODE_ENV, PORT, FRONTEND_URL (backend-config)
kubectl apply -f k8s/backend/deployment.yaml # 2 replicas, image from ECR, /health probes
kubectl apply -f k8s/backend/service.yaml    # ClusterIP :3000 → bmi-backend-svc
```

Resource limits per backend pod:

| | Request | Limit |
|---|---|---|
| CPU | 100m | 300m |
| Memory | 128Mi | 256Mi |

The script waits up to **90 seconds** for a clean rolling update:

```bash
kubectl rollout status deployment/bmi-backend -n bmi-app --timeout=90s
```

Both liveness (`/health` every 30s) and readiness (`/health` every 10s) probes on port 3000 must pass before a pod is considered Ready.

---

**[5/6] Frontend**

```bash
kubectl apply -f k8s/frontend/deployment.yaml # 2 replicas, Nginx, image from ECR
kubectl apply -f k8s/frontend/service.yaml    # NodePort 30080 → bmi-frontend-svc
```

Resource limits per frontend pod:

| | Request | Limit |
|---|---|---|
| CPU | 50m | 200m |
| Memory | 64Mi | 128Mi |

The script waits up to **90 seconds** for a clean rolling update:

```bash
kubectl rollout status deployment/bmi-frontend -n bmi-app --timeout=90s
```

Nginx is configured to proxy all `/api/*` requests to `http://bmi-backend-svc:3000` (Kubernetes DNS). The browser never calls the backend directly — no CORS needed.

---

**[6/6] Deployment Summary**

The script prints current pod status and the app URL:

```bash
kubectl get pods -n bmi-app
# ✅ App is live at: http://13.127.88.162:30080
```

---

**Full expected output:**

```
================================================
 BMI Health Tracker — Kubernetes Deployment
================================================

[0/6] Refreshing ECR pull secret...
✅ ECR secret ready (valid for 12 hours).

[1/6] Creating namespace...
namespace/bmi-app configured

[2/6] Deploying PostgreSQL...
      Waiting for postgres pod to be Ready (up to 120s)...
pod/postgres-0 condition met

[3/6] Running database migrations...
      Waiting for migration job to complete (up to 90s)...
job.batch/bmi-migrations condition met

[4/6] Deploying backend...
      Waiting for backend pods to be Ready (up to 90s)...
deployment.apps/bmi-backend successfully rolled out

[5/6] Deploying frontend...
      Waiting for frontend pods to be Ready (up to 90s)...
deployment.apps/bmi-frontend successfully rolled out

[6/6] Deployment complete! Current pod status:
NAME                            READY   STATUS      RESTARTS   AGE
bmi-backend-xxxxxx-xxxxx        1/1     Running     0          30s
bmi-backend-xxxxxx-xxxxx        1/1     Running     0          30s
bmi-frontend-xxxxxx-xxxxx       1/1     Running     0          20s
bmi-frontend-xxxxxx-xxxxx       1/1     Running     0          20s
bmi-migrations-xxxxx            0/1     Completed   0          60s
postgres-0                      1/1     Running     0          90s

================================================
 ✅ App is live at: http://13.127.88.162:30080
================================================
```

---

## 9. Verify the Deployment

Run these checks on the control-plane after `deploy.sh` finishes.

### 9.1 Pod Status

All pods should show `Running` (or `Completed` for the migration job):

```bash
kubectl get pods -n bmi-app
```

### 9.2 Services

```bash
kubectl get svc -n bmi-app
```

Expected:

```
NAME               TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)        AGE
bmi-backend-svc    ClusterIP   10.x.x.x     <none>        3000/TCP       ...
bmi-frontend-svc   NodePort    10.x.x.x     <none>        80:30080/TCP   ...
bmi-postgres-svc   ClusterIP   10.x.x.x     <none>        5432/TCP       ...
```

### 9.3 Health Check

```bash
curl http://10.0.130.111:3000/health       # from inside the cluster only
kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
```

Expected response: `{"status":"ok"}` or `OK`

### 9.4 Open in Browser

```
http://13.127.88.162:30080
```

---

## 10. Update Workflow (Every Code Change)

**Step 1 — Local machine** (after editing backend or frontend code):

```bash
bash k8s/build-and-push.sh
```

This builds new images with a new git SHA tag, pushes to ECR, patches both deployment YAMLs, and commits + pushes to git automatically.

**Step 2 — Control-plane:**

```bash
cd kubernetes-3tier-app
git pull
bash k8s/deploy.sh
```

`deploy.sh` handles everything: ECR secret refresh, re-applies all manifests (including the new image tag), re-runs migrations (idempotent), and waits for all pods to be ready.

> `kubectl apply` with a new image tag triggers a **rolling update** automatically — pods are replaced one at a time with zero downtime.

---

## 11. Rollback

To roll back to the previous image tag on any deployment:

```bash
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app
```

To roll back to a specific revision:

```bash
kubectl rollout history deployment/bmi-backend -n bmi-app     # list revisions
kubectl rollout undo deployment/bmi-backend -n bmi-app --to-revision=2
```

---

## 12. Useful Commands

```bash
# Pod status
kubectl get pods -n bmi-app

# Watch pods live
kubectl get pods -n bmi-app -w

# Describe a pod (events, probe failures, image pull errors)
kubectl describe pod -n bmi-app <pod-name>

# Backend application logs
kubectl logs -n bmi-app deploy/bmi-backend

# Frontend Nginx logs
kubectl logs -n bmi-app deploy/bmi-frontend

# PostgreSQL logs
kubectl logs -n bmi-app statefulset/postgres

# Migration job logs
kubectl logs -n bmi-app job/bmi-migrations

# Manually refresh ECR token (if image pulls fail between deploys)
bash k8s/setup-ecr-secret.sh

# Check ECR secret exists
kubectl get secret ecr-credentials -n bmi-app

# Check PersistentVolume and PVC
kubectl get pv,pvc -n bmi-app

# Check all resources in namespace
kubectl get all -n bmi-app

# Force restart all backend pods (without image change)
kubectl rollout restart deployment/bmi-backend -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app

# Delete and re-run migrations manually
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
kubectl apply -f k8s/postgres/migration-job.yaml
kubectl wait --for=condition=complete job/bmi-migrations -n bmi-app --timeout=90s
```

---

## 13. Reference

| Item | Value |
|---|---|
| App URL | http://13.127.88.162:30080 |
| Control-plane public IP (SSH + NodePort entry) | 13.127.88.162 |
| Control-plane private IP | 10.0.5.64 |
| Worker node private IP (private subnet, no public IP) | 10.0.130.111 |
| ECR registry | `388779989543.dkr.ecr.ap-south-1.amazonaws.com` |
| ECR repos | `bmi-backend`, `bmi-frontend` |
| Kubernetes namespace | `bmi-app` |
| PostgreSQL data path (worker-1) | `/data/postgres` |
| PV reclaim policy | `Retain` — data NOT deleted on pod/PVC deletion |
| Image tag strategy | git short SHA — unique per commit |
| ECR token lifetime | 12 hours — auto-refreshed by `deploy.sh` |
| Secrets committed to git | Never — `k8s/postgres/secret.yaml` and `k8s/backend/secret.yaml` are `.gitignore`d |
| Backend health endpoint | `GET /health` on port 3000 |
| Frontend NodePort | 30080 |

---

## Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, Hogarth Worldwide  
Email: sarowar@hotmail.com  
LinkedIn: https://www.linkedin.com/in/sarowar/
