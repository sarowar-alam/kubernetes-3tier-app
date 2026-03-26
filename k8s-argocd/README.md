# BMI Health Tracker — GitOps Deployment with ArgoCD

> **Audience:** Engineers onboarding to this project for the first time.  
> **Goal:** Understand the system, bootstrap the environment, deploy, operate, and safely introduce changes — without needing to ask anyone.

---

## Table of Contents

1. [What This Is](#1-what-this-is)
2. [Architecture Overview](#2-architecture-overview)
3. [How Deployments Work](#3-how-deployments-work)
4. [Repository Layout](#4-repository-layout)
5. [Prerequisites](#5-prerequisites)
6. [Cluster & AWS Setup (one-time)](#6-cluster--aws-setup-one-time)
7. [Secrets Setup (one-time, never committed)](#7-secrets-setup-one-time-never-committed)
8. [Bootstrap ArgoCD (one-time)](#8-bootstrap-argocd-one-time)
9. [Day-to-Day: Deploying a Change](#9-day-to-day-deploying-a-change)
10. [Sync Waves — Deployment Ordering](#10-sync-waves--deployment-ordering)
11. [ECR Token Refresh — How It Works](#11-ecr-token-refresh--how-it-works)
12. [Navigating the Manifests](#12-navigating-the-manifests)
13. [Operational Runbook](#13-operational-runbook)
14. [Rollback](#14-rollback)
15. [Safely Introducing Changes](#15-safely-introducing-changes)
16. [Design Decisions](#16-design-decisions)
17. [Troubleshooting](#17-troubleshooting)

---

## 1. What This Is

This directory (`k8s-argocd/`) is a **self-contained GitOps delivery system** for the BMI Health Tracker — a 3-tier application (React frontend, Node.js backend, PostgreSQL database) running on a self-managed Kubernetes cluster on AWS EC2.

**Live app:** http://13.127.88.162:30080  
**GitHub repo:** https://github.com/sarowar-alam/kubernetes-3tier-app

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Developer Machine                                               │
│                                                                  │
│  docker build + push → AWS ECR                                  │
│  git commit + push   → GitHub (main branch)                     │
└────────────────────────────┬─────────────────────────────────────┘
                             │  ArgoCD polls every 3 minutes
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster — AWS EC2 (ap-south-1)                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Namespace: argocd                                        │   │
│  │  ArgoCD Server — watches k8s-argocd/app/ on main branch  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                             │ applies diffs automatically        │
│                             ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Namespace: bmi-app                                       │   │
│  │                                                           │   │
│  │  ┌─────────────┐   ┌──────────────┐   ┌──────────────┐  │   │
│  │  │  Frontend   │   │   Backend    │   │  PostgreSQL  │  │   │
│  │  │  ×2 pods    │──▶│   ×2 pods   │──▶│  StatefulSet │  │   │
│  │  │  Nginx+React│   │  Node.js API │   │  + 5Gi PV   │  │   │
│  │  └────┬────────┘   └──────────────┘   └──────────────┘  │   │
│  │       │ NodePort :30080                                   │   │
│  └───────┼───────────────────────────────────────────────────┘  │
└──────────┼───────────────────────────────────────────────────────┘
           │
           ▼  http://10.0.130.111:30080
        Browser
```

### Cluster nodes

| Hostname | Private IP | Role |
|---|---|---|
| k8s-control-plane | 10.0.5.64 | API server, scheduler, etcd |
| k8s-worker-1 | 10.0.130.111 | All application pods, PostgreSQL storage |

### Traffic flow

```
Browser → :30080 (NodePort)
  └─ bmi-frontend-svc → Nginx (:80)
       └─ /api/* → bmi-backend-svc:3000
            └─ bmi-postgres-svc:5432
```

Only one port (`30080`) is exposed externally. The backend and database are unreachable from outside the cluster.

---

## 3. How Deployments Work

```
local: bash k8s-argocd/build-and-push.sh
  (done — ArgoCD detects the git diff and syncs automatically)
```

**What ArgoCD does continuously:**
- Polls the `k8s-argocd/app/` path on the `main` branch every ~3 minutes
- Compares the live cluster state against the git state
- Applies any diff automatically (`selfHeal: true`)
- Reverts any manual `kubectl` changes that diverge from git (`selfHeal: true`)
- Prunes resources that were removed from git (`prune: true`)

> **Important:** With `selfHeal: true`, any manual `kubectl edit` or `kubectl apply` against `bmi-app` resources will be reverted by ArgoCD on the next sync. Always make changes through git.

---

## 4. Repository Layout

```
k8s-argocd/
│
├── bootstrap.sh              ← One-time setup: installs ArgoCD, applies secrets,
│                               creates the Application. Run ONCE on control-plane.
│
├── build-and-push.sh         ← Day-to-day: build images, push to ECR, patch
│                               manifests, git push. Run on your local machine.
│
├── setup-ecr-secret.sh       ← Manual ECR token refresh (rarely needed).
│
├── argocd/
│   ├── namespace.yaml        ← Creates the 'argocd' namespace
│   └── application.yaml      ← ArgoCD Application resource (the GitOps config)
│
├── app/                      ← Everything ArgoCD manages. This is the source of truth.
│   ├── namespace.yaml
│   ├── postgres/
│   │   ├── pv.yaml                    ← Cluster-scoped, 5Gi hostPath on worker-1
│   │   ├── pvc.yaml
│   │   ├── service.yaml               ← ClusterIP :5432
│   │   ├── secret.yaml                ← GITIGNORED — apply manually
│   │   ├── statefulset.yaml           ← sync-wave: 1
│   │   ├── migrations-configmap.yaml  ← Embeds SQL migration files
│   │   └── migration-job.yaml         ← PreSync hook, sync-wave: 2
│   ├── backend/
│   │   ├── configmap.yaml             ← NODE_ENV, PORT, FRONTEND_URL
│   │   ├── secret.yaml                ← GITIGNORED — apply manually
│   │   ├── deployment.yaml            ← 2 replicas, sync-wave: 3
│   │   └── service.yaml               ← ClusterIP :3000
│   └── frontend/
│       ├── deployment.yaml            ← 2 replicas, sync-wave: 4
│       └── service.yaml               ← NodePort :30080
│
└── infra/
    └── ecr-secret-refresher.yaml  ← CronJob: refreshes ecr-credentials every 6h
```

---

## 5. Prerequisites

### Local machine (your laptop)

| Tool | Minimum version | Install |
|---|---|---|
| Docker Desktop | 24+ | https://docs.docker.com/desktop/ |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Git | 2.x | https://git-scm.com/ |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools/ |

**AWS CLI profile** — the script expects a profile named `sarowar-ostad`:
```bash
aws configure --profile sarowar-ostad
# Enter: AWS Access Key ID, Secret, region=ap-south-1, output=json
```

**kubectl context** — point to the cluster:
```bash
# Copy kubeconfig from control-plane
scp ubuntu@10.0.5.64:~/.kube/config ~/.kube/config-bmi
export KUBECONFIG=~/.kube/config-bmi
kubectl get nodes   # should show both nodes
```

### Control-plane node (10.0.5.64)

| Tool | Install command |
|---|---|
| AWS CLI | `apt install unzip -y && curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip && unzip -q /tmp/a.zip -d /tmp && sudo /tmp/aws/install` |
| kubectl | pre-installed (it's the control-plane) |
| git | `sudo apt-get install -y git` |

---

## 6. Cluster & AWS Setup (one-time)

These steps are done once when the cluster is freshly provisioned. Skip if the cluster already exists.

### 6.1 Attach IAM Role to both EC2 instances

The cluster nodes need permission to pull images from ECR without static credentials.

1. Go to **AWS Console → IAM → Roles → Create role**
2. Trusted entity: **EC2**
3. Attach policy: `AmazonEC2ContainerRegistryReadOnly`
4. Name the role: `k8s-node-ecr-role`
5. Attach to **both** EC2 instances:  
   EC2 → select instance → **Actions → Security → Modify IAM role**

### 6.2 Create PostgreSQL data directory on worker-1

`bootstrap.sh` handles this automatically using a temporary `busybox` pod pinned to `k8s-worker-1`. No SSH or extra IAM permissions needed.

If you need to do it manually:

```bash
kubectl run mkdir-postgres -n bmi-app --restart=Never \
  --image=busybox \
  --overrides='{
    "spec": {
      "nodeSelector": {"kubernetes.io/hostname": "k8s-worker-1"},
      "containers": [{
        "name": "mkdir-postgres",
        "image": "busybox",
        "command": ["sh", "-c", "mkdir -p /host/postgres && chmod 777 /host/postgres && echo DONE"],
        "volumeMounts": [{"name": "host-data", "mountPath": "/host"}],
        "securityContext": {"runAsUser": 0}
      }],
      "volumes": [{"name": "host-data", "hostPath": {"path": "/data"}}]
    }
  }'

kubectl wait pod/mkdir-postgres -n bmi-app --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
kubectl logs mkdir-postgres -n bmi-app   # should print: DONE
kubectl delete pod mkdir-postgres -n bmi-app
```

### 6.3 Create ECR repositories (if not already created)

```bash
export AWS_PROFILE=sarowar-ostad
aws ecr create-repository --repository-name bmi-backend  --region ap-south-1
aws ecr create-repository --repository-name bmi-frontend --region ap-south-1
```

---

## 7. Secrets Setup (one-time, never committed)

Two secret files are **gitignored** and must be created locally and applied to the cluster manually before the first bootstrap.

### 7.0 Create the namespace first

Secrets are namespaced resources — the `bmi-app` namespace must exist before applying them:

```bash
kubectl apply -f k8s-argocd/app/namespace.yaml
```

### 7.1 PostgreSQL secret

File: `k8s-argocd/app/postgres/secret.yaml`

> ⚠️ This file already exists in the repo with default dev credentials. **Change the password before using on any shared or production cluster.**

Apply it:
```bash
kubectl apply -f k8s-argocd/app/postgres/secret.yaml
```

### 7.2 Backend secret

File: `k8s-argocd/app/backend/secret.yaml`

The `DATABASE_URL` password **must match** `POSTGRES_PASSWORD` in the postgres secret above.

Apply it:
```bash
kubectl apply -f k8s-argocd/app/backend/secret.yaml
```

> These secrets are applied once. ArgoCD does not manage them (they are gitignored). They persist across all future syncs.

---

## 8. Bootstrap ArgoCD (one-time)

Run **once**, from the control-plane node, after completing sections 6 and 7:

```bash
# On your local machine
git clone https://github.com/sarowar-alam/kubernetes-3tier-app
cd kubernetes-3tier-app

# Copy the repo to the control-plane
scp -r k8s-argocd ubuntu@10.0.5.64:~/kubernetes-3tier-app/

# SSH to control-plane and run bootstrap
ssh ubuntu@10.0.5.64
cd kubernetes-3tier-app
bash k8s-argocd/bootstrap.sh
```

### What `bootstrap.sh` does, step by step

| Step | Action |
|---|---|
| 0 | Installs AWS CLI if not already present (required for ECR token refresh) |
| 1 | Creates `argocd` and `bmi-app` namespaces |
| 2 | Applies the gitignored secrets (`postgres-secret` + `backend-secret`) |
| 3 | Creates the PostgreSQL PersistentVolume (cluster-scoped) |
| 4 | Creates `/data/postgres` on worker-1 via a temporary `busybox` pod (no SSH needed) |
| 4.5 | Creates the `ecr-credentials` pull secret so pods can pull images from ECR |
| 5 | Installs ArgoCD from the official stable manifest |
| 6 | Exposes the ArgoCD UI as a NodePort service |
| 7 | Creates the ArgoCD Application — this triggers the **first automated sync** |
| 8 | Prints a live verification summary (namespaces, secrets, PV, ArgoCD app status) |

At the end, the script prints:

```
ArgoCD UI : http://10.0.130.111:<port>
Username  : admin
Password  : <auto-generated>
```

> Change the admin password after first login:  
> ArgoCD UI → User Info → Update Password

### What happens during the first sync

ArgoCD reads `k8s-argocd/app/` from the `main` branch and applies everything in sync-wave order:

```
Wave 1 → PostgreSQL StatefulSet starts
Wave 2 → Migration Job runs (PreSync hook — waits for Postgres ready)
Wave 3 → Backend Deployment starts (2 replicas)
Wave 4 → Frontend Deployment starts (2 replicas)
```

The app is live at `http://10.0.130.111:30080` once all waves complete (typically 3–5 minutes).

---

## 9. Day-to-Day: Deploying a Change

Once ArgoCD is bootstrapped, **all future deploys are a single command on your local machine:**

```bash
bash k8s-argocd/build-and-push.sh
```

### What this script does

1. Logs in to ECR using your `sarowar-ostad` AWS profile
2. Builds `bmi-backend` and `bmi-frontend` Docker images
3. Tags them with the current **git short SHA** (e.g., `c8f3a21`) and `latest`
4. Pushes all tags to ECR
5. Patches the `image:` field in `k8s-argocd/app/backend/deployment.yaml` and `k8s-argocd/app/frontend/deployment.yaml` with the new SHA tag
6. Commits and pushes the updated manifests to `main`

ArgoCD detects the commit within ~3 minutes and rolls out a new deployment automatically.

### Verifying the rollout

```bash
# Watch pods update
kubectl get pods -n bmi-app -w

# Check rollout status
kubectl rollout status deployment/bmi-backend  -n bmi-app
kubectl rollout status deployment/bmi-frontend -n bmi-app

# Check ArgoCD sync status
kubectl get application bmi-health-tracker -n argocd
```

Or open the ArgoCD UI and watch the sync in real time.

---

## 10. Sync Waves — Deployment Ordering

ArgoCD applies all resources in a namespace simultaneously by default. Sync waves enforce ordering.

| Wave | Resource | Why it must come first |
|---|---|---|
| `0` (default) | PV, PVC, Services, ConfigMaps | No dependencies |
| `1` | PostgreSQL StatefulSet | Database must be up before migrations run |
| `2` | Migration Job (PreSync hook) | Must complete before app starts; `BeforeHookCreation` deletes the previous job so it re-runs on every sync |
| `3` | Backend Deployment | Needs the database and migrations to exist |
| `4` | Frontend Deployment | Needs the backend service DNS to exist |

The `PreSync` hook on the migration job means it runs **before** any wave-3/4 resources are touched — guaranteeing schema is always up to date before the app handles traffic.

---

## 11. ECR Token Refresh — How It Works

AWS ECR authentication tokens expire after **12 hours**. The `ecr-credentials` Kubernetes Secret (used as `imagePullSecrets` on every pod) must be kept fresh.

| Mechanism | When used |
|---|---|
| `setup-ecr-secret.sh` | Run manually during bootstrap or emergency refresh |
| `infra/ecr-secret-refresher.yaml` | CronJob running in-cluster every 6 hours — handles all ongoing refreshes automatically |

The CronJob uses the EC2 node's IAM instance profile to authenticate — no static AWS credentials are stored anywhere in the cluster.

**To apply the CronJob** (first time, from the control-plane):
```bash
kubectl apply -f k8s-argocd/infra/ecr-secret-refresher.yaml
```

> If pod pulls suddenly fail with `ImagePullBackOff`, manually refresh:
> ```bash
> bash k8s-argocd/setup-ecr-secret.sh
> ```

---

## 12. Navigating the Manifests

### Finding a resource

| I want to change... | File |
|---|---|
| Backend environment variables (non-secret) | `app/backend/configmap.yaml` |
| Backend database URL | `app/backend/secret.yaml` (apply manually) |
| Number of backend/frontend replicas | `app/backend/deployment.yaml` or `app/frontend/deployment.yaml` |
| Backend CPU/memory limits | `app/backend/deployment.yaml` → `resources:` |
| PostgreSQL storage size | `app/postgres/pv.yaml` + `app/postgres/pvc.yaml` |
| A SQL migration | `app/postgres/migrations-configmap.yaml` |
| ArgoCD sync policy (polling interval, auto-sync) | `argocd/application.yaml` |
| ECR secret refresh schedule | `infra/ecr-secret-refresher.yaml` → `schedule:` |

### Key annotations to know

```yaml
argocd.argoproj.io/sync-wave: "N"         # Controls apply ordering (lower = earlier)
argocd.argoproj.io/hook: PreSync           # Runs before the main sync begins
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation  # Re-runs job on every sync
```

---

## 13. Operational Runbook

### Check overall health

```bash
# All pods in bmi-app
kubectl get pods -n bmi-app

# ArgoCD application sync status
kubectl get application bmi-health-tracker -n argocd -o wide

# Recent events (useful for crash diagnosis)
kubectl get events -n bmi-app --sort-by='.lastTimestamp' | tail -20
```

### View logs

```bash
# Backend logs (all replicas)
kubectl logs -l app=bmi-backend -n bmi-app --tail=100

# Frontend logs
kubectl logs -l app=bmi-frontend -n bmi-app --tail=100

# PostgreSQL logs
kubectl logs -l app=postgres -n bmi-app --tail=100

# Last migration job logs
kubectl logs job/bmi-migrations -n bmi-app
```

### Scale manually (temporary — ArgoCD will revert on next sync)

```bash
# To scale permanently, edit the replicas: field in the deployment YAML and git push
kubectl scale deployment bmi-backend  --replicas=3 -n bmi-app
kubectl scale deployment bmi-frontend --replicas=3 -n bmi-app
```

### Restart pods without a code change

```bash
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app
```

### Connect to PostgreSQL directly

```bash
kubectl exec -it postgres-0 -n bmi-app -- \
  psql -U bmi_user -d bmidb
```

### Force an immediate ArgoCD sync

```bash
# From CLI (requires argocd CLI tool)
argocd app sync bmi-health-tracker

# Or from the ArgoCD UI: click the app → "Sync" → "Synchronize"
```

---

## 14. Rollback

### Option A — Rollback via Kubernetes (immediate, no git change)

```bash
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app
```

> ⚠️ ArgoCD `selfHeal` will **revert this** on the next sync (~3 minutes). Use this only for a quick emergency fix while you prepare a proper git revert.

### Option B — Rollback via git (permanent, recommended)

```bash
# Find the commit to revert to
git log --oneline k8s-argocd/app/

# Revert the deploy commit
git revert <commit-sha>
git push

# ArgoCD picks up the revert commit and rolls back the deployment automatically
```

### Option C — Pin to a specific image tag manually

Edit `app/backend/deployment.yaml` and `app/frontend/deployment.yaml`, replace the image tag with an older SHA, commit, and push. ArgoCD applies it.

---

## 15. Safely Introducing Changes

### Application code changes (backend or frontend)

1. Make your code changes in `backend/` or `frontend/`
2. Test locally: `docker build` and run the container
3. Commit your code changes
4. Run `bash k8s-argocd/build-and-push.sh` — this builds, pushes, patches manifests, and pushes to git
5. ArgoCD rolls out the new pods using a rolling update (zero downtime)
6. Verify with `kubectl rollout status` and check the app at `:30080`

### Kubernetes manifest changes

1. Edit the YAML file in `k8s-argocd/app/`
2. Validate the YAML:
   ```bash
   kubectl apply --dry-run=client -f k8s-argocd/app/<file>.yaml
   ```
3. Commit and push to `main`
4. ArgoCD applies the change automatically

### Database schema changes (new migration)

1. Add a new SQL file to `app/postgres/migrations-configmap.yaml` under `data:` (e.g., `003_add_column.sql`)
2. Make the SQL **idempotent** — use `IF NOT EXISTS`, `DO $$ IF NOT EXISTS ... END $$`
3. Add the new file to the `run-migrations` container command in `app/postgres/migration-job.yaml`
4. Commit and push
5. ArgoCD runs the migration job as a PreSync hook before touching any app resources

### ArgoCD configuration changes

1. Edit `argocd/application.yaml`
2. Apply it directly (ArgoCD manages itself once bootstrapped):
   ```bash
   kubectl apply -f k8s-argocd/argocd/application.yaml
   ```

### Things you must **never** do

| Action | Why |
|---|---|
| `kubectl edit` resources in `bmi-app` | ArgoCD will revert it on the next sync |
| Push image tags with `latest`-only in deployment YAMLs | No diff = ArgoCD won't detect a new deploy |
| Commit `app/postgres/secret.yaml` or `app/backend/secret.yaml` | Credentials in git history are a permanent security risk |
| Delete the `argocd` namespace | Removes ArgoCD — all automated syncs stop |

---

## 16. Design Decisions

### Why git SHA image tags (not `latest`)?

ArgoCD compares the desired state (git) to the live state (cluster). If the image tag never changes, ArgoCD never sees a diff and never redeploys — even if the image content changed. SHA tags guarantee a new tag on every commit, making every deploy explicit and traceable.

### Why `PreSync` hook for migrations?

Running migrations as a `PreSync` Job ensures the database schema is always updated before any application pods start. If a migration fails, the sync stops and no new pods are started — preventing the app from running against a mismatched schema.

### Why `BeforeHookCreation` on the migration job?

Kubernetes Jobs are immutable once created. Without this policy, re-syncing would find the completed job still present and fail. `BeforeHookCreation` deletes the previous job before re-creating it, making migrations idempotent across syncs.

### Why `selfHeal: true`?

This enforces that git is always the single source of truth. Any configuration drift from manual changes is automatically corrected within the sync interval. This prevents "it works on my cluster" problems.

### Why a CronJob for ECR token refresh?

The original `deploy.sh` refreshed the ECR token on every deploy. With ArgoCD, there is no deploy script running on the cluster anymore. An in-cluster CronJob running every 6 hours ensures the `ecr-credentials` secret is always valid before a pod pull is attempted, without requiring any human action.

---

## 17. Troubleshooting

### Pods stuck in `ImagePullBackOff`

The ECR token has expired.

```bash
bash k8s-argocd/setup-ecr-secret.sh
# Pods will retry automatically within ~30 seconds
```

### ArgoCD shows `OutOfSync` but won't auto-sync

Check for sync errors:
```bash
kubectl describe application bmi-health-tracker -n argocd | grep -A 20 "Conditions"
```

Common causes:
- A resource has a validation error (check `kubectl get events -n bmi-app`)
- The migration job previously failed (`kubectl logs job/bmi-migrations -n bmi-app`)
- A secret referenced by a pod doesn't exist yet (apply secrets manually)

### Migration job keeps failing

```bash
kubectl logs job/bmi-migrations -n bmi-app
```

Common causes:
- PostgreSQL not ready yet — the init container should handle this, but if the pod is crash-looping, check `kubectl logs -l app=postgres -n bmi-app`
- SQL syntax error in a new migration — fix the SQL, commit, and push

### Backend pods in `CrashLoopBackOff`

```bash
kubectl logs -l app=bmi-backend -n bmi-app --previous
```

Common causes:
- `backend-secret` missing or has wrong `DATABASE_URL` — reapply the secret
- PostgreSQL not accepting connections — check `kubectl exec -it postgres-0 -n bmi-app -- pg_isready -U bmi_user -d bmidb`

### ArgoCD Application was deleted accidentally

```bash
# Re-apply the Application resource
kubectl apply -f k8s-argocd/argocd/application.yaml
# ArgoCD will re-sync and restore all managed resources
```

### How to completely tear down and start over

```bash
# Delete the ArgoCD Application (cascade deletes all bmi-app resources)
kubectl delete application bmi-health-tracker -n argocd

# Uninstall ArgoCD
kubectl delete namespace argocd

# Keep postgres data intact (PV has Retain policy)
# To also wipe data:
# ssh ubuntu@10.0.130.111 "sudo rm -rf /data/postgres/*"
```

---

## Quick Reference Card

```bash
# First time bootstrap (control-plane, once only)
bash k8s-argocd/bootstrap.sh

# Deploy a change (local machine, every time)
bash k8s-argocd/build-and-push.sh

# Check pod health
kubectl get pods -n bmi-app

# View backend logs
kubectl logs -l app=bmi-backend -n bmi-app --tail=100

# Connect to DB
kubectl exec -it postgres-0 -n bmi-app -- psql -U bmi_user -d bmidb

# Emergency ECR token refresh
bash k8s-argocd/setup-ecr-secret.sh

# Rollback immediately (ArgoCD will revert in ~3 min unless you git-revert too)
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app

# Permanent rollback
git revert <deploy-commit-sha> && git push
```
