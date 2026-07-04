# BMI Health Tracker — ArgoCD Manual Deployment Guide

**Cluster:** 1 master + 2 workers (kubeadm)
**Deployment:** GitOps via ArgoCD — every `git push` auto-deploys
**Repo:** https://github.com/sarowar-alam/kubernetes-3tier-app

---

## How GitOps Works

```
Local machine  →  git push  →  GitHub (main branch)
                                  └─ ArgoCD polls every ~3 min
                                       └─ Detects diff in k8s-argocd/app/
                                            └─ Syncs in wave order:
                                                 Wave 1 → PostgreSQL StatefulSet
                                                 Wave 2 → Migration Job (Sync hook)
                                                 Wave 3 → Backend Deployment
                                                 Wave 4 → Frontend Deployment
```

After initial setup, every code change = `git push`. No SSH to the cluster needed.

**Sync rules:**
- `selfHeal: true` — any manual `kubectl edit` is reverted within ~3 minutes
- `prune: true` — resources deleted from git are removed from the cluster
- **Always edit files in git and push — never edit live resources directly**

---

## Cluster Topology

| Node | Role | Note |
|---|---|---|
| master | Control-plane | Run all `kubectl` commands here |
| worker-1 | PostgreSQL storage | Hosts `/data/postgres`; labelled `role=postgres-storage` in Step 3.5 |
| worker-2 | Application workloads | Runs backend and frontend pods |

---

## Table of Contents

- [Phase 1 — Local Machine Prerequisites](#phase-1--local-machine-prerequisites)
- [Phase 2 — AWS Console One-Time Setup](#phase-2--aws-console-one-time-setup)
- [Phase 3 — Master Node One-Time Setup](#phase-3--master-node-one-time-setup)
- [Phase 4 — Build and Push Images](#phase-4--build-and-push-images)
- [Phase 5 — Watch ArgoCD Sync](#phase-5--watch-argocd-sync)
- [Update Workflow](#update-workflow)
- [Rollback](#rollback)
- [Useful Commands](#useful-commands)
- [Troubleshooting](#troubleshooting)

---

## Phase 1 — Local Machine Prerequisites

> Do **all** steps in this phase on your **laptop / workstation** before touching any server.

### Install Docker

**macOS / Windows:** Download Docker Desktop → https://www.docker.com/products/docker-desktop/

**Ubuntu / Debian:**
```bash
# Remove old versions
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker official repo
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker CE
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# Run Docker without sudo
sudo usermod -aG docker $USER && newgrp docker
```

**Verify:**
```bash
docker --version
docker run --rm hello-world   # Expected: Hello from Docker!
```

---

### Install AWS CLI v2

**macOS:** `brew install awscli`

**Windows:** `winget install Amazon.AWSCLI`

**Ubuntu / Debian:**
```bash
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
  -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp/awscli-install
sudo /tmp/awscli-install/aws/install
rm -rf /tmp/awscli.zip /tmp/awscli-install
```

**Verify:** `aws --version`

---

### Configure AWS Credentials

Choose **one** option. Both work with all commands in this guide.

**Option A — Named profile (recommended, persists across sessions):**
```bash
aws configure --profile sarowar-ostad
# AWS Access Key ID:     <your IAM user access key>
# AWS Secret Access Key: <your IAM user secret key>
# Default region name:   ap-south-1
# Default output format: json
```
Verify: `aws sts get-caller-identity --profile sarowar-ostad`

**Option B — Environment variables (current terminal session only):**
```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="ap-south-1"
```

> All commands in this guide include `--profile sarowar-ostad`.
> If using Option B, remove that flag from every command.

---

### Clone the Repository

```bash
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app
```

---

## Phase 2 — AWS Console One-Time Setup

### 2.1 Create ECR Repositories

AWS Console → Elastic Container Registry → Create repository (×2):
- Name: `bmi-backend` — Private, tag immutability: off
- Name: `bmi-frontend` — Private, tag immutability: off

Verify from local machine:
```bash
aws ecr describe-repositories --region ap-south-1 --profile sarowar-ostad \
  --query 'repositories[].repositoryName'
# Expected: [ "bmi-backend", "bmi-frontend" ]
```

---

### 2.2 Create IAM Role — `k8s-node-ecr-role`

AWS Console → IAM → Roles → Create role:
- Trusted entity: **AWS service**
- Use case: **EC2**
- Attach policy: `AmazonEC2ContainerRegistryReadOnly`
- Role name: `k8s-node-ecr-role`

---

### 2.3 Attach Role to All 3 EC2 Instances

EC2 → Instances → select each → Actions → Security →
Modify IAM role → select `k8s-node-ecr-role`

Repeat for: **master**, **worker-1**, **worker-2**

> This lets nodes pull images from ECR via the EC2 instance profile — no stored credentials needed.

---

### 2.4 Add ECR Push Policy to Your IAM User

AWS Console → IAM → Users → your user → Permissions →
Add permissions → Create inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
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
  }]
}
```

---

## Phase 3 — Master Node One-Time Setup

> Connect: `ssh ubuntu@<MASTER-PUBLIC-IP>`
> All commands run from `~/kubernetes-3tier-app` unless noted.

---

### Step 3.1 — Verify Cluster Health

```bash
kubectl get nodes -o wide
# Expected: all 3 nodes STATUS=Ready
# Note the NAME of the worker that will host PostgreSQL storage — needed in Step 3.5
```

---

### Step 3.2 — Install AWS CLI on Master

```bash
apt-get install -y unzip
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
  -o /tmp/aws-cli.zip
unzip -q /tmp/aws-cli.zip -d /tmp/aws-cli
sudo /tmp/aws-cli/aws/install
rm -rf /tmp/aws-cli.zip /tmp/aws-cli
```

Verify: `aws --version`

---

### Step 3.3 — Clone Repository

```bash
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app
```

---

### Step 3.4 — Create Namespaces

> `argocd` must exist before ArgoCD is installed.
> `bmi-app` must exist before the ECR secret and application secrets are created.

```bash
kubectl apply -f k8s-argocd/argocd/namespace.yaml
kubectl apply -f k8s-argocd/app/namespace.yaml
```

Verify:
```bash
kubectl get ns argocd bmi-app
# Expected: both STATUS=Active
```

---

### Step 3.5 — Label the PostgreSQL Storage Node

> **Critical.** The `pv.yaml`, `statefulset.yaml`, and `migration-job.yaml` all use
> `role: postgres-storage` as their node selector. Without this label the postgres
> pod stays Pending forever.

```bash
# Replace <WORKER-1-NODE-NAME> with the exact name from: kubectl get nodes
kubectl label node <WORKER-1-NODE-NAME> role=postgres-storage --overwrite
```

Verify:
```bash
kubectl get node <WORKER-1-NODE-NAME> --show-labels | grep postgres-storage
# Expected: role=postgres-storage visible in the labels column
```

---

### Step 3.6 — Create Application Secrets

> These are **gitignored** — never committed to git.
> Created once; they persist in the cluster across deployments.
> Use the **same password** in both commands below.

```bash
DB_PASS="<YOUR-STRONG-PASSWORD>"   # min 8 chars, e.g. MyStr0ng!Pass2026

# postgres-secret — credentials read by the PostgreSQL pod at startup
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb \
  --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="${DB_PASS}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -

# backend-secret — DATABASE_URL read by the Node.js backend
kubectl create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:${DB_PASS}@bmi-postgres-svc:5432/bmidb" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:
```bash
kubectl get secret postgres-secret backend-secret -n bmi-app
# Expected: both TYPE=Opaque
```

---

### Step 3.7 — Create `/data/postgres` on Worker-1

The PostgreSQL StatefulSet uses a `hostPath` volume — the directory must exist
on worker-1 before the pod can schedule.

```bash
# SSH from master to worker-1
ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-1-PRIVATE-IP>
```

On **worker-1**:
```bash
sudo mkdir -p /data/postgres
sudo chmod 777 /data/postgres
# PostgreSQL runs as UID 999 — needs write access to this directory
```

Verify:
```bash
ls -ld /data/postgres
# Expected: drwxrwxrwx 2 root root 4096 ...

exit   # return to master
```

---

### Step 3.8 — Create ECR Pull Secret

```bash
# On master, inside ~/kubernetes-3tier-app
ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
# Uses EC2 instance profile IAM role — no static credentials needed

kubectl create secret docker-registry ecr-credentials \
  --docker-server=388779989543.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:
```bash
kubectl get secret ecr-credentials -n bmi-app
# Expected: TYPE=kubernetes.io/dockerconfigjson
```

---

### Step 3.9 — Install ArgoCD

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for ArgoCD server (takes 1–3 minutes):
```bash
kubectl rollout status deployment/argocd-server \
  -n argocd --timeout=180s
# Expected: deployment "argocd-server" successfully rolled out
```

Verify:
```bash
kubectl get pods -n argocd
# Expected: ~7 pods, all STATUS=Running READY=1/1
# argocd-server, argocd-repo-server, argocd-application-controller,
# argocd-dex-server, argocd-redis, argocd-notifications-controller,
# argocd-applicationset-controller
```

---

### Step 3.10 — Expose ArgoCD UI as NodePort

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":8080,"nodePort":30081}]}}'
```

Get the admin password:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
# Save this — it is the ArgoCD admin password
```

Verify:
```bash
kubectl get svc argocd-server -n argocd
# Expected: TYPE=NodePort, PORT(S)=80:30081/TCP
```

> **ArgoCD UI:** `http://<MASTER-PUBLIC-IP>:30081`
> **Username:** `admin` | **Password:** output from command above

---

### Step 3.11 — Create ArgoCD Application

```bash
kubectl apply -f k8s-argocd/argocd/application.yaml
# ArgoCD now watches k8s-argocd/app/ on the main branch
```

Force an immediate sync (skip the 3-minute auto-poll):
```bash
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

> **What ArgoCD syncs from git in wave order:**
>
> | Wave | Resources synced |
> |---|---|
> | 1 | PV, PVC, StatefulSet, Service (postgres) |
> | 2 | Migrations ConfigMap + Job (Sync hook — waits for postgres healthy) |
> | 3 | Backend ConfigMap, Deployment, Service |
> | 4 | Frontend Deployment, Service |
>
> The app may show `OutOfSync` or `Degraded` until images are pushed in Phase 4.
> **That is expected — continue to Phase 4.**

Verify:
```bash
kubectl get application bmi-health-tracker -n argocd
```

---

### Step 3.12 — Apply ECR Token Auto-Refresh CronJob

ECR tokens expire every 12 hours. This CronJob refreshes `ecr-credentials` every 6 hours.

```bash
kubectl apply -f k8s-argocd/infra/ecr-secret-refresher.yaml
# Creates in bmi-app namespace:
#   ServiceAccount  ecr-refresher-sa
#   Role            ecr-refresher-role        (get/create/patch/update secrets)
#   RoleBinding     ecr-refresher-rolebinding
#   CronJob         ecr-secret-refresher      (0 */6 * * * — via EC2 instance profile)
```

Verify:
```bash
kubectl get cronjob ecr-secret-refresher -n bmi-app
# Expected: SCHEDULE=0 */6 * * *  SUSPEND=False  ACTIVE=0
```

---

## Phase 4 — Build and Push Images

> All steps run on your **local machine** from the repo root (`kubernetes-3tier-app/`).

---

### Step 4.1 — Set Variables

```bash
export AWS_PROFILE="sarowar-ostad"   # skip if using Option B env vars from Phase 1
export ECR_BASE="388779989543.dkr.ecr.ap-south-1.amazonaws.com"
export TAG=$(git rev-parse --short HEAD)
echo "Building tag: ${TAG}"
```

---

### Step 4.2 — Log In to ECR

```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin "${ECR_BASE}"
# Expected: Login Succeeded
```

---

### Step 4.3 — Build Images

```bash
docker build -t "bmi-backend:${TAG}"  ./backend
docker build -t "bmi-frontend:${TAG}" ./frontend
```

Verify:
```bash
docker images bmi-backend
docker images bmi-frontend
# Expected: both listed with tag = $TAG
```

---

### Step 4.4 — Tag for ECR

Each image gets two tags: an immutable SHA tag (used in manifests) and `latest`.

```bash
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
```

Verify:
```bash
docker images | grep "${ECR_BASE}"
# Expected: 4 rows (2 images x 2 tags each)
```

---

### Step 4.5 — Push to ECR

```bash
docker push "${ECR_BASE}/bmi-backend:${TAG}"
docker push "${ECR_BASE}/bmi-backend:latest"
docker push "${ECR_BASE}/bmi-frontend:${TAG}"
docker push "${ECR_BASE}/bmi-frontend:latest"
```

Verify:
```bash
aws ecr list-images --repository-name bmi-backend --region ap-south-1 \
  --profile sarowar-ostad --query 'imageIds[].imageTag'
# Expected: [ "<sha>", "latest" ]
```

---

### Step 4.6 — Patch Deployment Manifests with New Image Tag

**Linux / macOS:**
```bash
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s-argocd/app/backend/deployment.yaml

sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s-argocd/app/frontend/deployment.yaml
```

**Windows PowerShell:**
```powershell
(Get-Content k8s-argocd/app/backend/deployment.yaml) `
  -replace 'image: .*bmi-backend:.*', "image: $ECR_BASE/bmi-backend:$TAG" |
  Set-Content k8s-argocd/app/backend/deployment.yaml

(Get-Content k8s-argocd/app/frontend/deployment.yaml) `
  -replace 'image: .*bmi-frontend:.*', "image: $ECR_BASE/bmi-frontend:$TAG" |
  Set-Content k8s-argocd/app/frontend/deployment.yaml
```

Verify:
```bash
grep "image:" k8s-argocd/app/backend/deployment.yaml
grep "image:" k8s-argocd/app/frontend/deployment.yaml
# Expected: full ECR URL with the SHA tag in each file
```

---

### Step 4.7 — Commit and Push to Git

```bash
git add k8s-argocd/app/backend/deployment.yaml \
        k8s-argocd/app/frontend/deployment.yaml

git diff --staged   # confirm only the image: line changed in each file

git commit -m "deploy(argocd): image tag ${TAG}"
git push
# ArgoCD detects the diff and auto-syncs within ~3 minutes
```

---

## Phase 5 — Watch ArgoCD Sync

> Run on the **master node**.

```bash
# Watch the Application converge
kubectl get application bmi-health-tracker -n argocd -w
# Expected: OutOfSync → Syncing → Synced  |  Progressing → Healthy

# Watch pods come up in wave order
kubectl get pods -n bmi-app -w
# Wave 1: postgres-0           → Running
# Wave 2: bmi-migrations-xxx   → Completed  (runs SQL migrations, then exits)
# Wave 3: bmi-backend-xxx      → Running    (x2 replicas)
# Wave 4: bmi-frontend-xxx     → Running    (x2 replicas)
```

### Final Verification

```bash
kubectl get pods -n bmi-app
# Expected:
# NAME                          READY   STATUS      RESTARTS   AGE
# bmi-backend-xxx               1/1     Running     0          1m
# bmi-backend-xxx               1/1     Running     0          1m
# bmi-frontend-xxx              1/1     Running     0          45s
# bmi-frontend-xxx              1/1     Running     0          45s
# bmi-migrations-xxx            0/1     Completed   0          2m
# postgres-0                    1/1     Running     0          3m

kubectl get svc -n bmi-app
# Expected:
# bmi-backend-svc    ClusterIP  3000/TCP
# bmi-frontend-svc   NodePort   80:30080/TCP
# bmi-postgres-svc   ClusterIP  5432/TCP

kubectl get pv,pvc
# Expected: postgres-pv STATUS=Bound, postgres-pvc STATUS=Bound

kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"}

kubectl get application bmi-health-tracker -n argocd
# Expected: SYNC STATUS=Synced  HEALTH STATUS=Healthy
```

**App is live: `http://<MASTER-PUBLIC-IP>:30080`**
**ArgoCD UI:   `http://<MASTER-PUBLIC-IP>:30081`**

---

## Update Workflow

After initial setup, every code change is just a `git push`.

### On local machine

```bash
# With script (recommended — runs Phase 4 automatically):
bash k8s-argocd/build-and-push.sh

# Without script — run Phase 4 steps 4.1 through 4.7 manually
```

### ArgoCD auto-syncs

No SSH needed. ArgoCD detects the manifest diff within ~3 minutes.

Force immediate sync from master:
```bash
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

> Pods are replaced one at a time — rolling update, zero downtime.

---

## Rollback

### Option A — Git Revert (recommended — the GitOps way)

```bash
# Local machine
git revert HEAD       # new commit that reverses the last change
git push              # ArgoCD auto-syncs within ~3 minutes
```

Revert to a specific commit:
```bash
git revert <COMMIT-SHA>
git push
```

### Option B — kubectl Rollback (immediate, bypasses git)

> ArgoCD `selfHeal: true` will revert this within ~3 minutes.
> Disable auto-sync in the ArgoCD UI first if you need the rollback to persist.

```bash
# On master
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app

# List available revisions
kubectl rollout history deployment/bmi-backend -n bmi-app

# Roll back to a specific revision
kubectl rollout undo deployment/bmi-backend -n bmi-app --to-revision=2
```

---

## Useful Commands

```bash
# Live pod watch
kubectl get pods -n bmi-app -w

# Describe a stuck pod — shows events, image pull errors, probe failures
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

# ArgoCD application status
kubectl get application bmi-health-tracker -n argocd

# Force ArgoCD sync
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Manually refresh ECR token (if pods show ImagePullBackOff between deploys)
bash k8s-argocd/setup-ecr-secret.sh
# Pods retry automatically within ~30 seconds

# Re-run migrations manually
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found
kubectl apply  -f k8s-argocd/app/postgres/migration-job.yaml
kubectl wait --for=condition=complete job/bmi-migrations \
  -n bmi-app --timeout=90s

# Force restart without image change
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app
```

---

## Troubleshooting

### `postgres-0` stuck in Pending

```bash
kubectl describe pod postgres-0 -n bmi-app
```

| Symptom in Events | Cause | Fix |
|---|---|---|
| `node(s) didn't match node selector` | Worker-1 not labelled | Run Step 3.5 |
| `no persistent volumes available` | PV nodeAffinity not matching | Confirm Step 3.5 was done |
| `persistentvolumeclaim not found` | ArgoCD not yet synced | Force sync — Step 3.11 |

---

### Pods in `ImagePullBackOff`

ECR token expired (tokens last 12 hours).
```bash
bash k8s-argocd/setup-ecr-secret.sh
# Pods retry automatically within ~30 seconds
```

---

### Migration job stuck in `Init:0/1`

The initContainer polls `bmi-postgres-svc:5432` — waiting for postgres.
```bash
kubectl get pods -n bmi-app                         # confirm postgres-0 is Running
kubectl get endpoints bmi-postgres-svc -n bmi-app  # endpoint must exist
kubectl logs postgres-0 -n bmi-app                  # check postgres startup errors
```

---

### ArgoCD app shows `OutOfSync` after initial setup

Expected — happens before ECR images exist. After Phase 4 `git push`, ArgoCD syncs automatically.

---

### ArgoCD repo-server not starting

```bash
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status  deployment/argocd-repo-server -n argocd --timeout=120s
```

---

### ArgoCD Application deleted accidentally

```bash
kubectl apply -f k8s-argocd/argocd/application.yaml
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## Reference

| Item | Value |
|---|---|
| App URL | `http://<MASTER-PUBLIC-IP>:30080` |
| ArgoCD UI | `http://<MASTER-PUBLIC-IP>:30081` |
| ArgoCD username | `admin` |
| ECR registry | `388779989543.dkr.ecr.ap-south-1.amazonaws.com` |
| Kubernetes namespace | `bmi-app` |
| PostgreSQL data path | `/data/postgres` on worker-1 |
| ArgoCD watches | `k8s-argocd/app/` on `main` branch |
| Sync waves | 1=Postgres, 2=Migrations, 3=Backend, 4=Frontend |
| ECR token refresh | Every 6h via CronJob `ecr-secret-refresher` |
