# BMI Health Tracker — Complete Deployment Guide (V2)

**Repo:** https://github.com/sarowar-alam/kubernetes-3tier-app  
**App URL:** http://13.127.210.35:30080  
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
Browser → http://13.127.210.35:30080  (NodePort on control-plane — public subnet)
  └─ bmi-frontend-svc  → Nginx pod :80
       └─ /api/*  proxied  → bmi-backend-svc:3000
            └─ bmi-postgres-svc:5432  → PostgreSQL StatefulSet
```

> **Network topology:** The control-plane is in a **public subnet** and is the external entry point. The worker nodes are in a **private subnet** — they have no public IP and are not directly reachable from the internet. Kubernetes NodePort is exposed on **all** cluster nodes, so the public IP of the control-plane serves external traffic on port 30080.

| Node | Private IP | Public IP | Subnet | Role |
|---|---|---|---|---|
| k8s-lab-master | 10.0.10.34 | 13.127.210.35 | Public | API server, scheduler, etcd, NodePort entry |
| k8s-lab-worker-1 | 10.0.132.170 | — (none) | Private | Runs app pods, PostgreSQL storage |
| k8s-lab-worker-2 | 10.0.141.21 | — (none) | Private | Runs app pods |

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

Repeat for **all three nodes** — `k8s-lab-master`, `k8s-lab-worker-1`, and `k8s-lab-worker-2`:

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
ssh ubuntu@13.127.210.35
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
# worker-1 (PostgreSQL node)
ssh -J ubuntu@13.127.210.35 ubuntu@10.0.132.170

# worker-2
ssh -J ubuntu@13.127.210.35 ubuntu@10.0.141.21
```

Alternatively, SSH to the control-plane first and then hop to the worker from there:

```bash
ssh ubuntu@13.127.210.35           # step 1: land on control-plane
ssh ubuntu@10.0.132.170            # step 2: hop to worker-1 via private IP
# or
ssh ubuntu@10.0.141.21             # step 2: hop to worker-2 via private IP
```

Once on **k8s-lab-worker-1**, create the PostgreSQL data directory. The PersistentVolume uses `hostPath: /data/postgres` on this specific node — this directory must exist before the PostgreSQL pod starts.

```bash
sudo mkdir -p /data/postgres
sudo chmod 777 /data/postgres
exit
```

> You do **not** need to create this directory on k8s-lab-worker-2 — postgres is pinned to k8s-lab-worker-1 only.

> The PersistentVolume uses `persistentVolumeReclaimPolicy: Retain`, so data survives pod deletions and redeployments.

---

## 6. Clone Repo and Prepare Secrets

Back on the control-plane (`ssh ubuntu@13.127.210.35`):

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

## 7. Build and Push Docker Images — Manual Steps

Run all commands below from the **repo root directory**. This can be your **local Windows machine** or the **Ubuntu control-plane** (`ssh ubuntu@13.127.210.35`) — Docker must be installed wherever you run this.

> **Important:** The build commands use `./backend` and `./frontend` as the Docker build context. These paths only resolve correctly when you are in the repo root. Running from any other directory (e.g. inside `k8s/`) will cause `docker build` to fail with _"unable to prepare context"_.

**Navigate to the repo root first:**

**Ubuntu / macOS / Linux / Git Bash:**
```bash
cd ~/kubernetes-3tier-app
pwd
# Expected: /home/ubuntu/kubernetes-3tier-app
```

**PowerShell (Windows):**
```powershell
cd C:\path\to\kubernetes-3tier-app
Get-Location
# Expected: C:\path\to\kubernetes-3tier-app
```

> **Shell guide for this section:**
> - **Ubuntu / macOS / Linux / Git Bash** — use the bash code blocks (works on the Ubuntu control-plane or any Linux/macOS terminal)
> - **PowerShell** — use the PowerShell code blocks (Windows only)

> **You can also run the whole section in one command (bash only, from repo root):**  
> `bash k8s/build-and-push.sh`  
> The manual steps below are the exact equivalent — use them when you want full control or need to re-run a single step.

---

### Step 7.0 — Set shared variables

These variables are used in every command below. Set them once in your terminal session.

**Ubuntu / macOS / Linux / Git Bash:**
```bash
export AWS_PROFILE="sarowar-ostad"
export ECR_BASE="388779989543.dkr.ecr.ap-south-1.amazonaws.com"
export TAG=$(git rev-parse --short HEAD)
echo "Image tag will be: ${TAG}"
```

**PowerShell:**
```powershell
$env:AWS_PROFILE = "sarowar-ostad"
$ECR_BASE = "388779989543.dkr.ecr.ap-south-1.amazonaws.com"
$TAG = git rev-parse --short HEAD
Write-Host "Image tag will be: $TAG"
```

> `TAG` is the git short SHA of the current commit (e.g. `3fcc322`). Every build is traceable to a specific commit, and rollback is easy with `kubectl rollout undo`.

---

### Step 7.1 — Log in to ECR

**Ubuntu / macOS / Linux / Git Bash:**
```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin "${ECR_BASE}"
```

**PowerShell:**
```powershell
aws ecr get-login-password --region ap-south-1 |
  docker login --username AWS --password-stdin $ECR_BASE
```

Expected output:
```
Login Succeeded
```

> The ECR token is valid for **12 hours**. If you get `no basic auth credentials` when pushing, re-run this step.

---

### Step 7.2 — Build the backend Docker image

**Ubuntu / macOS / Linux / Git Bash:**
```bash
docker build -t "bmi-backend:${TAG}" ./backend
```

**PowerShell:**
```powershell
docker build -t "bmi-backend:$TAG" ./backend
```

- Multi-stage build: Node.js 18 Alpine installs dependencies, second stage copies output and runs as non-root user `appuser`
- Exposes port `3000`, health check on `GET /health`

Verify the image was built:
```bash
docker images bmi-backend
```

---

### Step 7.3 — Build the frontend Docker image

**Ubuntu / macOS / Linux / Git Bash:**
```bash
docker build -t "bmi-frontend:${TAG}" ./frontend
```

**PowerShell:**
```powershell
docker build -t "bmi-frontend:$TAG" ./frontend
```

- Multi-stage build: Node.js 18 Alpine runs `npm run build` (Vite), second stage copies `dist/` into Nginx 1.25 Alpine
- Nginx proxies `/api/*` to `http://bmi-backend-svc:3000` (Kubernetes DNS)

Verify the image was built:
```bash
docker images bmi-frontend
```

---

### Step 7.4 — Tag both images for ECR

Each image needs two tags: an immutable SHA tag (used in Kubernetes manifests) and `latest` (for convenience).

**Ubuntu / macOS / Linux / Git Bash:**
```bash
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
```

**PowerShell:**
```powershell
docker tag "bmi-backend:$TAG"  "$ECR_BASE/bmi-backend:$TAG"
docker tag "bmi-backend:$TAG"  "$ECR_BASE/bmi-backend:latest"
docker tag "bmi-frontend:$TAG" "$ECR_BASE/bmi-frontend:$TAG"
docker tag "bmi-frontend:$TAG" "$ECR_BASE/bmi-frontend:latest"
```

After tagging, verify all 4 ECR-tagged images exist:

**Ubuntu / macOS / Linux / Git Bash:**
```bash
docker images | grep "${ECR_BASE}"
```

**PowerShell:**
```powershell
docker images | Select-String $ECR_BASE
```

---

### Step 7.5 — Push images to ECR

Push all 4 tags (2 images × 2 tags):

**Ubuntu / macOS / Linux / Git Bash:**
```bash
docker push "${ECR_BASE}/bmi-backend:${TAG}"
docker push "${ECR_BASE}/bmi-backend:latest"
docker push "${ECR_BASE}/bmi-frontend:${TAG}"
docker push "${ECR_BASE}/bmi-frontend:latest"
```

**PowerShell:**
```powershell
docker push "$ECR_BASE/bmi-backend:$TAG"
docker push "$ECR_BASE/bmi-backend:latest"
docker push "$ECR_BASE/bmi-frontend:$TAG"
docker push "$ECR_BASE/bmi-frontend:latest"
```

Each push prints digest + size per layer. The last line for each push looks like:
```
3fcc322: digest: sha256:abc123... size: 12345678
```

---

### Step 7.6 — Update deployment manifests with the new image tag

Patch the `image:` field in both Kubernetes deployment YAMLs to the new SHA tag:

**Ubuntu / macOS / Linux / Git Bash:**
```bash
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s/backend/deployment.yaml

sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s/frontend/deployment.yaml
```

**PowerShell (Git Bash `sed` not available — use PowerShell replace):**
```powershell
(Get-Content k8s/backend/deployment.yaml) -replace 'image: .*bmi-backend:.*', "image: $ECR_BASE/bmi-backend:$TAG" |
  Set-Content k8s/backend/deployment.yaml

(Get-Content k8s/frontend/deployment.yaml) -replace 'image: .*bmi-frontend:.*', "image: $ECR_BASE/bmi-frontend:$TAG" |
  Set-Content k8s/frontend/deployment.yaml
```

Verify the change:

**Ubuntu / macOS / Linux / Git Bash:**
```bash
grep "image:" k8s/backend/deployment.yaml
grep "image:" k8s/frontend/deployment.yaml
```

**PowerShell:**
```powershell
Select-String "image:" k8s/backend/deployment.yaml
Select-String "image:" k8s/frontend/deployment.yaml
```

Expected (with your actual SHA):
```
image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:3fcc322
image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:3fcc322
```

---

### Step 7.7 — Commit and push the updated manifests to git

```bash
git add k8s/backend/deployment.yaml k8s/frontend/deployment.yaml
git diff --staged    # confirm only the image tag line changed
git commit -m "deploy: image tag ${TAG}"
git push
```

> If you re-run step 7.6 with the same SHA (no new commits), `git diff --staged` will show no changes — skip the commit in that case.

---

**All steps complete.** The new image tag is now in ECR and the deployment YAMLs in git reflect it. Proceed to **Section 8** to deploy to Kubernetes.

---

## 8. Deploy to Kubernetes — `deploy.sh`

Run this on the **Ubuntu control-plane node** (`ssh ubuntu@13.127.210.35`) after **Section 7** has completed.

> All commands in this section are **bash only** — they run on the Ubuntu control-plane server.

> **Note:** Your cluster has 2 worker nodes (`k8s-lab-worker-1` and `k8s-lab-worker-2`). The backend and frontend deployments (2 replicas each) will spread across both workers automatically. PostgreSQL is pinned to `k8s-lab-worker-1` via `nodeSelector`.

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
# ✅ App is live at: http://13.127.210.35:30080
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
 ✅ App is live at: http://13.127.210.35:30080
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
kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
```

Expected response: `{"status":"ok"}` or `OK`

### 9.4 Open in Browser

```
http://13.127.210.35:30080
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
| App URL | http://13.127.210.35:30080 |
| Control-plane node name | k8s-lab-master |
| Control-plane public IP (SSH + NodePort entry) | 13.127.210.35 |
| Control-plane private IP | 10.0.10.34 |
| Worker-1 node name (PostgreSQL node) | k8s-lab-worker-1 |
| Worker-1 private IP (private subnet, no public IP) | 10.0.132.170 |
| Worker-2 node name | k8s-lab-worker-2 |
| Worker-2 private IP (private subnet, no public IP) | 10.0.141.21 |
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
