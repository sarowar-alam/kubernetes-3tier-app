# BMI Health Tracker — Kubernetes Implementation Guide

**Repo:** https://github.com/sarowar-alam/kubernetes-3tier-app
**App URL:** http://13.127.210.35:30080
**Namespace:** `bmi-app`

---

## Cluster Topology

| Node | Role | Private IP | Public IP | Subnet |
|---|---|---|---|---|
| k8s-lab-master | Control-plane | 10.0.10.34 | 13.127.210.35 | Public |
| k8s-lab-worker-1 | Worker (PostgreSQL) | 10.0.132.170 | — | Private |
| k8s-lab-worker-2 | Worker | 10.0.141.21 | — | Private |

Traffic flow:
```
Browser → http://13.127.210.35:30080 (NodePort on master — public subnet)
  └─ bmi-frontend-svc → Nginx pod :80
       └─ /api/* proxied → bmi-backend-svc:3000
            └─ bmi-postgres-svc:5432 → PostgreSQL StatefulSet
```

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Part 1 — Deploy WITH Automation Scripts](#part-1--deploy-with-automation-scripts)
- [Part 2 — Deploy WITHOUT Automation Scripts (Full Manual)](#part-2--deploy-without-automation-scripts-full-manual)
- [Update Workflow (Every Code Change)](#update-workflow-every-code-change)
- [Rollback](#rollback)
- [Useful Commands](#useful-commands)

---

## Prerequisites

All prerequisites must be satisfied before starting either Part 1 or Part 2.

### Local Machine

| Requirement | Install Command | Verify |
|---|---|---|
| Docker Desktop | https://www.docker.com/products/docker-desktop/ | `docker --version` |
| AWS CLI v2 | macOS: `brew install awscli` / Windows: `winget install Amazon.AWSCLI` | `aws --version` |
| Git | https://git-scm.org | `git --version` |
| AWS credentials | Option A: named profile `sarowar-ostad` OR Option B: environment variables | see below |

**Choose ONE of the two options below. Both work with all commands in this guide.**

#### Option A — Named Profile (recommended, persists across sessions)

```bash
# Directory: anywhere on local machine
# Run this once — stores credentials in ~/.aws/credentials under [sarowar-ostad]
aws configure --profile sarowar-ostad
# Prompts:
#   AWS Access Key ID:     <your IAM user access key>
#   AWS Secret Access Key: <your IAM user secret key>
#   Default region name:   ap-south-1
#   Default output format: json
```

All commands in this guide already include `--profile sarowar-ostad` or `export AWS_PROFILE="sarowar-ostad"` — nothing else to change.

**Verify:**
```bash
aws sts get-caller-identity --profile sarowar-ostad
# Expected: { "Account": "388779989543", "UserId": "...", "Arn": "..." }
```

#### Option B — Environment Variables (no profile needed, valid for current session only)

Use this if you cannot or do not want to create a named profile. Export credentials directly:

```bash
# Directory: anywhere on local machine
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_DEFAULT_REGION="ap-south-1"
# These override any profile for the duration of the current terminal session
# Replace the example values with your actual IAM user credentials
```

When using Option B, **remove** `--profile sarowar-ostad` and `export AWS_PROFILE=...` from any command in this guide — the environment variables take precedence automatically.

**Verify:**
```bash
aws sts get-caller-identity
# Expected: { "Account": "388779989543", "UserId": "...", "Arn": "..." }
```

### AWS Console (One-Time)

**1. Create ECR Repositories**
- AWS Console → ECR → Create repository
- Name: `bmi-backend` — Private, tag immutability: off
- Name: `bmi-frontend` — Private, tag immutability: off

Verify via CLI:
```bash
# Directory: anywhere on local machine
aws ecr describe-repositories --region ap-south-1 --profile sarowar-ostad \
  --query 'repositories[].repositoryName'
# Expected: [ "bmi-backend", "bmi-frontend" ]
```

**2. Create IAM Role — `k8s-node-ecr-role`**

AWS Console → IAM → Roles → Create role:
- Trusted entity: **AWS service**
- Use case: **EC2**
- Attach policy: `AmazonEC2ContainerRegistryReadOnly`
- Role name: `k8s-node-ecr-role`

Equivalent inline policy JSON:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRReadOnly",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "*"
    }
  ]
}
```

**3. Attach Role to All 3 EC2 Instances**

EC2 → Instances → select each instance → Actions → Security → Modify IAM role → select `k8s-node-ecr-role`

Repeat for: `k8s-lab-master`, `k8s-lab-worker-1`, `k8s-lab-worker-2`

**4. IAM Policy for Local Machine (ECR Push)**

AWS Console → IAM → Users → your user → Add permissions → Create inline policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ],
      "Resource": "*"
    }
  ]
}
```

### Kubernetes Cluster

| Requirement | Why |
|---|---|
| kubeadm cluster running, all nodes Ready | Pods will not schedule without this |
| containerd runtime on all nodes | Image pulls from ECR require containerd |
| `kubectl` configured on master | All deploy commands run there |
| `/data/postgres` on k8s-lab-worker-1 | PostgreSQL hostPath PV requires this directory |

Verify cluster is healthy:
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get nodes -o wide
# Expected: all 3 nodes STATUS=Ready
```

---

# Part 1 — Deploy WITH Automation Scripts

Two scripts handle the full lifecycle. Run them in order.

| Script | Run On | Purpose |
|---|---|---|
| `k8s/build-and-push.sh` | Local machine (repo root) | Build images → push to ECR → patch YAMLs → git commit |
| `k8s/deploy.sh` | k8s-lab-master | Apply all manifests in order → wait for readiness |

---

## Phase 1.1 — One-Time Cluster Setup

### A. Prepare Worker-1 Storage

> **Directory: k8s-lab-worker-1 — home directory (`~`)**

```bash
# From local machine — jump through master to worker-1
ssh -J ubuntu@13.127.210.35 ubuntu@10.0.132.170

# On k8s-lab-worker-1:
sudo mkdir -p /data/postgres
# Creates /data/postgres directory if it does not exist

sudo chmod 777 /data/postgres
# Gives read/write/execute to all users
# PostgreSQL pod runs as UID 999 — requires write access
```

**Verify:**
```bash
# Directory: k8s-lab-worker-1 — ~
ls -ld /data/postgres
# Expected: drwxrwxrwx 2 root root 4096 ...

exit
# Returns to local machine
```

### B. Set Up the Control-Plane

> **Directory: k8s-lab-master — home directory (`~`)**

```bash
ssh ubuntu@13.127.210.35

# Install AWS CLI
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
unzip -q /tmp/a.zip -d /tmp
sudo /tmp/aws/install
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~
aws --version
# Expected: aws-cli/2.x.x Python/3.x.x Linux/...
```

```bash
# Clone the repository
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
ls k8s/
# Expected: backend/ frontend/ postgres/ build-and-push.sh deploy.sh namespace.yaml ...
```

### C. Apply Namespace and Secrets

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -f k8s/namespace.yaml
# Creates the bmi-app namespace
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get namespace bmi-app
# Expected: NAME      STATUS   AGE
#           bmi-app   Active   5s
```

```bash
# Edit PostgreSQL secret — change password before applying
nano k8s/postgres/secret.yaml
# Change POSTGRES_PASSWORD: "CHANGE_ME" to something strong
# Example: POSTGRES_PASSWORD: "MyStr0ng!Pass2026"

kubectl apply -f k8s/postgres/secret.yaml
```

```bash
# Edit backend secret — DATABASE_URL password must match POSTGRES_PASSWORD above
nano k8s/backend/secret.yaml
# Change: postgres://bmi_user:CHANGE_ME@bmi-postgres-svc:5432/bmidb
# To:     postgres://bmi_user:MyStr0ng!Pass2026@bmi-postgres-svc:5432/bmidb

kubectl apply -f k8s/backend/secret.yaml
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get secret -n bmi-app
# Expected:
# NAME              TYPE                             DATA   AGE
# backend-secret    Opaque                           1      5s
# postgres-secret   Opaque                           3      10s
```

---

## Phase 1.2 — Build and Push Images

> **Directory: local machine — repo root (`kubernetes-3tier-app/`)**

```bash
cd kubernetes-3tier-app
# IMPORTANT: must be repo root — build-and-push.sh uses ./backend and ./frontend paths

bash k8s/build-and-push.sh
```

**What the script does internally:**
| Step | Command run internally |
|---|---|
| [1/5] ECR Login | `aws ecr get-login-password \| docker login` |
| [2/5] Build | `docker build -t bmi-backend:<SHA> ./backend` and `./frontend` |
| [3/5] Tag | `docker tag` — adds SHA and `latest` tags for ECR |
| [4/5] Push | `docker push` — all 4 tags (2 images × 2 tags) |
| [5/5] Patch + Commit | `sed` updates deployment YAMLs → `git commit && git push` |

**Expected output:**
```
[1/5] Logging in to ECR...
Login Succeeded
[2/5] Building backend image...
[3/5] Tagging images...
[4/5] Pushing backend to ECR...
[5/5] Updating deployment manifests...
      Manifests committed and pushed to git.
✅ Done!
   Backend:  388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f
   Frontend: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
grep "image:" k8s/backend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f

grep "image:" k8s/frontend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

---

## Phase 1.3 — Deploy to Kubernetes

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
ssh ubuntu@13.127.210.35
cd kubernetes-3tier-app

git pull
# Pulls the manifest changes committed by build-and-push.sh
# Expected: 1 file changed — deployment YAML with new image tag

bash k8s/deploy.sh
```

**What the script does internally:**
| Step | What happens | Timeout |
|---|---|---|
| [0/6] Refresh ECR secret | `setup-ecr-secret.sh` — creates/updates `ecr-credentials` imagePullSecret | — |
| [1/6] Namespace | `kubectl apply -f k8s/namespace.yaml` | — |
| [2/6] PostgreSQL | Applies secret→PV→PVC→StatefulSet→Service, waits for Ready | 120s |
| [3/6] Migrations | Deletes old Job, applies migration Job, waits for Complete | 90s |
| [4/6] Backend | Applies secret→configmap→deployment→service, waits for rollout | 90s |
| [5/6] Frontend | Applies deployment→service, waits for rollout | 90s |
| [6/6] Summary | `kubectl get pods -n bmi-app` | — |

**Expected output:**
```
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
[6/6] Deployment complete!
✅ App is live at: http://13.127.210.35:30080
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pods -n bmi-app
# Expected:
# NAME                             READY   STATUS      RESTARTS   AGE
# bmi-backend-xxxxxxx-xxxxx        1/1     Running     0          1m
# bmi-backend-xxxxxxx-xxxxx        1/1     Running     0          1m
# bmi-frontend-xxxxxxx-xxxxx       1/1     Running     0          45s
# bmi-frontend-xxxxxxx-xxxxx       1/1     Running     0          45s
# bmi-migrations-xxxxx             0/1     Completed   0          2m
# postgres-0                       1/1     Running     0          3m

kubectl get svc -n bmi-app
# Expected:
# NAME               TYPE        PORT(S)        AGE
# bmi-backend-svc    ClusterIP   3000/TCP       1m
# bmi-frontend-svc   NodePort    80:30080/TCP   45s
# bmi-postgres-svc   ClusterIP   5432/TCP       3m

kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"}
```

**Open in browser: http://13.127.210.35:30080**

---

# Part 2 — Deploy WITHOUT Automation Scripts (Full Manual)

Every command that the scripts execute, broken down individually with explanations.

---

## Phase 2.1 — One-Time Cluster Setup

Same as Phase 1.1 — see sections A, B, C above.

---

## Phase 2.2 — Authenticate to ECR

> **Directory: local machine — kubernetes-3tier-app/**

```bash
cd kubernetes-3tier-app
# Must be at repo root for build context paths to work
```

**Set variables — choose Option A or Option B:**

```bash
# Option A — Named profile (if you ran aws configure --profile sarowar-ostad)
export AWS_PROFILE="sarowar-ostad"

# Option B — Environment variables (if you did NOT create a named profile)
# export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
# export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
# export AWS_DEFAULT_REGION="ap-south-1"
# (uncomment Option B lines and comment out the Option A line above if using this)

export ECR_BASE="388779989543.dkr.ecr.ap-south-1.amazonaws.com"
export TAG=$(git rev-parse --short HEAD)
# TAG = git short SHA of current commit (e.g. 9b8bf6f)
# Used as the immutable image tag — traceable to a specific commit

echo "Building tag: ${TAG}"

aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin "${ECR_BASE}"
# aws ecr get-login-password: calls ECR API, returns a 12-hour temporary password
# docker login: registers the credential with the local Docker daemon
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
echo "Login status: $?"
# Expected: Login Succeeded  (printed by docker login above)
# Exit code 0 = success
```

---

## Phase 2.3 — Build Docker Images

> **Directory: local machine — kubernetes-3tier-app/**

### Build Backend
```bash
docker build -t "bmi-backend:${TAG}" ./backend
# -t "bmi-backend:<SHA>"   tags the image locally with the git SHA
# ./backend                Docker build context — reads backend/Dockerfile
#
# Dockerfile stages:
#   Stage 1: node:18-alpine — npm install (production deps only)
#   Stage 2: node:18-alpine — copies output, creates non-root user appuser, exposes :3000
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
docker images bmi-backend
# Expected:
# REPOSITORY    TAG       IMAGE ID       CREATED         SIZE
# bmi-backend   9b8bf6f   abc123def456   5 seconds ago   ~120MB
```

### Build Frontend
```bash
docker build -t "bmi-frontend:${TAG}" ./frontend
# ./frontend               Docker build context — reads frontend/Dockerfile
#
# Dockerfile stages:
#   Stage 1: node:18-alpine — npm install + npm run build (Vite → dist/)
#   Stage 2: nginx:1.25-alpine — copies dist/, applies nginx.conf, exposes :80
#             nginx.conf proxies /api/* → http://bmi-backend-svc:3000 (K8s DNS)
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
docker images bmi-frontend
# Expected:
# REPOSITORY     TAG       IMAGE ID       CREATED         SIZE
# bmi-frontend   9b8bf6f   def456abc789   5 seconds ago   ~30MB
```

---

## Phase 2.4 — Tag Images for ECR

> **Directory: local machine — kubernetes-3tier-app/**

Each image needs two tags:
- **SHA tag** — immutable, used in Kubernetes deployment manifests
- **latest tag** — always points to the most recent push

```bash
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
# docker tag creates a new reference to the same image layers
# The ECR registry URL prefix tells docker push where to send the image
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
docker images | grep "${ECR_BASE}"
# Expected (4 rows):
# 388779989543.dkr.ecr...amazonaws.com/bmi-backend    9b8bf6f   ...
# 388779989543.dkr.ecr...amazonaws.com/bmi-backend    latest    ...
# 388779989543.dkr.ecr...amazonaws.com/bmi-frontend   9b8bf6f   ...
# 388779989543.dkr.ecr...amazonaws.com/bmi-frontend   latest    ...
```

---

## Phase 2.5 — Push Images to ECR

> **Directory: local machine — kubernetes-3tier-app/**

```bash
docker push "${ECR_BASE}/bmi-backend:${TAG}"
# Uploads image layers to ECR — only changed layers are uploaded (layer caching)

docker push "${ECR_BASE}/bmi-backend:latest"

docker push "${ECR_BASE}/bmi-frontend:${TAG}"

docker push "${ECR_BASE}/bmi-frontend:latest"
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
aws ecr list-images --repository-name bmi-backend --region ap-south-1 \
  --profile sarowar-ostad --query 'imageIds[].imageTag'
# Expected: [ "9b8bf6f", "latest" ]

aws ecr list-images --repository-name bmi-frontend --region ap-south-1 \
  --profile sarowar-ostad --query 'imageIds[].imageTag'
# Expected: [ "9b8bf6f", "latest" ]
```

---

## Phase 2.6 — Update Deployment Manifests

> **Directory: local machine — kubernetes-3tier-app/**

```bash
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s/backend/deployment.yaml
# sed -i: edit file in-place
# s|old|new|g: replaces any existing bmi-backend image line regardless of previous tag

sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s/frontend/deployment.yaml
```

**PowerShell equivalent (Windows):**
```powershell
# Directory: local machine — kubernetes-3tier-app/
(Get-Content k8s/backend/deployment.yaml) `
  -replace 'image: .*bmi-backend:.*', "image: $ECR_BASE/bmi-backend:$TAG" |
  Set-Content k8s/backend/deployment.yaml

(Get-Content k8s/frontend/deployment.yaml) `
  -replace 'image: .*bmi-frontend:.*', "image: $ECR_BASE/bmi-frontend:$TAG" |
  Set-Content k8s/frontend/deployment.yaml
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
grep "image:" k8s/backend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f

grep "image:" k8s/frontend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

---

## Phase 2.7 — Commit and Push Manifests

> **Directory: local machine — kubernetes-3tier-app/**

```bash
git add k8s/backend/deployment.yaml k8s/frontend/deployment.yaml
# Stages only the two patched files

git diff --staged
# Review: should show only the image: line changed in each file

git commit -m "deploy: image tag ${TAG}"
# Commits the manifest change — cluster will git pull this

git push
# Pushes to GitHub so the cluster can pull
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
git log --oneline -3
# Expected: most recent commit is "deploy: image tag 9b8bf6f"
```

---

## Phase 2.8 — Deploy All Manifests to Kubernetes

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
ssh ubuntu@13.127.210.35
cd kubernetes-3tier-app

git pull
# Expected: 1 file changed — deployment YAML with updated image tag
```

### Step 0 — Refresh ECR Pull Secret

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
# Uses EC2 instance profile IAM role to fetch a 12-hour ECR password
# No static credentials needed — role is attached to the EC2 instance

kubectl create secret docker-registry ecr-credentials \
  --docker-server=388779989543.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
# --dry-run=client -o yaml: generates YAML without applying
# | kubectl apply -f -:     applies from stdin — idempotent, creates or updates
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get secret ecr-credentials -n bmi-app
# Expected: NAME              TYPE                             DATA   AGE
#           ecr-credentials   kubernetes.io/dockerconfigjson   1      5s
```

### Step 1 — Namespace

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl apply -f k8s/namespace.yaml
# Expected: namespace/bmi-app configured
```

**Verify:**
```bash
kubectl get namespace bmi-app
# Expected: NAME      STATUS   AGE
#           bmi-app   Active   ...
```

### Step 2 — PostgreSQL

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app

kubectl apply -f k8s/postgres/secret.yaml
# Creates postgres-secret (POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD)

kubectl apply -f k8s/postgres/pv.yaml
# Creates 5Gi hostPath PersistentVolume on k8s-lab-worker-1
# reclaimPolicy: Retain — data is NOT deleted if PVC or pod is deleted

kubectl apply -f k8s/postgres/pvc.yaml
# Creates PVC that binds to the above PV via storageClassName: manual

kubectl apply -f k8s/postgres/statefulset.yaml
# Creates postgres:14 pod — nodeSelector pins it to k8s-lab-worker-1
# PGDATA=/var/lib/postgresql/data/pgdata (subdirectory prevents "not empty" errors)

kubectl apply -f k8s/postgres/service.yaml
# Creates ClusterIP service bmi-postgres-svc:5432
# Backend connects via DNS: bmi-postgres-svc:5432
```

**Verify PV bound:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pv postgres-pv
# Expected: NAME          CAPACITY   STATUS   CLAIM                  STORAGECLASS
#           postgres-pv   5Gi        Bound    bmi-app/postgres-pvc   manual

kubectl get pvc postgres-pvc -n bmi-app
# Expected: NAME           STATUS   VOLUME        CAPACITY
#           postgres-pvc   Bound    postgres-pv   5Gi
```

```bash
# Wait for postgres to be ready before running migrations
kubectl wait --for=condition=ready pod \
  -l app=postgres \
  -n bmi-app \
  --timeout=120s
# Readiness probe: pg_isready -U bmi_user -d bmidb, every 10s, 10s delay
# Expected: pod/postgres-0 condition met
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pod postgres-0 -n bmi-app
# Expected: NAME         READY   STATUS    RESTARTS   AGE
#           postgres-0   1/1     Running   0          30s
```

### Step 3 — Database Migrations

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app

kubectl apply -f k8s/postgres/migrations-configmap.yaml
# Stores 001_create_measurements.sql and 002_add_measurement_date.sql as a ConfigMap
# The Job mounts this ConfigMap as a volume at /migrations

kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
# K8s Jobs are immutable once complete — must delete before re-creating
# --ignore-not-found=true: no error if the job does not exist yet

kubectl apply -f k8s/postgres/migration-job.yaml
# Creates the Job:
#   initContainer (busybox): polls nc -z bmi-postgres-svc 5432 until open
#   main container (postgres:14): runs psql for 001 then 002
#   001: CREATE TABLE IF NOT EXISTS measurements (...) — idempotent
#   002: ADD COLUMN IF NOT EXISTS measurement_date — idempotent

kubectl wait --for=condition=complete job/bmi-migrations \
  -n bmi-app \
  --timeout=90s
# Expected: job.batch/bmi-migrations condition met
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl logs -n bmi-app job/bmi-migrations
# Expected output includes:
#   Running migration 001...
#   Running migration 002...
#   All migrations completed successfully!

kubectl get job bmi-migrations -n bmi-app
# Expected: NAME             COMPLETIONS   DURATION
#           bmi-migrations   1/1           15s
```

### Step 4 — Backend

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app

kubectl apply -f k8s/backend/secret.yaml
# Creates/updates backend-secret with DATABASE_URL

kubectl apply -f k8s/backend/configmap.yaml
# Creates/updates backend-config with NODE_ENV=production, PORT=3000, FRONTEND_URL

kubectl apply -f k8s/backend/deployment.yaml
# Creates 2 backend pods using the new image tag from ECR
# imagePullSecrets: ecr-credentials
# Resources: requests 100m CPU/128Mi mem, limits 300m/256Mi
# Liveness:  GET /health :3000 every 30s (delay 20s, fail threshold 3)
# Readiness: GET /health :3000 every 10s (delay 10s, fail threshold 3)

kubectl apply -f k8s/backend/service.yaml
# Creates ClusterIP bmi-backend-svc:3000
# Nginx frontend proxies /api/* to this service

kubectl rollout status deployment/bmi-backend -n bmi-app --timeout=90s
# Waits for rolling update to complete — both replicas Ready
# Expected: deployment "bmi-backend" successfully rolled out
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pods -n bmi-app -l app=bmi-backend
# Expected: 2 pods, both READY 1/1, STATUS Running

kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"}
```

### Step 5 — Frontend

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app

kubectl apply -f k8s/frontend/deployment.yaml
# Creates 2 Nginx pods serving the React SPA
# Nginx proxies /api/* → http://bmi-backend-svc:3000 (in-cluster DNS)
# Resources: requests 50m/64Mi, limits 200m/128Mi
# Liveness/Readiness: GET / on :80

kubectl apply -f k8s/frontend/service.yaml
# Creates NodePort service bmi-frontend-svc
# Exposes port 30080 on ALL cluster nodes → routes to Nginx pods on :80

kubectl rollout status deployment/bmi-frontend -n bmi-app --timeout=90s
# Expected: deployment "bmi-frontend" successfully rolled out
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pods -n bmi-app -l app=bmi-frontend
# Expected: 2 pods, both READY 1/1, STATUS Running

kubectl get svc bmi-frontend-svc -n bmi-app
# Expected: TYPE=NodePort, PORT(S)=80:30080/TCP
```

### Final Verification — All Resources

```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app

kubectl get pods -n bmi-app
# Expected:
# NAME                             READY   STATUS      RESTARTS   AGE
# bmi-backend-xxxxxxx-xxxxx        1/1     Running     0          1m
# bmi-backend-xxxxxxx-xxxxx        1/1     Running     0          1m
# bmi-frontend-xxxxxxx-xxxxx       1/1     Running     0          45s
# bmi-frontend-xxxxxxx-xxxxx       1/1     Running     0          45s
# bmi-migrations-xxxxx             0/1     Completed   0          2m
# postgres-0                       1/1     Running     0          3m

kubectl get svc -n bmi-app
# Expected:
# NAME               TYPE        PORT(S)        AGE
# bmi-backend-svc    ClusterIP   3000/TCP       1m
# bmi-frontend-svc   NodePort    80:30080/TCP   45s
# bmi-postgres-svc   ClusterIP   5432/TCP       3m
```

**App is live: http://13.127.210.35:30080**

---

# Update Workflow (Every Code Change)

### Step 1 — Local machine

> **Directory: local machine — kubernetes-3tier-app/**

```bash
# With script (recommended):
bash k8s/build-and-push.sh

# Without script — run Phases 2.2 through 2.7 in order
```

### Step 2 — Control-plane

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
# With script:
git pull && bash k8s/deploy.sh

# Without script:
git pull
# Then run Phase 2.8 Steps 0–5
```

> `kubectl apply` with a changed image tag triggers a **rolling update** automatically.  
> Pods are replaced one at a time — zero downtime.

---

# Rollback

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
# Roll back to the previous deployment
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app

# List available revisions
kubectl rollout history deployment/bmi-backend -n bmi-app

# Roll back to a specific revision number
kubectl rollout undo deployment/bmi-backend -n bmi-app --to-revision=2
```

**Verify:**
```bash
kubectl get pods -n bmi-app
# All pods should return to Running with the previous image tag
```

---

# Useful Commands

> **All commands run on k8s-lab-master — ~/kubernetes-3tier-app unless noted**

```bash
# Live pod watch
kubectl get pods -n bmi-app -w

# Describe a pod — shows events, image pull errors, probe failures
kubectl describe pod -n bmi-app <pod-name>

# Application logs
kubectl logs -n bmi-app deploy/bmi-backend
kubectl logs -n bmi-app deploy/bmi-frontend
kubectl logs -n bmi-app statefulset/postgres
kubectl logs -n bmi-app job/bmi-migrations

# All resources in namespace
kubectl get all -n bmi-app

# Storage
kubectl get pv,pvc -n bmi-app

# Check ECR pull secret
kubectl get secret ecr-credentials -n bmi-app

# Manually refresh ECR token (if image pulls fail between deploys)
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
bash k8s/setup-ecr-secret.sh

# Force restart without image change
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app

# Re-run migrations manually
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
kubectl apply -f k8s/postgres/migration-job.yaml
kubectl wait --for=condition=complete job/bmi-migrations -n bmi-app --timeout=90s
```

---

## Reference

| Item | Value |
|---|---|
| App URL | http://13.127.210.35:30080 |
| Control-plane public IP | 13.127.210.35 |
| Control-plane private IP | 10.0.10.34 |
| Worker-1 private IP | 10.0.132.170 |
| Worker-2 private IP | 10.0.141.21 |
| ECR registry | 388779989543.dkr.ecr.ap-south-1.amazonaws.com |
| Kubernetes namespace | bmi-app |
| PostgreSQL data path | /data/postgres on k8s-lab-worker-1 |
| PV reclaim policy | Retain — data not deleted on pod/PVC deletion |
| Image tag strategy | git short SHA — unique per commit |
| ECR token lifetime | 12 hours — must refresh before deploying |
| Secrets in git | Never — postgres/secret.yaml and backend/secret.yaml are .gitignored |

---

## Author

*Md. Sarowar Alam*
Lead DevOps Engineer, Hogarth Worldwide
Email: sarowar@hotmail.com
LinkedIn: https://www.linkedin.com/in/sarowar/
