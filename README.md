# BMI & Health Tracker

A production-ready 3-tier web application for tracking body measurements and computing health metrics. Built with React, Node.js/Express, and PostgreSQL, deployed on a self-managed Kubernetes cluster on AWS EC2.

**Live app:** http://13.127.88.162:30080  
**Repository:** https://github.com/sarowar-alam/kubernetes-3tier-app

---

## Table of Contents

1. [What This App Does](#what-this-app-does)
2. [Architecture](#architecture)
3. [Repository Structure](#repository-structure)
4. [Technology Stack](#technology-stack)
5. [Prerequisites](#prerequisites)
6. [Local Development](#local-development)
7. [Environment Variables](#environment-variables)
8. [Database](#database)
9. [API Reference](#api-reference)
10. [Docker Images](#docker-images)
11. [Kubernetes Infrastructure](#kubernetes-infrastructure)
12. [First-Time Cluster Setup](#first-time-cluster-setup)
13. [Deploy](#deploy)
14. [Update the Application](#update-the-application)
15. [Rollback](#rollback)
16. [Operational Runbook](#operational-runbook)
17. [Security](#security)
18. [Design Decisions](#design-decisions)

---

## What This App Does

Users enter weight, height, age, biological sex, and activity level. The app calculates and stores:

| Metric | Formula |
|---|---|
| **BMI** | `weight_kg / height_m²` |
| **BMR** | Harris-Benedict: `10×kg + 6.25×cm − 5×age + 5` (male) / `−161` (female) |
| **Daily Calories** | `BMR × activity multiplier` (1.2 → 1.9) |
| **BMI Category** | Underweight / Normal / Overweight / Obese |

Data is persisted in PostgreSQL. A 30-day BMI trend chart is rendered with Chart.js.

---

## Architecture

```
Internet
    │
    ▼  NodePort :30080
┌───────────────────────────────┐
│  Frontend Pod × 2             │  Nginx — serves React SPA
│  nginx:1.25-alpine            │  proxies /api → bmi-backend-svc
└──────────────┬────────────────┘
               │  ClusterIP bmi-backend-svc:3000
               ▼
┌───────────────────────────────┐
│  Backend Pod × 2              │  Node.js / Express REST API
│  node:18-alpine (non-root)    │  calculates metrics, reads/writes DB
└──────────────┬────────────────┘
               │  ClusterIP bmi-postgres-svc:5432
               ▼
┌───────────────────────────────┐
│  PostgreSQL StatefulSet × 1   │  postgres:14
│  Namespace: bmi-app           │  data → hostPath /data/postgres
└───────────────────────────────┘
```

**Why this topology?**  
The browser never communicates directly with the backend. Nginx receives all traffic on port 80 and reverse-proxies `/api/*` requests to the backend Kubernetes DNS name (`bmi-backend-svc`). This means:
- Only one port is exposed externally (30080)
- CORS is a non-issue — browser and API share the same origin
- The backend is fully internal and unreachable from outside the cluster

**Cluster nodes:**

| Hostname | IP | Role |
|---|---|---|
| k8s-control-plane | 10.0.5.64 | API server, scheduler, etcd |
| k8s-worker-1 | 10.0.130.111 | Runs all application pods, PostgreSQL storage |

---

## Repository Structure

```
.
├── backend/                        # Node.js Express API
│   ├── Dockerfile                  # Multi-stage, non-root, node:18-alpine
│   ├── ecosystem.config.js         # PM2 config (for non-K8s deployments)
│   ├── package.json
│   ├── migrations/
│   │   ├── 001_create_measurements.sql
│   │   └── 002_add_measurement_date.sql
│   └── src/
│       ├── server.js               # Express app, CORS, health check
│       ├── routes.js               # API route handlers
│       ├── db.js                   # PostgreSQL connection pool
│       └── calculations.js         # BMI, BMR, calorie formulas
│
├── frontend/                       # React SPA
│   ├── Dockerfile                  # Multi-stage: Vite build → nginx:1.25-alpine
│   ├── nginx.conf                  # SPA fallback + /api proxy to bmi-backend-svc
│   ├── package.json
│   ├── vite.config.js              # Dev server proxy (/api → localhost:3000)
│   ├── index.html
│   └── src/
│       ├── main.jsx
│       ├── App.jsx                 # Root component, data fetching
│       ├── api.js                  # Axios instance (baseURL: /api, timeout: 10s)
│       ├── index.css               # Design tokens, layout, component styles
│       └── components/
│           ├── MeasurementForm.jsx # Data-entry form with validation
│           └── TrendChart.jsx      # 30-day BMI line chart (Chart.js)
│
├── database/
│   └── setup-database.sh           # Bare-metal PostgreSQL bootstrap script
│
└── k8s/                            # All Kubernetes & deployment automation
    ├── README.md                   # This file
    ├── DEPLOYMENT.md               # Concise step-by-step deployment reference
    ├── namespace.yaml
    ├── build-and-push.sh           # LOCAL: build → ECR → commit
    ├── deploy.sh                   # CLUSTER: full ordered deployment
    ├── setup-ecr-secret.sh         # CLUSTER: create/refresh ECR pull secret
    ├── setup-ecr-on-nodes.sh       # CLUSTER: install kubelet credential provider
    ├── postgres/
    │   ├── secret.yaml             # ⚠ GITIGNORED — apply manually
    │   ├── pv.yaml                 # hostPath PV on worker-1
    │   ├── pvc.yaml
    │   ├── statefulset.yaml        # postgres:14, pinned to worker-1
    │   ├── service.yaml            # ClusterIP: bmi-postgres-svc:5432
    │   ├── migrations-configmap.yaml
    │   └── migration-job.yaml      # One-shot K8s Job
    ├── backend/
    │   ├── secret.yaml             # ⚠ GITIGNORED — apply manually
    │   ├── configmap.yaml          # NODE_ENV, PORT, FRONTEND_URL
    │   ├── deployment.yaml         # 2 replicas, liveness + readiness probes
    │   └── service.yaml            # ClusterIP: bmi-backend-svc:3000
    └── frontend/
        ├── deployment.yaml         # 2 replicas, liveness + readiness probes
        └── service.yaml            # NodePort :30080
```

---

## Technology Stack

| Layer | Technology | Version | Purpose |
|---|---|---|---|
| Frontend | React | 18.2.0 | UI framework |
| Frontend | Vite | 5.0.0 | Build tool & dev server |
| Frontend | Axios | 1.4.0 | HTTP client |
| Frontend | Chart.js + react-chartjs-2 | 4.4.0 / 5.2.0 | BMI trend chart |
| Frontend runtime | Nginx | 1.25-alpine | Static file serving + API proxy |
| Backend | Node.js | 18 (LTS) | Runtime |
| Backend | Express | 4.18.2 | Web framework |
| Backend | pg | 8.10.0 | PostgreSQL client |
| Backend | dotenv | 16.0.0 | Environment config |
| Database | PostgreSQL | 14 | Relational data store |
| Container runtime | Docker (containerd) | 18-alpine base | Image builds |
| Orchestration | Kubernetes (kubeadm) | — | Cluster management |
| CNI | Calico | — | Pod networking |
| Registry | AWS ECR | ap-south-1 | Image storage |
| Cloud | AWS EC2 | Ubuntu | Infrastructure |

---

## Prerequisites

### Local machine (development + deployments)

| Tool | Minimum version | Install |
|---|---|---|
| Docker Desktop | 24+ | https://docs.docker.com/desktop/ |
| Node.js | 18 LTS | https://nodejs.org |
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| git | 2.x | https://git-scm.com |
| bash | 4+ | Git Bash (Windows) / terminal (Mac/Linux) |

**AWS CLI profile:**  
The scripts use the named profile `sarowar-ostad`. Configure it once:
```bash
aws configure --profile sarowar-ostad
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region:        ap-south-1
# Default output format: json
```

### Cluster nodes (Ubuntu EC2)

| Tool | Purpose | Auto-installed by |
|---|---|---|
| kubeadm / kubectl / kubelet | Kubernetes | pre-existing cluster |
| containerd | Container runtime | pre-existing cluster |
| AWS CLI v2 | ECR token generation | `setup-ecr-on-nodes.sh` |
| curl, unzip | Download utilities | `setup-ecr-on-nodes.sh` |

---

## Local Development

### 1. Clone the repository
```bash
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app
```

### 2. Start PostgreSQL locally
```bash
# Quickest option — Docker
docker run -d \
  --name bmi-postgres \
  -e POSTGRES_DB=bmidb \
  -e POSTGRES_USER=bmi_user \
  -e POSTGRES_PASSWORD=localdev \
  -p 5432:5432 \
  postgres:14

# Run migrations
PGPASSWORD=localdev psql -h localhost -U bmi_user -d bmidb \
  -f backend/migrations/001_create_measurements.sql \
  -f backend/migrations/002_add_measurement_date.sql
```

### 3. Start the backend
```bash
cd backend
cp .env.example .env          # create if it doesn't exist, or set manually:
# DATABASE_URL=postgres://bmi_user:localdev@localhost:5432/bmidb
# PORT=3000
# NODE_ENV=development

npm install
npm run dev
# Server running on http://localhost:3000
# ✅ Database connected successfully
```

### 4. Start the frontend
```bash
cd frontend
npm install
npm run dev
# Vite dev server at http://localhost:5173
# /api/* requests proxied to http://localhost:3000
```

The Vite dev server's proxy (`vite.config.js`) mirrors the nginx proxy in production — the React app always uses the relative `/api` base URL and never hard-codes a backend address.

---

## Environment Variables

### Backend

| Variable | Where set | Example | Required |
|---|---|---|---|
| `DATABASE_URL` | K8s secret / `.env` | `postgres://bmi_user:pass@bmi-postgres-svc:5432/bmidb` | ✅ |
| `PORT` | K8s configmap / `.env` | `3000` | No (default: 3000) |
| `NODE_ENV` | K8s configmap / `.env` | `production` | No (default: development) |
| `FRONTEND_URL` | K8s configmap / `.env` | `http://10.0.130.111:30080` | No (used for CORS in production) |

**CORS behaviour:**
- `NODE_ENV=development` → allows `localhost:5173` and `localhost:3000`
- `NODE_ENV=production` → allows only `FRONTEND_URL` (or `http://localhost` if unset)

Since Nginx proxies `/api` to the backend, the browser never sends cross-origin requests in production — CORS is effectively a non-issue.

### Frontend

The frontend has no runtime environment variables. The Vite build is entirely static. API calls use the relative path `/api` which nginx resolves at runtime.

---

## Database

### Schema

```sql
CREATE TABLE measurements (
  id               SERIAL PRIMARY KEY,
  weight_kg        NUMERIC(5,2) NOT NULL CHECK (weight_kg > 0 AND weight_kg < 1000),
  height_cm        NUMERIC(5,2) NOT NULL CHECK (height_cm > 0 AND height_cm < 300),
  age              INTEGER      NOT NULL CHECK (age > 0 AND age < 150),
  sex              VARCHAR(10)  NOT NULL CHECK (sex IN ('male', 'female')),
  activity_level   VARCHAR(30)       CHECK (activity_level IN
                     ('sedentary', 'light', 'moderate', 'active', 'very_active')),
  bmi              NUMERIC(4,1) NOT NULL,
  bmi_category     VARCHAR(30),
  bmr              INTEGER,
  daily_calories   INTEGER,
  measurement_date DATE         NOT NULL DEFAULT CURRENT_DATE,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_measurements_measurement_date ON measurements(measurement_date DESC);
CREATE INDEX idx_measurements_created_at       ON measurements(created_at DESC);
CREATE INDEX idx_measurements_bmi              ON measurements(bmi);
```

### Migrations

Migrations live in `backend/migrations/` and are loaded into the cluster as a Kubernetes ConfigMap (`k8s/postgres/migrations-configmap.yaml`). A one-shot Kubernetes **Job** applies them after every deployment. Both migrations are idempotent (`IF NOT EXISTS`/`DO $$ BEGIN ... END $$`) — safe to re-run.

| File | Description |
|---|---|
| `001_create_measurements.sql` | Creates the `measurements` table with all constraints and indexes |
| `002_add_measurement_date.sql` | Adds `measurement_date` column if missing; backfills from `created_at` |

**Adding a new migration:**  
1. Create `backend/migrations/003_your_change.sql` (idempotent)
2. Add its content to `k8s/postgres/migrations-configmap.yaml`
3. Add the `psql -f /migrations/003_...` line to `k8s/postgres/migration-job.yaml`
4. Deploy — the Job runs automatically

---

## API Reference

**Base URL:** `/api`  
**Content-Type:** `application/json`

### `POST /api/measurements`

Record a new health measurement.

**Request body:**
```json
{
  "weightKg": 75.5,
  "heightCm": 178,
  "age": 30,
  "sex": "male",
  "activity": "moderate",
  "measurementDate": "2026-03-14"
}
```

| Field | Type | Constraints |
|---|---|---|
| `weightKg` | number | required, > 0 |
| `heightCm` | number | required, > 0 |
| `age` | number | required, > 0 |
| `sex` | string | `"male"` or `"female"` |
| `activity` | string | `sedentary` / `light` / `moderate` / `active` / `very_active` |
| `measurementDate` | string (ISO date) | optional, defaults to today; no future dates |

**Response `201`:**
```json
{
  "measurement": {
    "id": 42,
    "weight_kg": "75.50",
    "height_cm": "178.00",
    "age": 30,
    "sex": "male",
    "activity_level": "moderate",
    "bmi": 23.8,
    "bmi_category": "Normal",
    "bmr": 1806,
    "daily_calories": 2800,
    "measurement_date": "2026-03-14",
    "created_at": "2026-03-14T06:00:00.000Z"
  }
}
```

**Errors:** `400` (validation), `500` (server/DB error)

---

### `GET /api/measurements`

Fetch all measurements, sorted newest first.

**Response `200`:**
```json
{
  "rows": [ { "id": 42, "weight_kg": "75.50", ... }, ... ]
}
```

---

### `GET /api/measurements/trends`

Fetch 30-day daily average BMI for the trend chart.

**Response `200`:**
```json
{
  "rows": [
    { "day": "2026-02-12", "avg_bmi": "22.4" },
    { "day": "2026-02-15", "avg_bmi": "23.1" }
  ]
}
```

---

### `GET /health`

Liveness / readiness check (used by Kubernetes probes).

**Response `200`:**
```json
{ "status": "ok", "environment": "production" }
```

---

## Docker Images

Both images use **multi-stage builds** to keep production images minimal.

### Backend image

| Stage | Base | What it does |
|---|---|---|
| builder | `node:18-alpine` | `npm install --only=production`, copies `src/` |
| runtime | `node:18-alpine` | Runs as non-root `appuser`, exposes 3000 |

```
HEALTHCHECK: GET http://localhost:3000/health
  --interval=30s --timeout=5s --start-period=15s --retries=3
```

### Frontend image

| Stage | Base | What it does |
|---|---|---|
| builder | `node:18-alpine` | `npm install`, `vite build` → `dist/` |
| runtime | `nginx:1.25-alpine` | Serves `dist/`, applies `nginx.conf` |

```
HEALTHCHECK: GET http://localhost/index.html
  --interval=30s --timeout=5s --start-period=10s --retries=3
```

**Image tags:**  
Every build produces two tags — a git short SHA (immutable, traceable) and `latest`:
```
388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:c8c6291
388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:latest
```
The deployment YAMLs are always updated to reference the SHA tag so rollbacks target a specific commit.

---

## Kubernetes Infrastructure

### Namespace

All application resources live in the `bmi-app` namespace.

### Resource summary

| Resource | Kind | Replicas | CPU req/limit | Mem req/limit |
|---|---|---|---|---|
| bmi-frontend | Deployment | 2 | 50m / 200m | 64Mi / 128Mi |
| bmi-backend | Deployment | 2 | 100m / 300m | 128Mi / 256Mi |
| postgres | StatefulSet | 1 | 250m / 500m | 256Mi / 512Mi |

### Persistent storage

PostgreSQL data is stored at `/data/postgres` on `k8s-worker-1` using a `hostPath` PersistentVolume pinned via `nodeAffinity`. The PV reclaim policy is `Retain` — data survives pod deletion.

> **Limitation:** hostPath ties the PostgreSQL pod to worker-1 permanently. This is acceptable for a single-worker-node setup. To move to multi-node in future, replace with an AWS EBS CSI driver-backed StorageClass.

### Health probes

Both backend and frontend deployments use separate liveness and readiness probes:

- **Readiness** — removes the pod from the Service's endpoint list until it's ready to serve traffic
- **Liveness** — restarts the pod if it becomes unhealthy

The backend probes hit `GET /health` which verifies the Express server is responding. The frontend probes hit `GET /` which verifies nginx is serving the SPA.

### ECR authentication

Pods pull images from AWS ECR using a Kubernetes `docker-registry` secret named `ecr-credentials`. This secret is created (and refreshed) automatically by `setup-ecr-secret.sh`, which is called at the start of every `deploy.sh` run.

The ECR token is valid for **12 hours**. It is **never committed to git**.

---

## First-Time Cluster Setup

Perform these steps once on a fresh cluster. After this, use the [Deploy](#deploy) section for all subsequent deployments.

### Step 1 — Create and attach an IAM role to both EC2 instances

**Create the role** (AWS Console → IAM → Roles → Create role):

| Field | Value |
|---|---|
| Trusted entity | AWS service → EC2 |
| Policy | `AmazonEC2ContainerRegistryReadOnly` |
| Role name | `k8s-node-ecr-role` |

**Attach to both instances** (EC2 → select instance → Actions → Security → Modify IAM role):
- `k8s-control-plane` (10.0.5.64)
- `k8s-worker-1` (10.0.130.111)

> The control-plane needs the role to run `aws ecr get-login-password`.  
> Worker nodes need it so containerd can pull ECR images at pod scheduling time.

---

### Step 2 — Prepare storage on worker-1

```bash
ssh ubuntu@10.0.130.111
sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres
exit
```

---

### Step 3 — Install AWS CLI on the control-plane

```bash
ssh ubuntu@10.0.5.64
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
unzip -q /tmp/a.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/a.zip /tmp/aws
aws --version   # aws-cli/2.x.x
# Verify instance profile works:
aws sts get-caller-identity
```

---

### Step 4 — Create ECR repositories (once)

```bash
# Run on your local machine
aws ecr create-repository --repository-name bmi-backend  --region ap-south-1 --profile sarowar-ostad
aws ecr create-repository --repository-name bmi-frontend --region ap-south-1 --profile sarowar-ostad
```

---

### Step 5 — Build and push images from your local machine

```bash
bash k8s/build-and-push.sh
```

This will:
1. Authenticate with ECR using the `sarowar-ostad` profile
2. Build `bmi-backend` and `bmi-frontend` Docker images
3. Tag each with the current git short SHA + `latest`
4. Push all tags to ECR
5. Update `k8s/backend/deployment.yaml` and `k8s/frontend/deployment.yaml` with the new SHA image URIs
6. Commit and push the updated manifests to git

---

### Step 6 — Clone the repo on the control-plane and apply secrets

Secrets contain passwords and are **never committed to git**. Apply them manually:

```bash
ssh ubuntu@10.0.5.64
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app

# Create the namespace first
kubectl apply -f k8s/namespace.yaml

# Edit and apply the postgres secret
vi k8s/postgres/secret.yaml
# Set POSTGRES_PASSWORD to your chosen password

kubectl apply -f k8s/postgres/secret.yaml

# Edit and apply the backend secret
vi k8s/backend/secret.yaml
# Set DATABASE_URL — the password must match POSTGRES_PASSWORD above
# Format: postgres://bmi_user:<password>@bmi-postgres-svc:5432/bmidb

kubectl apply -f k8s/backend/secret.yaml
```

**Secret file format reference:**

```yaml
# k8s/postgres/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: bmi-app
type: Opaque
stringData:
  POSTGRES_DB:       "bmidb"
  POSTGRES_USER:     "bmi_user"
  POSTGRES_PASSWORD: "your-strong-password-here"
```

```yaml
# k8s/backend/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: backend-secret
  namespace: bmi-app
type: Opaque
stringData:
  DATABASE_URL: "postgres://bmi_user:your-strong-password-here@bmi-postgres-svc:5432/bmidb"
```

---

### Step 7 — Run the deployment

```bash
bash k8s/deploy.sh
```

Expected output:
```
[0/6] Refreshing ECR pull secret... ✅
[1/6] Creating namespace...         ✅
[2/6] Deploying PostgreSQL...       ✅ (pod ready)
[3/6] Running database migrations... ✅ (job complete)
[4/6] Deploying backend...          ✅ (rollout complete)
[5/6] Deploying frontend...         ✅ (rollout complete)
[6/6] Deployment complete!

✅ App is live at: http://10.0.130.111:30080
```

---

## Deploy

After first-time setup, use this sequence for all subsequent full deployments (e.g. after tearing down and rebuilding the cluster):

```bash
# On control-plane
ssh ubuntu@10.0.5.64
cd kubernetes-3tier-app && git pull

# Re-apply secrets if the cluster was wiped
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/postgres/secret.yaml
kubectl apply -f k8s/backend/secret.yaml

bash k8s/deploy.sh
```

---

## Update the Application

Use this workflow every time you change the application code.

### 1. Make and commit your changes locally

```bash
git add .
git commit -m "feat: describe your change"
```

### 2. Build, push, and update manifests

```bash
bash k8s/build-and-push.sh
```

The script automatically:
- Builds new images tagged with the new git SHA
- Pushes to ECR
- Updates the image references in both deployment YAMLs
- Commits and pushes the manifest changes to git

### 3. Roll out on the cluster

```bash
ssh ubuntu@10.0.5.64
cd kubernetes-3tier-app && git pull

kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app
```

Kubernetes performs a rolling restart — new pods are started before old ones are terminated, ensuring zero downtime.

### 4. Verify

```bash
kubectl rollout status deployment/bmi-backend  -n bmi-app
kubectl rollout status deployment/bmi-frontend -n bmi-app
kubectl get pods -n bmi-app
```

---

## Rollback

To instantly revert to the previous deployment:

```bash
kubectl rollout undo deployment/bmi-backend  -n bmi-app
kubectl rollout undo deployment/bmi-frontend -n bmi-app
```

To roll back to a specific revision:

```bash
# List revision history
kubectl rollout history deployment/bmi-backend -n bmi-app

# Roll back to revision 3
kubectl rollout undo deployment/bmi-backend -n bmi-app --to-revision=3
```

Because images are tagged with git SHAs, you can identify exactly which commit is running:

```bash
kubectl get deployment bmi-backend -n bmi-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:c8c6291
```

---

## Operational Runbook

### Check pod status
```bash
kubectl get pods -n bmi-app
kubectl get all -n bmi-app
```

### View logs
```bash
kubectl logs -n bmi-app deploy/bmi-backend          # last 100 lines
kubectl logs -n bmi-app deploy/bmi-backend --follow  # stream
kubectl logs -n bmi-app deploy/bmi-frontend
kubectl logs -n bmi-app postgres-0
```

### Debug a crashing pod
```bash
kubectl describe pod -n bmi-app <pod-name>   # check Events section
kubectl logs -n bmi-app <pod-name> --previous # logs from crashed container
```

### Exec into a running pod
```bash
kubectl exec -it -n bmi-app deploy/bmi-backend -- sh
kubectl exec -it -n bmi-app postgres-0 -- psql -U bmi_user -d bmidb
```

### Check backend health
```bash
curl http://13.127.88.162:30080/api/measurements
curl http://13.127.88.162:30080/health
# Note: /health is served by nginx as a proxy to backend /health
```

### Manually refresh the ECR pull secret
The ECR token expires every **12 hours**. `deploy.sh` refreshes it automatically. To refresh manually:
```bash
bash k8s/setup-ecr-secret.sh
```

### Verify secrets are correct
```bash
# Check database password
kubectl get secret postgres-secret -n bmi-app \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

# Check DATABASE_URL password matches
kubectl get secret backend-secret -n bmi-app \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

### Restart a deployment
```bash
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app
```

### Scale replicas
```bash
kubectl scale deployment/bmi-backend  --replicas=3 -n bmi-app
kubectl scale deployment/bmi-frontend --replicas=3 -n bmi-app
```

### Run a migration manually
```bash
# Re-run the migration job (jobs are immutable, must delete first)
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
kubectl apply  -f k8s/postgres/migration-job.yaml
kubectl wait --for=condition=complete job/bmi-migrations -n bmi-app --timeout=90s
kubectl logs -n bmi-app -l job-name=bmi-migrations
```

---

## Security

| Area | Implementation |
|---|---|
| **Non-root containers** | Backend runs as `appuser:appgroup` (non-root UID) |
| **Minimal images** | Alpine-based; multi-stage builds discard build tooling |
| **Secrets not in git** | `k8s/postgres/secret.yaml` and `k8s/backend/secret.yaml` are gitignored |
| **ECR token not in git** | `setup-ecr-secret.sh` fetches a fresh token at deploy time via instance profile |
| **Internal services** | Backend and PostgreSQL are ClusterIP — unreachable from outside the cluster |
| **Single external port** | Only NodePort 30080 is exposed; browser never talks directly to the backend |
| **Nginx security headers** | `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`, `X-XSS-Protection: 1; mode=block` |
| **Server version hidden** | `server_tokens off` in nginx config |
| **DB constraints** | CHECK constraints on all numeric columns; ENUM-like checks on sex and activity_level |
| **Input validation** | Backend validates all request fields before DB write; returns 400 on invalid input |
| **CORS** | Production CORS locked to `FRONTEND_URL`; moot in K8s since nginx proxies all `/api` requests |

---

## Design Decisions

**Why NodePort instead of Ingress?**  
The cluster has a single worker node and no cloud load balancer controller. NodePort is the simplest exposure method requiring no additional controller installation.

**Why hostPath PersistentVolume?**  
With one worker node, hostPath is sufficient and requires no external storage dependency. The `nodeAffinity` rule pins the postgres pod to worker-1 permanently, ensuring data co-location. Upgrading to an EBS CSI-backed StorageClass requires only changing the PV/PVC without touching the StatefulSet.

**Why a Kubernetes Job for migrations instead of an init container?**  
An init container runs every time the pod starts, which would apply migrations on every backend restart. A Job runs once (or until it succeeds) and its completion status is visible in `kubectl get jobs`. This makes migration status explicit and auditable.

**Why git SHA as the image tag?**  
`latest` is mutable — re-deploying with `latest` gives no traceability. SHA tags are immutable. The deployment YAML always reflects the exact commit that is running, making rollback and audit straightforward.

**Why is `imagePullPolicy: Always` set?**  
ECR tokens are short-lived. `Always` ensures the kubelet re-authenticates with ECR on every pod start rather than relying on a cached image that may have been pulled with an expired credential.

**Why does the frontend proxy `/api` at the nginx level rather than the browser making cross-origin requests?**  
Eliminates CORS entirely, hides the backend address from clients, and allows the backend URL to change (e.g. cluster-internal DNS, different port) without any frontend code change.

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, Hogarth Worldwide  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
