# BMI Health Tracker — ArgoCD GitOps Implementation Guide

**Repo:** https://github.com/sarowar-alam/kubernetes-3tier-app
**App URL:** http://13.127.210.35:30080
**ArgoCD UI:** http://13.127.210.35:30081
**Namespace:** `bmi-app` (application) | `argocd` (ArgoCD control plane)

---

## How GitOps Works

ArgoCD continuously watches the `k8s-argocd/app/` directory on the `main` branch of the GitHub repository. Every `git push` triggers an automatic deployment — no SSH to the cluster is needed after initial setup.

```
Local machine  →  git push  →  GitHub (main branch)
                                  └─ ArgoCD polls every ~3 minutes
                                       └─ Detects manifest diff in k8s-argocd/app/
                                            └─ Syncs in wave order:
                                                 Wave 1 → PostgreSQL StatefulSet     (database first)
                                                 Wave 2 → Migration Job (Sync hook)  (schema before API)
                                                 Wave 3 → Backend Deployment         (API before UI)
                                                 Wave 4 → Frontend Deployment
```

**Sync behaviours:**
- `prune: true` — resources deleted from git are removed from the cluster automatically
- `selfHeal: true` — any manual `kubectl edit` is reverted within ~3 minutes
- **Rule:** always edit files in git, commit, and push — never edit live resources directly

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
            └─ bmi-postgres-svc:5432 → PostgreSQL StatefulSet (k8s-lab-worker-1)
```

---

## Repository Files — What Each Does

| File | Applied By | Purpose | Required? |
|---|---|---|---|
| `argocd/namespace.yaml` | One-time setup | Creates the `argocd` namespace before ArgoCD can be installed | Yes |
| `argocd/application.yaml` | One-time setup | Registers the app with ArgoCD — this file itself is NOT watched by ArgoCD; changes must be re-applied with `kubectl apply` | Yes |
| `app/namespace.yaml` | ArgoCD (auto) | Creates the `bmi-app` namespace | Yes |
| `app/postgres/secret.yaml` | One-time setup (gitignored) | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — must exist locally before setup runs | Yes |
| `app/postgres/pv.yaml` | ArgoCD (auto) | 5Gi hostPath PersistentVolume pinned to k8s-lab-worker-1, Retain policy | Yes |
| `app/postgres/pvc.yaml` | ArgoCD (auto) | Binds to `postgres-pv` via `storageClassName: manual` | Yes |
| `app/postgres/statefulset.yaml` | ArgoCD (auto, wave 1) | PostgreSQL 14 pod pinned to k8s-lab-worker-1 | Yes |
| `app/postgres/service.yaml` | ArgoCD (auto) | ClusterIP `bmi-postgres-svc:5432` | Yes |
| `app/postgres/migrations-configmap.yaml` | ArgoCD (auto) | Embeds `001_create_measurements.sql` and `002_add_measurement_date.sql` as a volume | Yes |
| `app/postgres/migration-job.yaml` | ArgoCD (Sync hook, wave 2) | Runs SQL migrations after Postgres is healthy; auto-deleted before each re-sync | Yes |
| `app/backend/secret.yaml` | One-time setup (gitignored) | `DATABASE_URL` — must exist locally before setup runs | Yes |
| `app/backend/configmap.yaml` | ArgoCD (auto) | `NODE_ENV`, `PORT`, `FRONTEND_URL` | Yes |
| `app/backend/deployment.yaml` | ArgoCD (auto, wave 3) | 2 backend replicas; `image:` line patched by `build-and-push.sh` on every deploy | Yes |
| `app/backend/service.yaml` | ArgoCD (auto) | ClusterIP `bmi-backend-svc:3000` | Yes |
| `app/frontend/deployment.yaml` | ArgoCD (auto, wave 4) | 2 Nginx replicas; `image:` line patched by `build-and-push.sh` on every deploy | Yes |
| `app/frontend/service.yaml` | ArgoCD (auto) | NodePort `bmi-frontend-svc:30080` | Yes |
| `infra/ecr-secret-refresher.yaml` | One-time setup (manual) | CronJob every 6h + ServiceAccount + RBAC — auto-refreshes ECR token; `bootstrap.sh` does NOT apply this | Yes — must be applied manually |
| `bootstrap.sh` | Part 1 — run once on master | Automates all one-time cluster setup commands (8 steps) | Part 1 only |
| `build-and-push.sh` | Part 1 — run locally every deploy | ECR login → build → tag → push → patch manifests → git commit | Part 1 only |
| `setup-ecr-secret.sh` | Emergency fallback on master | Manual ECR token refresh; also called internally by `bootstrap.sh` at step [4.5/8] | Yes |

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Part 1 — Deploy WITH Automation Scripts](#part-1--deploy-with-automation-scripts)
- [Part 2 — Deploy WITHOUT Automation Scripts (Full Manual)](#part-2--deploy-without-automation-scripts-full-manual)
- [Update Workflow (Every Code Change)](#update-workflow-every-code-change)
- [Rollback](#rollback)
- [Useful Commands](#useful-commands)
- [Troubleshooting](#troubleshooting)
- [Reference](#reference)

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
# Replace the example values with your actual IAM user credentials
# These override any profile for the duration of the current terminal session
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
| `k8s-argocd/bootstrap.sh` | k8s-lab-master (once only) | Namespaces → secrets → PV → ECR secret → ArgoCD install → expose UI → create Application |
| `k8s-argocd/build-and-push.sh` | Local machine (every deploy) | Build images → push to ECR → patch manifests → git commit → ArgoCD auto-syncs |

---

## Phase 1.1 — One-Time Cluster Preparation

### A. Prepare Worker-1 Storage

> **Directory: k8s-lab-worker-1 — home directory (`~`)**

```bash
# From local machine — jump through master to worker-1
ssh -J ubuntu@13.127.210.35 ubuntu@10.0.132.170

# On k8s-lab-worker-1:
sudo mkdir -p /data/postgres
# Creates /data/postgres — required by the PostgreSQL hostPath PersistentVolume

sudo chmod 777 /data/postgres
# PostgreSQL pod runs as UID 999 — requires write access to this directory
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

# Install AWS CLI (required by bootstrap.sh to create ECR pull secret)
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
ls k8s-argocd/
# Expected: app/  argocd/  infra/  bootstrap.sh  build-and-push.sh  deployment-manually-v2.md  ...
```

### C. Edit Secrets Before Running bootstrap.sh

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
# Edit PostgreSQL secret — change password before applying
nano k8s-argocd/app/postgres/secret.yaml
# Change POSTGRES_PASSWORD: "CHANGE_ME" to something strong
# Example: POSTGRES_PASSWORD: "MyStr0ng!Pass2026"
```

```bash
# Edit backend secret — DATABASE_URL password must match POSTGRES_PASSWORD above
nano k8s-argocd/app/backend/secret.yaml
# Change: postgres://bmi_user:CHANGE_ME@bmi-postgres-svc:5432/bmidb
# To:     postgres://bmi_user:MyStr0ng!Pass2026@bmi-postgres-svc:5432/bmidb
```

> ⚠️ These two files are gitignored — they exist only on this machine. Never commit them.

---

## Phase 1.2 — Run bootstrap.sh

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
bash k8s-argocd/bootstrap.sh
# Runs all 8 steps of one-time cluster setup automatically
# Takes approximately 3–5 minutes (ArgoCD install is the longest step)
```

**What the script does internally:**

| Step | What happens |
|---|---|
| [0/8] | Installs AWS CLI if not present; skips if already installed |
| [1/8] | `kubectl apply` — creates `argocd` and `bmi-app` namespaces |
| [2/8] | `kubectl apply` — applies `app/postgres/secret.yaml` and `app/backend/secret.yaml` |
| [3/8] | `kubectl apply` — creates `postgres-pv` (5Gi hostPath on k8s-lab-worker-1, Retain) |
| [4/8] | Runs a busybox pod to create `/data/postgres` on `k8s-lab-worker-1` — skipped safely if step A already created it via SSH |
| [4.5/8] | Calls `setup-ecr-secret.sh` — creates `ecr-credentials` imagePullSecret using EC2 instance profile |
| [5/8] | `kubectl apply` — installs ArgoCD from the official upstream manifest; waits for server Ready |
| [6/8] | `kubectl patch` — exposes `argocd-server` as NodePort 30081 |
| [7/8] | `kubectl apply` — applies `argocd/application.yaml`; forces first hard sync immediately |
| [8/8] | Prints summary: ArgoCD URL, admin password, App URL |

**Expected output (final summary block):**
```
================================================
 Bootstrap complete!

  ArgoCD UI : http://13.127.210.35:30081
  Username  : admin
  Password  : <auto-generated>

  App URL   : http://13.127.210.35:30080

  ArgoCD is now watching: k8s-argocd/app/ on branch main
  Every git push will trigger an automatic sync.

  Sync order (waves):
    Wave 1  → PostgreSQL StatefulSet
    Wave 2  → Migration Job (Sync hook — waits for Postgres healthy)
    Wave 3  → Backend Deployment
    Wave 4  → Frontend Deployment
================================================
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app

# All ArgoCD pods running
kubectl get pods -n argocd
# Expected: all 7 pods STATUS=Running, READY=1/1

# ArgoCD application registered
kubectl get application bmi-health-tracker -n argocd
# Expected: SYNC STATUS=Synced or OutOfSync (OutOfSync is normal — no image pushed yet)

# Namespaces and secrets
kubectl get ns argocd bmi-app
kubectl get secret postgres-secret backend-secret ecr-credentials -n bmi-app

# PV created
kubectl get pv postgres-pv
# Expected: STATUS=Available or Bound, CAPACITY=5Gi, RECLAIM POLICY=Retain
```

**Get ArgoCD admin password:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
# Login at: http://13.127.210.35:30081
# Username: admin  |  Password: output from above command
```

---

## Phase 1.3 — Apply ECR CronJob

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

> `bootstrap.sh` does NOT apply this — it must be applied manually once.

```bash
kubectl apply -f k8s-argocd/infra/ecr-secret-refresher.yaml
# Creates 4 resources in bmi-app namespace:
#   ServiceAccount  ecr-refresher-sa          — identity for the CronJob pods
#   Role            ecr-refresher-role         — permission to create/patch secrets in bmi-app
#   RoleBinding     ecr-refresher-rolebinding  — binds SA to Role
#   CronJob         ecr-secret-refresher       — runs every 6h via EC2 instance profile
#                                                refreshes ecr-credentials secret automatically
#                                                ECR tokens expire after 12h — CronJob keeps them fresh
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get cronjob ecr-secret-refresher -n bmi-app
# Expected: NAME                   SCHEDULE      SUSPEND   ACTIVE
#           ecr-secret-refresher   0 */6 * * *   False     0

kubectl get serviceaccount ecr-refresher-sa -n bmi-app
# Expected: NAME               SECRETS   AGE
#           ecr-refresher-sa   0         5s
```

---

## Phase 1.4 — Build and Push First Images

> **Directory: local machine — kubernetes-3tier-app/**

```bash
cd kubernetes-3tier-app
# IMPORTANT: must be repo root — build-and-push.sh uses ./backend and ./frontend paths

bash k8s-argocd/build-and-push.sh
```

**What the script does internally:**

| Step | Command run internally |
|---|---|
| [1/5] ECR Login | `aws ecr get-login-password \| docker login --username AWS --password-stdin` |
| [2/5] Build | `docker build -t bmi-backend:<SHA> ./backend` and `docker build -t bmi-frontend:<SHA> ./frontend` |
| [3/5] Tag | `docker tag` — adds SHA tag and `latest` tag for ECR (2 images × 2 tags = 4 tags) |
| [4/5] Push | `docker push` — pushes all 4 tags to ECR |
| [5/5] Patch + Commit | `sed` patches `image:` line in `k8s-argocd/app/backend/deployment.yaml` and `frontend/deployment.yaml` → `git commit && git push` |

> After `git push`, ArgoCD detects the manifest diff within ~3 minutes and automatically syncs using the wave order.

**Expected output:**
```
================================================
 BMI Health Tracker — Build & Push (ArgoCD)
 Image tag : 9b8bf6f
 Registry  : 388779989543.dkr.ecr.ap-south-1.amazonaws.com
================================================

[1/5] Logging in to ECR...
Login Succeeded
[2/5] Building backend image...
      Building frontend image...
[3/5] Tagging images...
[4/5] Pushing to ECR...
[5/5] Patching k8s-argocd/app/ manifests with new image tag...
      Manifests committed and pushed.
      ArgoCD will detect the diff and sync within ~3 minutes.

================================================
 Done!
   Backend  : 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f
   Frontend : 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
================================================
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
grep "image:" k8s-argocd/app/backend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f

grep "image:" k8s-argocd/app/frontend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

---

## Phase 1.5 — Watch ArgoCD Sync

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
# Watch ArgoCD application converge
kubectl get application bmi-health-tracker -n argocd -w
# Expected progression: OutOfSync → Syncing → Synced + Healthy

# Watch pods come up in wave order
kubectl get pods -n bmi-app -w
# Expected wave order:
#   postgres-0           → Running   (wave 1 — PostgreSQL ready)
#   bmi-migrations-xxx   → Completed (wave 2 — Sync hook runs and exits)
#   bmi-backend-xxx      → Running   (wave 3, ×2 replicas)
#   bmi-frontend-xxx     → Running   (wave 4, ×2 replicas)
```

**Final Verification — All Resources:**
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
# NAME               TYPE        PORT(S)          AGE
# bmi-backend-svc    ClusterIP   3000/TCP         1m
# bmi-frontend-svc   NodePort    80:30080/TCP     45s
# bmi-postgres-svc   ClusterIP   5432/TCP         3m

kubectl get pv,pvc -n bmi-app
# Expected: postgres-pv STATUS=Bound, postgres-pvc STATUS=Bound

kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"}

kubectl get application bmi-health-tracker -n argocd
# Expected: SYNC STATUS=Synced, HEALTH STATUS=Healthy
```

**Open in browser: http://13.127.210.35:30080**
**ArgoCD UI: http://13.127.210.35:30081**

---

# Part 2 — Deploy WITHOUT Automation Scripts (Full Manual)

Every command that the scripts execute, broken down individually with explanations.
No `.sh` files are executed — every step is a direct command.

---

## Phase 2.1 — One-Time Cluster Preparation

Same as Phase 1.1 — see sections A, B, and C above.

---

## Phase 2.2 — Create Namespaces

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -f k8s-argocd/argocd/namespace.yaml
# Creates the argocd namespace — ArgoCD must be installed into this namespace

kubectl apply -f k8s-argocd/app/namespace.yaml
# Creates the bmi-app namespace — all application resources live here
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get ns argocd bmi-app
# Expected:
# NAME      STATUS   AGE
# argocd    Active   5s
# bmi-app   Active   5s
```

---

## Phase 2.3 — Apply Secrets and PersistentVolume

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -f k8s-argocd/app/postgres/secret.yaml
# Creates postgres-secret with POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
# Read by the PostgreSQL StatefulSet pod via envFrom at startup

kubectl apply -f k8s-argocd/app/backend/secret.yaml
# Creates backend-secret with DATABASE_URL connection string
# Format: postgres://bmi_user:<password>@bmi-postgres-svc:5432/bmidb

kubectl apply -f k8s-argocd/app/postgres/pv.yaml
# Creates 5Gi hostPath PersistentVolume
# reclaimPolicy: Retain — data is NOT deleted if PVC or pod is deleted
# nodeAffinity pins it to k8s-lab-worker-1 — storage physically lives on that node
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get secret postgres-secret backend-secret -n bmi-app
# Expected: both TYPE=Opaque

kubectl get pv postgres-pv
# Expected: STATUS=Available, CAPACITY=5Gi, RECLAIM POLICY=Retain, STORAGECLASS=manual
```

---

## Phase 2.4 — Create ECR Pull Secret

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
# Uses the EC2 instance profile IAM role to fetch a 12-hour temporary ECR password
# No static AWS credentials needed — role is attached directly to the EC2 instance

kubectl create secret docker-registry ecr-credentials \
  --docker-server=388779989543.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
# --dry-run=client -o yaml: generates the Secret YAML without applying it
# | kubectl apply -f -:     pipes to stdin — idempotent, creates or updates the secret
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get secret ecr-credentials -n bmi-app
# Expected: NAME              TYPE                             DATA   AGE
#           ecr-credentials   kubernetes.io/dockerconfigjson   1      5s
```

---

## Phase 2.5 — Install ArgoCD

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# --server-side --force-conflicts: handles both fresh installs and re-runs gracefully
# Installs ~50 ArgoCD resources: Deployments, Services, CRDs, RBAC rules
```

```bash
# Wait for ArgoCD server to be ready — takes 1–3 minutes
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
# Expected: deployment "argocd-server" successfully rolled out
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pods -n argocd
# Expected: all 7 pods STATUS=Running, READY=1/1
# Pods: argocd-server, argocd-repo-server, argocd-application-controller,
#       argocd-dex-server, argocd-redis, argocd-notifications-controller,
#       argocd-applicationset-controller
```

---

## Phase 2.6 — Expose ArgoCD UI as NodePort

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":8080,"nodePort":30081}]}}'
# Changes argocd-server from ClusterIP to NodePort
# Port 30081 on master public IP → routes to ArgoCD UI on container port 8080
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get svc argocd-server -n argocd
# Expected: TYPE=NodePort, PORT(S)=80:30081/TCP
```

**Get ArgoCD admin password:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
# ArgoCD UI: http://13.127.210.35:30081
# Username: admin  |  Password: output from above command
```

---

## Phase 2.7 — Apply ArgoCD Application

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -f k8s-argocd/argocd/application.yaml
# Creates the ArgoCD Application resource bmi-health-tracker:
#   source: k8s-argocd/app/ on main branch (recurse: true → scans all subdirs)
#   destination: bmi-app namespace in this cluster
#   syncPolicy: automated with prune=true and selfHeal=true
#   syncOptions: ServerSideApply (required for large migration ConfigMap)
# ArgoCD immediately starts watching the repo after this is applied
```

```bash
# Force an immediate sync — don't wait for the 3-minute auto-poll
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
# Triggers ArgoCD to re-fetch the repo and sync in the next few seconds
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get application bmi-health-tracker -n argocd
# Expected: SYNC STATUS=Synced (OutOfSync is normal until first image is pushed)
#           HEALTH STATUS=Healthy
```

---

## Phase 2.8 — Apply ECR CronJob

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -f k8s-argocd/infra/ecr-secret-refresher.yaml
# Creates 4 resources in bmi-app namespace:
#   ServiceAccount  ecr-refresher-sa          — identity used by CronJob pods
#   Role            ecr-refresher-role         — allows get/create/patch/update on secrets
#   RoleBinding     ecr-refresher-rolebinding  — binds the ServiceAccount to the Role
#   CronJob         ecr-secret-refresher       — schedule: every 6 hours (0 */6 * * *)
#                                                Uses EC2 instance profile — no static creds
#                                                Refreshes ecr-credentials before the 12h token expires
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get cronjob ecr-secret-refresher -n bmi-app
# Expected: SCHEDULE=0 */6 * * *  SUSPEND=False  ACTIVE=0

kubectl get rolebinding ecr-refresher-rolebinding -n bmi-app
# Expected: rolebinding exists with ecr-refresher-role
```

---

## Phase 2.9 — Authenticate to ECR

> **Directory: local machine — kubernetes-3tier-app/**

```bash
cd kubernetes-3tier-app
# Must be at repo root — sed commands in Phase 2.13 reference k8s-argocd/app/*/deployment.yaml
```

**Set variables — choose Option A or Option B:**

```bash
# Option A — Named profile (if you ran aws configure --profile sarowar-ostad)
export AWS_PROFILE="sarowar-ostad"

# Option B — Environment variables (if you did NOT create a named profile)
# export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
# export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
# export AWS_DEFAULT_REGION="ap-south-1"
# (uncomment Option B lines and comment out Option A if using this)

export ECR_BASE="388779989543.dkr.ecr.ap-south-1.amazonaws.com"
export TAG=$(git rev-parse --short HEAD)
# TAG = git short SHA of current commit (e.g. 9b8bf6f)
# Used as the immutable image tag — always traceable to a specific commit

echo "Building tag: ${TAG}"

aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin "${ECR_BASE}"
# aws ecr get-login-password: calls ECR API, returns a 12-hour temporary password
# docker login: registers the credential with the local Docker daemon
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
# docker login prints on success:
# Login Succeeded
echo "Exit code: $?"
# Expected: Exit code: 0
```

---

## Phase 2.10 — Build Docker Images

> **Directory: local machine — kubernetes-3tier-app/**

### Build Backend
```bash
docker build -t "bmi-backend:${TAG}" ./backend
# -t "bmi-backend:<SHA>"   tags the image locally with the git SHA
# ./backend                Docker build context — reads backend/Dockerfile
#
# Dockerfile stages:
#   Stage 1: node:18-alpine — npm install (production dependencies only)
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

## Phase 2.11 — Tag Images for ECR

> **Directory: local machine — kubernetes-3tier-app/**

Each image needs two tags:
- **SHA tag** — immutable, used in Kubernetes deployment manifests
- **latest tag** — always points to the most recent push

```bash
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
# docker tag: creates a new reference to the same image layers — no data copied
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

## Phase 2.12 — Push Images to ECR

> **Directory: local machine — kubernetes-3tier-app/**

```bash
docker push "${ECR_BASE}/bmi-backend:${TAG}"
# Uploads image layers to ECR — only changed layers are sent (Docker layer caching)

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

## Phase 2.13 — Update Deployment Manifests

> **Directory: local machine — kubernetes-3tier-app/**

```bash
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s-argocd/app/backend/deployment.yaml
# sed -i: edit file in-place
# s|old|new|g: replaces the bmi-backend image line regardless of the previous tag value

sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s-argocd/app/frontend/deployment.yaml
```

**PowerShell equivalent (Windows):**
```powershell
# Directory: local machine — kubernetes-3tier-app/
(Get-Content k8s-argocd/app/backend/deployment.yaml) `
  -replace 'image: .*bmi-backend:.*', "image: $ECR_BASE/bmi-backend:$TAG" |
  Set-Content k8s-argocd/app/backend/deployment.yaml

(Get-Content k8s-argocd/app/frontend/deployment.yaml) `
  -replace 'image: .*bmi-frontend:.*', "image: $ECR_BASE/bmi-frontend:$TAG" |
  Set-Content k8s-argocd/app/frontend/deployment.yaml
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
grep "image:" k8s-argocd/app/backend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f

grep "image:" k8s-argocd/app/frontend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

---

## Phase 2.14 — Commit and Push Manifests to Git

> **Directory: local machine — kubernetes-3tier-app/**

```bash
git add k8s-argocd/app/backend/deployment.yaml \
        k8s-argocd/app/frontend/deployment.yaml
# Stages only the two patched deployment files

git diff --staged
# Review the diff — should show only the image: line changed in each file

git commit -m "deploy(argocd): image tag ${TAG}"
# Commits the manifest change with a descriptive message

git push
# Pushes to GitHub — ArgoCD detects the manifest diff within ~3 minutes
# and automatically syncs using the wave order
```

**Verify:**
```bash
# Directory: local machine — kubernetes-3tier-app/
git log --oneline -3
# Expected: most recent commit is "deploy(argocd): image tag 9b8bf6f"
```

---

## Phase 2.15 — Watch ArgoCD Sync

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**
>
> No additional commands needed — ArgoCD detects the git push and syncs automatically.

```bash
# Watch ArgoCD application converge
kubectl get application bmi-health-tracker -n argocd -w
# Expected progression: OutOfSync → Syncing → Synced + Healthy

# Watch pods come up in wave order
kubectl get pods -n bmi-app -w
# Expected wave order:
#   postgres-0           → Running   (wave 1)
#   bmi-migrations-xxx   → Completed (wave 2 — Sync hook)
#   bmi-backend-xxx      → Running   (wave 3, ×2)
#   bmi-frontend-xxx     → Running   (wave 4, ×2)
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
# NAME               TYPE        PORT(S)          AGE
# bmi-backend-svc    ClusterIP   3000/TCP         1m
# bmi-frontend-svc   NodePort    80:30080/TCP     45s
# bmi-postgres-svc   ClusterIP   5432/TCP         3m

kubectl get pv,pvc -n bmi-app
# Expected: postgres-pv STATUS=Bound, postgres-pvc STATUS=Bound

kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"}

kubectl get application bmi-health-tracker -n argocd
# Expected: SYNC STATUS=Synced, HEALTH STATUS=Healthy
```

**App is live: http://13.127.210.35:30080**
**ArgoCD UI: http://13.127.210.35:30081**

---

# Update Workflow (Every Code Change)

After initial setup, deploying a code change requires only a git push — ArgoCD handles the rest.

### Step 1 — Local machine

> **Directory: local machine — kubernetes-3tier-app/**

```bash
# With script (recommended):
bash k8s-argocd/build-and-push.sh

# Without script — run Phases 2.9 through 2.14 in order
```

### Step 2 — ArgoCD auto-syncs

> No SSH to the cluster is needed.

ArgoCD detects the manifest diff on the `main` branch within ~3 minutes and auto-syncs.

To trigger an immediate sync without waiting:
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

> Pods are replaced one at a time using Kubernetes rolling update — zero downtime.

---

# Rollback

## Option A — Git Revert (recommended — the GitOps way)

> **Directory: local machine — kubernetes-3tier-app/**

```bash
git revert HEAD
# Creates a new commit that reverses the last change
# Git history is preserved — no force push needed

git push
# ArgoCD detects the revert within ~3 minutes and rolls back automatically
```

**Or roll back to a specific commit:**
```bash
git revert <commit-SHA>
git push
```

**Verify:**
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get pods -n bmi-app
# Pods should be re-created with the previous image tag
```

## Option B — Emergency kubectl Rollback

> ⚠️ If you use `kubectl rollout undo` without pausing ArgoCD, ArgoCD will revert your rollback within ~3 minutes (`selfHeal: true`). Pause automated sync first.

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
# Step 1: Pause ArgoCD automated sync
kubectl patch application bmi-health-tracker -n argocd \
  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# Disables prune + selfHeal — ArgoCD still watches but does not auto-apply

# Step 2: Roll back the deployments
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app

# Step 3: Verify rollback
kubectl get pods -n bmi-app
# All pods should return to Running with the previous image tag

# Step 4: Re-enable automated sync when ready
kubectl patch application bmi-health-tracker -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
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

# ArgoCD application status
kubectl get application bmi-health-tracker -n argocd

# Force immediate ArgoCD sync
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Get ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Check ECR pull secret
kubectl get secret ecr-credentials -n bmi-app

# Manually refresh ECR token (if pods show ImagePullBackOff between CronJob runs)
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
bash k8s-argocd/setup-ecr-secret.sh

# Check ECR CronJob history
kubectl get cronjob ecr-secret-refresher -n bmi-app
kubectl get jobs -n bmi-app | grep ecr

# Force restart without image change
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app
```

---

# Troubleshooting

### ArgoCD repo-server connection refused
```bash
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=120s
```

### Migration job stuck in Init:0/1
```bash
# Check if postgres-0 is Running
kubectl get pods -n bmi-app

# Check if the service endpoint exists — postgres must be accepting connections
kubectl get endpoints bmi-postgres-svc -n bmi-app
# Expected: an IP:5432 endpoint listed

# Check migration container logs
kubectl logs -l job-name=bmi-migrations -n bmi-app --container run-migrations
```

### Pods in ImagePullBackOff (ECR token expired)
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
bash k8s-argocd/setup-ecr-secret.sh
# Refreshes ecr-credentials secret with a new 12-hour token
# Pods retry image pull automatically within ~30 seconds
```

### ArgoCD Application deleted accidentally
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl apply -f k8s-argocd/argocd/application.yaml
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Manual kubectl change reverted by ArgoCD
This is expected — `selfHeal: true` reverts any out-of-tree changes automatically.
Always make changes in git, commit, and push. ArgoCD syncs them within ~3 minutes.

### Force a full re-sync
```bash
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

# Reference

| Item | Value |
|---|---|
| App URL | http://13.127.210.35:30080 |
| ArgoCD UI | http://13.127.210.35:30081 |
| ArgoCD username | `admin` |
| Control-plane public IP | 13.127.210.35 |
| Control-plane private IP | 10.0.10.34 |
| Worker-1 private IP | 10.0.132.170 |
| Worker-2 private IP | 10.0.141.21 |
| ECR registry | 388779989543.dkr.ecr.ap-south-1.amazonaws.com |
| App namespace | bmi-app |
| ArgoCD namespace | argocd |
| PostgreSQL data path | /data/postgres on k8s-lab-worker-1 |
| PV reclaim policy | Retain — data not deleted on pod/PVC deletion |
| Image tag strategy | git short SHA — unique per commit, traceable |
| ECR token lifetime | 12 hours — auto-refreshed by CronJob every 6 hours |
| ArgoCD watched path | `k8s-argocd/app/` on `main` branch |
| ArgoCD sync interval | ~3 minutes (automatic after every git push) |
| Sync waves | 1=PostgreSQL, 2=Migrations (Sync hook), 3=Backend, 4=Frontend |
| Secrets in git | Never — `app/postgres/secret.yaml` and `app/backend/secret.yaml` are gitignored |

---

## Author

*Md. Sarowar Alam*
Lead DevOps Engineer, Hogarth Worldwide
Email: sarowar@hotmail.com
LinkedIn: https://www.linkedin.com/in/sarowar/
