# BMI Health Tracker — LoadBalancer (MetalLB) Variant — Full Guide

This folder is a self-contained, alternative deployment of the same app as
[`k8s/`](../k8s/README.md) and [`k8s-ingress/`](../k8s-ingress/README.md):
identical app manifests, but the frontend `Service` is `type: LoadBalancer`,
fulfilled by **MetalLB** (since this kubeadm cluster has no
cloud-controller-manager to satisfy it natively), fronted by a
manually-created **AWS Network Load Balancer**.

> **Do not apply `k8s/`, `k8s-argocd/`, `k8s-ingress/` and `k8s-LoadBalancer/`
> to the same cluster at the same time.** They all use the same namespace
> (`bmi-app`), the same PostgreSQL hostPath (`/data/postgres`) and the same
> node label (`role=postgres-storage`) — these are alternative deployment
> methods for the same app, not meant to coexist.

## Cluster Topology

| Node | Role | Private IP | Public IP | Subnet |
|---|---|---|---|---|
| k8s-lab-master | Control-plane | 10.0.10.34 | 13.127.210.35 | Public |
| k8s-lab-worker-1 | Worker (PostgreSQL) | 10.0.132.170 | — | Private |
| k8s-lab-worker-2 | Worker | 10.0.141.21 | — | Private |

> **Note:** The node names and IP addresses above are from a specific cluster.
> Replace them with your actual values in all commands throughout this guide.

---

- [Prerequisites](#prerequisites)
- [Why MetalLB?](#why-metallb)
- [What's different from `k8s/`](#whats-different-from-k8s)
- [Part 1 — Deploy WITH Automation Scripts](#part-1--deploy-with-automation-scripts)
- [Part 2 — Deploy WITHOUT Automation Scripts (Full Manual)](#part-2--deploy-without-automation-scripts-full-manual)
- [Choosing the address pool range](#choosing-the-address-pool-range)
- [Create the AWS Network Load Balancer (manual, one-time)](#create-the-aws-network-load-balancer-manual-one-time)
- [Update Workflow (Every Code Change)](#update-workflow-every-code-change)
- [Rollback](#rollback)
- [Useful Commands](#useful-commands)
- [Design Decisions](#design-decisions-delta-from-k8sreadmemd)
- [Reference](#reference)

---

## Prerequisites

All prerequisites must be satisfied before starting either Part 1 or Part 2.

### Local Machine

> **Do all steps in this section on your laptop first — before SSH-ing into any server.**

| Requirement | Install | Verify |
|---|---|---|
| Docker | see install steps below | `docker --version` |
| AWS CLI v2 | see install steps below | `aws --version` |
| Git | https://git-scm.org | `git --version` |
| AWS credentials | Option A: named profile `sarowar-ostad` OR Option B: environment variables | see below |

#### Install Docker

**macOS / Windows:** Download and install Docker Desktop from https://www.docker.com/products/docker-desktop/ — it includes the Docker daemon and CLI.

**Ubuntu / Debian (local machine or EC2):**
```bash
# Remove any old versions
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key and repository
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

# Allow your user to run Docker without sudo
sudo usermod -aG docker $USER
newgrp docker
```

**Verify:**
```bash
docker --version
# Expected: Docker version 25.x.x, build ...

docker run --rm hello-world
# Expected: Hello from Docker!
```

#### Install AWS CLI v2

**macOS:** `brew install awscli`

**Windows:** `winget install Amazon.AWSCLI`

**Ubuntu / Debian:**
```bash
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp/awscli-install
sudo /tmp/awscli-install/aws/install
rm -rf /tmp/awscli.zip /tmp/awscli-install
```

**Verify:**
```bash
aws --version
# Expected: aws-cli/2.x.x Python/3.x.x ...
```

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
| `/data/postgres` on k8s-lab-worker-1 | PostgreSQL hostPath PV requires this directory — see below |

#### Create the PostgreSQL data directory on Worker-1

> **Run once before the first deploy.** `deploy.sh` does this automatically, but if you are following the manual path you must do it yourself.

```bash
# From your local machine — SSH through master to worker-1
ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-1-PRIVATE-IP>

# On worker-1:
sudo mkdir -p /data/postgres
sudo chmod 777 /data/postgres
# PostgreSQL pod runs as UID 999 — needs write access

# Verify:
ls -ld /data/postgres
# Expected: drwxrwxrwx 2 root root 4096 ...

exit
```

Verify cluster is healthy:
```bash
# Directory: k8s-lab-master — ~/kubernetes-3tier-app
kubectl get nodes -o wide
# Expected: all 3 nodes STATUS=Ready
```

---

## Why MetalLB?

A plain `Service type=LoadBalancer` (see the referenced
`service-loadbalancer.yaml`) only works out of the box on managed Kubernetes
(EKS/GKE/AKS) where a cloud controller-manager watches for `LoadBalancer`
Services and provisions a real cloud LB. On a self-managed kubeadm cluster
there is no such controller — the Service would stay `Pending` forever.
**MetalLB** plugs that gap: it watches for `LoadBalancer` Services and assigns
each one a virtual IP (VIP) from a configured address pool, then announces
that VIP on the local network (Layer 2 / ARP mode here) so traffic to it
reaches whichever node is currently the "leader" for that VIP.

**Important caveat:** the VIP MetalLB assigns is a **private IP inside your
VPC subnet** — it is NOT internet-reachable by itself. To expose it publicly,
this variant pairs MetalLB with a manually-created **AWS NLB using a
target group of type `ip`**, pointing directly at the MetalLB VIP. The NLB
gives you a real public DNS name; MetalLB's automatic node failover happens
transparently underneath it (the NLB just keeps hitting the same VIP,
regardless of which node currently owns it).

Traffic flow:
```
Browser → AWS NLB (manual, public DNS name)
  └─ target group (type: ip) → MetalLB VIP (private, e.g. 10.0.10.24x)
       └─ whichever node's speaker currently owns the VIP (L2/ARP)
            └─ bmi-frontend-svc (LoadBalancer) → Nginx pod :80
                 └─ /api/* proxied → bmi-backend-svc:3000
                      └─ bmi-postgres-svc:5432 → PostgreSQL StatefulSet
```

---

## What's different from `k8s/`

| | `k8s/` | `k8s-LoadBalancer/` |
|---|---|---|
| Frontend Service | `NodePort` (`80:30080/TCP`) | `LoadBalancer` |
| External IP source | none (NodePort on node IPs) | MetalLB (`metallb-system` namespace, L2 mode) |
| Public access | `http://<MASTER-PUBLIC-IP>:30080` | AWS NLB DNS name (manual, see below) |
| New resources | — | `metallb/install-metallb.sh`, `metallb/ipaddresspool.yaml`, `metallb/l2advertisement.yaml` |
| `/api` routing | nginx `proxy_pass` inside the frontend pod (unchanged) | same, unchanged |
| TLS | none | none (out of scope for this variant too) |

---

## Part 1 — Deploy WITH Automation Scripts

Two scripts handle the full lifecycle. Run them in order.

| Script | Run On | Purpose |
|---|---|---|
| `k8s-LoadBalancer/build-and-push.sh` | Local machine (repo root) | Build images → push to ECR → patch YAMLs → git commit |
| `k8s-LoadBalancer/deploy.sh` | k8s-lab-master | Apply all manifests in order → install MetalLB → wait for readiness |

### Phase 1.1 — One-Time Cluster Setup

#### A. Prepare Worker-1 Storage

> **Directory: k8s-lab-worker-1 — home directory (`~`)**

```bash
# From local machine — jump through master to worker-1
ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-1-PRIVATE-IP>

# On k8s-lab-worker-1:
sudo mkdir -p /data/postgres
sudo chmod 777 /data/postgres
# PostgreSQL pod runs as UID 999 — requires write access
```

**Verify:**
```bash
ls -ld /data/postgres
# Expected: drwxrwxrwx 2 root root 4096 ...

exit
```

#### B. Set Up the Control-Plane

> **Directory: k8s-lab-master — home directory (`~`)**

```bash
ssh ubuntu@<MASTER-PUBLIC-IP>

# Install AWS CLI
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
unzip -q /tmp/a.zip -d /tmp
sudo /tmp/aws/install
```

**Verify:**
```bash
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
ls k8s-LoadBalancer/
# Expected: backend/ frontend/ postgres/ metallb/ build-and-push.sh deploy.sh namespace.yaml ...
```

#### C. Apply Namespace and Secrets

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
kubectl apply -f k8s-LoadBalancer/namespace.yaml
# Creates the bmi-app namespace
```

**Verify:**
```bash
kubectl get namespace bmi-app
# Expected: NAME      STATUS   AGE
#           bmi-app   Active   5s
```

> **If using `deploy.sh`:** you can skip the secret creation below — it will
> prompt you for a database password and create both secrets automatically
> on first run if they don't exist yet.
>
> **If you want to pre-create secrets** (or are following Part 2 manually),
> use the commands below. Use the **same password** in both.

```bash
DB_PASS="<YOUR-STRONG-PASSWORD>"   # min 8 chars, e.g. MyStr0ng!Pass2026

# postgres-secret
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb \
  --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="${DB_PASS}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -

# backend-secret — DATABASE_URL password must match POSTGRES_PASSWORD above
kubectl create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:${DB_PASS}@bmi-postgres-svc:5432/bmidb" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Verify:**
```bash
kubectl get secret -n bmi-app
# Expected:
# NAME              TYPE                             DATA   AGE
# backend-secret    Opaque                           1      5s
# postgres-secret   Opaque                           3      10s
```

#### D. (Optional) Install ECR Credential Provider on All Nodes

> **Background:** `k8s-LoadBalancer/setup-ecr-on-nodes.sh` configures the kubelet to authenticate ECR image pulls directly using the node's EC2 instance profile. Once installed, image pulls succeed without any `imagePullSecrets` and without the 12-hour token refresh cycle.
>
> **Current cluster approach:** `setup-ecr-secret.sh` (imagePullSecrets) — used by `deploy.sh` on every run. This section is optional; skip it if you are happy with the current approach. Both methods work in parallel if both are configured.

> **Run this on ALL three nodes (master + both workers).**

```bash
# Directory: local machine — anywhere

# Copy the script to each node:
scp k8s-LoadBalancer/setup-ecr-on-nodes.sh ubuntu@<MASTER-PUBLIC-IP>:~/

ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-1-PRIVATE-IP> \
  "cat > ~/setup-ecr-on-nodes.sh" < k8s-LoadBalancer/setup-ecr-on-nodes.sh

ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-2-PRIVATE-IP> \
  "cat > ~/setup-ecr-on-nodes.sh" < k8s-LoadBalancer/setup-ecr-on-nodes.sh

# Run on k8s-lab-master:
ssh ubuntu@<MASTER-PUBLIC-IP> "sudo bash ~/setup-ecr-on-nodes.sh"

# Run on k8s-lab-worker-1:
ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-1-PRIVATE-IP> "sudo bash ~/setup-ecr-on-nodes.sh"

# Run on k8s-lab-worker-2:
ssh -J ubuntu@<MASTER-PUBLIC-IP> ubuntu@<WORKER-2-PRIVATE-IP> "sudo bash ~/setup-ecr-on-nodes.sh"
```

**Verify:**
```bash
kubectl get nodes
# Expected: all 3 nodes  STATUS=Ready
```

> **If you complete this step:** you may remove `imagePullSecrets: [{name: ecr-credentials}]` from `k8s-LoadBalancer/backend/deployment.yaml` and `k8s-LoadBalancer/frontend/deployment.yaml` and stop calling `setup-ecr-secret.sh`.

### Phase 1.2 — Build and Push Images

> **Directory: local machine — repo root (`kubernetes-3tier-app/`)**

```bash
cd kubernetes-3tier-app
# IMPORTANT: must be repo root — build-and-push.sh uses ./backend and ./frontend paths

bash k8s-LoadBalancer/build-and-push.sh
```

**What the script does internally:**
| Step | Command run internally |
|---|---|
| [1/5] ECR Login | `aws ecr get-login-password \| docker login` |
| [2/5] Build | `docker build -t bmi-backend:<SHA> ./backend` and `./frontend` |
| [3/5] Tag | `docker tag` — adds SHA and `latest` tags for ECR |
| [3b/5] Ensure ECR repos | `aws ecr describe-repositories` — auto-creates `bmi-backend`/`bmi-frontend` via `aws ecr create-repository` if missing |
| [4/5] Push | `docker push` — all 4 tags (2 images × 2 tags) |
| [5/5] Patch + Commit | patches `k8s-LoadBalancer/backend/deployment.yaml` and `k8s-LoadBalancer/frontend/deployment.yaml` → `git commit -m "deploy(lb): image tag <SHA>"` → `git push origin HEAD` |

**Expected output:**
```
[1/5] Logging in to ECR...
Login Succeeded
[2/5] Building backend image...
      Building frontend image...
[3/5] Tagging images...
[3b/5] Ensuring ECR repositories exist...
      bmi-backend already exists.
      bmi-frontend already exists.
[4/5] Pushing backend to ECR...
      Pushing frontend to ECR...
[5/5] Updating deployment manifests...
      Manifests committed and pushed to git.
✅ Done!
   Backend:  388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f
   Frontend: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

**Verify:**
```bash
grep "image:" k8s-LoadBalancer/backend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-backend:9b8bf6f

grep "image:" k8s-LoadBalancer/frontend/deployment.yaml
# Expected: image: 388779989543.dkr.ecr.ap-south-1.amazonaws.com/bmi-frontend:9b8bf6f
```

### Phase 1.3 — Deploy to Kubernetes

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
ssh ubuntu@<MASTER-PUBLIC-IP>
cd kubernetes-3tier-app

git pull
# Pulls the manifest changes committed by build-and-push.sh

bash k8s-LoadBalancer/deploy.sh
```

This applies all manifests in dependency order (prerequisites → ECR secret →
PostgreSQL → migrations → backend), plus two LoadBalancer-specific phases:

| Phase | What happens | Timeout |
|---|---|---|
| [Phase 0] Prerequisites | Installs AWS CLI if missing; applies namespace; prompts for Worker-1 IP + creates `/data/postgres` if missing; labels the node `role=postgres-storage`; creates secrets if missing | — |
| [1/6] Refresh ECR secret | `setup-ecr-secret.sh` — creates/updates `ecr-credentials` imagePullSecret | — |
| [2/6] PostgreSQL | Applies PV→PVC→StatefulSet→Service, waits for Ready | 120s |
| [3/6] Migrations | Deletes old Job, applies migration Job, waits for Complete | 90s |
| [4/6] Backend | Applies configmap→deployment→service, waits for rollout | 90s |
| [5/6] MetalLB | Runs `k8s-LoadBalancer/metallb/install-metallb.sh` — installs the MetalLB native manifest, waits for `controller`/`speaker` rollout, then applies the `IPAddressPool` and `L2Advertisement` | 120s |
| [6/6] Frontend | Applies the `LoadBalancer` frontend Service, waits for rollout, then polls for an `EXTERNAL-IP` (up to 60s) | 90s |

**Verify:**
```bash
kubectl get pods -n bmi-app
# Expected:
# NAME                             READY   STATUS      RESTARTS   AGE
# bmi-backend-xxxxxxx-xxxxx        1/1     Running     0          1m
# bmi-backend-xxxxxxx-xxxxx        1/1     Running     0          1m
# bmi-frontend-xxxxxxx-xxxxx       1/1     Running     0          45s
# bmi-frontend-xxxxxxx-xxxxx       1/1     Running     0          45s
# bmi-migrations-xxxxx             0/1     Completed   0          2m
# postgres-0                       1/1     Running     0          3m

kubectl get pods -n metallb-system
# Expected: controller-xxxxx 1/1 Running, speaker-xxxxx (one per node) 1/1 Running

kubectl get ipaddresspool,l2advertisement -n metallb-system
# Expected: bmi-pool, bmi-l2adv

kubectl get svc bmi-frontend-svc -n bmi-app
# Expected: TYPE=LoadBalancer   EXTERNAL-IP=<an IP from your pool>   PORT(S)=80:xxxxx/TCP

curl http://<EXTERNAL-IP>/
# Expected: frontend HTML (only reachable from inside the VPC at this point)
```

> The app is **not yet internet-reachable** — the MetalLB `EXTERNAL-IP` is a
> private VPC IP. Continue to [Create the AWS Network Load Balancer](#create-the-aws-network-load-balancer-manual-one-time)
> to expose it publicly.

---

## Part 2 — Deploy WITHOUT Automation Scripts (Full Manual)

Every command that the scripts execute, broken down individually with explanations.

### Phase 2.1 — One-Time Cluster Setup

Same as Phase 1.1 — see sections A, B, C above (and optionally D for the permanent ECR credential provider).

### Phase 2.2 — Authenticate to ECR

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

export ECR_BASE="388779989543.dkr.ecr.ap-south-1.amazonaws.com"
export TAG=$(git rev-parse --short HEAD)
# TAG = git short SHA of current commit (e.g. 9b8bf6f) — traceable, rollback-friendly

echo "Building tag: ${TAG}"

aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin "${ECR_BASE}"
```

**Verify:**
```bash
echo "Login status: $?"
# Expected: Login Succeeded, exit code 0
```

### Phase 2.3 — Build Docker Images

> **Directory: local machine — kubernetes-3tier-app/**

```bash
docker build -t "bmi-backend:${TAG}" ./backend
docker build -t "bmi-frontend:${TAG}" ./frontend
```

**Verify:**
```bash
docker images bmi-backend
docker images bmi-frontend
# Expected: both show a row with TAG=<your SHA>
```

### Phase 2.4 — Tag Images for ECR

> **Directory: local machine — kubernetes-3tier-app/**

```bash
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:${TAG}"
docker tag "bmi-backend:${TAG}"  "${ECR_BASE}/bmi-backend:latest"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:${TAG}"
docker tag "bmi-frontend:${TAG}" "${ECR_BASE}/bmi-frontend:latest"
```

**Verify:**
```bash
docker images | grep "${ECR_BASE}"
# Expected: 4 rows (backend/frontend × SHA/latest)
```

### Phase 2.5 — Push Images to ECR

> **Directory: local machine — kubernetes-3tier-app/**

```bash
docker push "${ECR_BASE}/bmi-backend:${TAG}"
docker push "${ECR_BASE}/bmi-backend:latest"
docker push "${ECR_BASE}/bmi-frontend:${TAG}"
docker push "${ECR_BASE}/bmi-frontend:latest"
```

**Verify:**
```bash
aws ecr list-images --repository-name bmi-backend --region ap-south-1 \
  --profile sarowar-ostad --query 'imageIds[].imageTag'
aws ecr list-images --repository-name bmi-frontend --region ap-south-1 \
  --profile sarowar-ostad --query 'imageIds[].imageTag'
# Expected: [ "<SHA>", "latest" ] for both
```

### Phase 2.6 — Update Deployment Manifests

> **Directory: local machine — kubernetes-3tier-app/**

```bash
sed -i "s|image: .*bmi-backend:.*|image: ${ECR_BASE}/bmi-backend:${TAG}|g" \
  k8s-LoadBalancer/backend/deployment.yaml

sed -i "s|image: .*bmi-frontend:.*|image: ${ECR_BASE}/bmi-frontend:${TAG}|g" \
  k8s-LoadBalancer/frontend/deployment.yaml
```

**PowerShell equivalent (Windows):**
```powershell
(Get-Content k8s-LoadBalancer/backend/deployment.yaml) `
  -replace 'image: .*bmi-backend:.*', "image: $ECR_BASE/bmi-backend:$TAG" |
  Set-Content k8s-LoadBalancer/backend/deployment.yaml

(Get-Content k8s-LoadBalancer/frontend/deployment.yaml) `
  -replace 'image: .*bmi-frontend:.*', "image: $ECR_BASE/bmi-frontend:$TAG" |
  Set-Content k8s-LoadBalancer/frontend/deployment.yaml
```

**Verify:**
```bash
grep "image:" k8s-LoadBalancer/backend/deployment.yaml
grep "image:" k8s-LoadBalancer/frontend/deployment.yaml
# Expected: both show the ECR URL with your current SHA tag
```

### Phase 2.7 — Commit and Push Manifests

> **Directory: local machine — kubernetes-3tier-app/**

```bash
git add k8s-LoadBalancer/backend/deployment.yaml k8s-LoadBalancer/frontend/deployment.yaml
git diff --staged
# Review: should show only the image: line changed in each file

git commit -m "deploy(lb): image tag ${TAG}"
git push
```

**Verify:**
```bash
git log --oneline -3
# Expected: most recent commit is "deploy(lb): image tag <SHA>"
```

### Phase 2.8 — Deploy All Manifests to Kubernetes

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
ssh ubuntu@<MASTER-PUBLIC-IP>
cd kubernetes-3tier-app

git pull
# Expected: 1 file changed — deployment YAML with updated image tag
```

#### Step 0 — Namespace

```bash
kubectl apply -f k8s-LoadBalancer/namespace.yaml
```

**Verify:**
```bash
kubectl get namespace bmi-app
# Expected: NAME      STATUS   AGE
#           bmi-app   Active   5s
```

#### Step 0.5 — Label the PostgreSQL Storage Node and Create Application Secrets

> **Critical — do this before applying any postgres manifests.**
> `pv.yaml`, `statefulset.yaml`, and `migration-job.yaml` all use
> `role: postgres-storage` as their node selector. Without this label the
> postgres pod stays Pending forever.

```bash
# Replace <WORKER-1-NODE-NAME> with the exact name from: kubectl get nodes
kubectl label node <WORKER-1-NODE-NAME> role=postgres-storage --overwrite
```

**Verify:**
```bash
kubectl get node <WORKER-1-NODE-NAME> --show-labels | grep postgres-storage
```

> **Create secrets** — the YAML files contain `CHANGE_ME` placeholders and must
> not be applied directly. Use `--from-literal` with the same password in both.

```bash
DB_PASS="<YOUR-STRONG-PASSWORD>"   # min 8 chars

kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb \
  --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="${DB_PASS}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:${DB_PASS}@bmi-postgres-svc:5432/bmidb" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Verify:**
```bash
kubectl get secret postgres-secret backend-secret -n bmi-app
# Expected: both TYPE=Opaque
```

```bash
ECR_TOKEN=$(aws ecr get-login-password --region ap-south-1)
# Uses EC2 instance profile IAM role to fetch a 12-hour ECR password

kubectl create secret docker-registry ecr-credentials \
  --docker-server=388779989543.dkr.ecr.ap-south-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="${ECR_TOKEN}" \
  --namespace=bmi-app \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Verify:**
```bash
kubectl get secret ecr-credentials -n bmi-app
# Expected: NAME              TYPE                             DATA   AGE
#           ecr-credentials   kubernetes.io/dockerconfigjson   1      5s
```

#### Step 2 — PostgreSQL

```bash
kubectl apply -f k8s-LoadBalancer/postgres/pv.yaml
kubectl apply -f k8s-LoadBalancer/postgres/pvc.yaml
kubectl apply -f k8s-LoadBalancer/postgres/statefulset.yaml
kubectl apply -f k8s-LoadBalancer/postgres/service.yaml
```

**Verify PV bound:**
```bash
kubectl get pv postgres-pv
kubectl get pvc postgres-pvc -n bmi-app
# Expected: both STATUS=Bound
```

```bash
kubectl wait --for=condition=ready pod \
  -l app=postgres \
  -n bmi-app \
  --timeout=120s
# Expected: pod/postgres-0 condition met
```

#### Step 3 — Database Migrations

```bash
kubectl apply -f k8s-LoadBalancer/postgres/migrations-configmap.yaml
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
kubectl apply -f k8s-LoadBalancer/postgres/migration-job.yaml

kubectl wait --for=condition=complete job/bmi-migrations \
  -n bmi-app \
  --timeout=90s
```

**Verify:**
```bash
kubectl logs -n bmi-app job/bmi-migrations
# Expected: Running migration 001... Running migration 002... All migrations completed successfully!

kubectl get job bmi-migrations -n bmi-app
# Expected: COMPLETIONS 1/1
```

#### Step 4 — Backend

```bash
kubectl apply -f k8s-LoadBalancer/backend/configmap.yaml
kubectl apply -f k8s-LoadBalancer/backend/deployment.yaml
kubectl apply -f k8s-LoadBalancer/backend/service.yaml

kubectl rollout status deployment/bmi-backend -n bmi-app --timeout=90s
```

**Verify:**
```bash
kubectl get pods -n bmi-app -l app=bmi-backend
kubectl exec -n bmi-app deploy/bmi-backend -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"}
```

#### Step 5 — MetalLB

> **Must run BEFORE the frontend Step 6** — the frontend Service is
> `type: LoadBalancer` and needs MetalLB's controller already running to be
> assigned an `EXTERNAL-IP`. This ordering differs from the plain `k8s/`
> variant, which has no such dependency.

```bash
bash k8s-LoadBalancer/metallb/install-metallb.sh
```

Or manually, step by step:
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

kubectl rollout status deployment/controller -n metallb-system --timeout=120s
kubectl rollout status daemonset/speaker    -n metallb-system --timeout=120s

kubectl apply -f k8s-LoadBalancer/metallb/ipaddresspool.yaml
kubectl apply -f k8s-LoadBalancer/metallb/l2advertisement.yaml
```

**Verify:**
```bash
kubectl get pods -n metallb-system
# Expected: controller-xxxxx 1/1 Running, speaker-xxxxx (one per node) 1/1 Running

kubectl get ipaddresspool,l2advertisement -n metallb-system
# Expected: bmi-pool, bmi-l2adv
```

#### Step 6 — Frontend

```bash
kubectl apply -f k8s-LoadBalancer/frontend/deployment.yaml
kubectl apply -f k8s-LoadBalancer/frontend/service.yaml

kubectl rollout status deployment/bmi-frontend -n bmi-app --timeout=90s
```

**Verify:**
```bash
kubectl get pods -n bmi-app -l app=bmi-frontend
kubectl get svc bmi-frontend-svc -n bmi-app
# Expected: TYPE=LoadBalancer   EXTERNAL-IP=<an IP from your pool>   PORT(S)=80:xxxxx/TCP
```

#### Final Verification — All Resources

```bash
kubectl get pods -n bmi-app
kubectl get svc -n bmi-app

curl http://<EXTERNAL-IP>/
# Expected: frontend HTML (only reachable from inside the VPC at this point)
```

> Continue to [Create the AWS Network Load Balancer](#create-the-aws-network-load-balancer-manual-one-time)
> to make the app internet-reachable.

---

## Choosing the address pool range

[`metallb/ipaddresspool.yaml`](metallb/ipaddresspool.yaml) ships with a
**guessed placeholder range** (`10.0.10.240-10.0.10.250`, based on the
`10.0.10.34` master IP referenced in `k8s/README.md`'s cluster topology
table). **Verify it's actually free in your subnet before deploying:**

```bash
# List every private IP already in use in your VPC (instances + ENIs)
aws ec2 describe-network-interfaces --region ap-south-1 --profile sarowar-ostad \
  --query 'NetworkInterfaces[].PrivateIpAddress' --output table

# Confirm your master/worker subnet CIDR
aws ec2 describe-subnets --region ap-south-1 --profile sarowar-ostad \
  --subnet-ids <PUBLIC_SUBNET_ID> --query 'Subnets[0].CidrBlock' --output text
```

Pick a range inside that CIDR that appears in neither list, avoiding the
first 4 and last 1 addresses of the CIDR block (AWS reserves those). Update
`metallb/ipaddresspool.yaml` accordingly before running `deploy.sh`.

---

## Create the AWS Network Load Balancer (manual, one-time)

Once `bmi-frontend-svc` has an `EXTERNAL-IP` from MetalLB:

1. **Target group** — type **IP**, protocol TCP (or HTTP), port **80**.
   Register the MetalLB `EXTERNAL-IP` itself as the single target (not the
   EC2 instances — the VIP already floats between nodes via MetalLB's own
   failover, so the NLB doesn't need to know which node currently owns it).
2. **Health check** — HTTP, path `/`, expect `200`.
3. **Load balancer** — internet-facing **Network Load Balancer**, placed in
   the public subnet (same VPC as the cluster — NLB target type `ip` requires
   targets to be reachable from the LB's subnets).
4. **Listener** — TCP/HTTP port `80` → forward to the target group above.
5. **Security group** — ensure the instances' SG allows inbound TCP `80` from
   the NLB (same VPC traffic, or the NLB's subnet CIDR if using a dedicated SG).
6. **Test:**
   ```bash
   curl http://<NLB-DNS-NAME>/
   curl http://<NLB-DNS-NAME>/api/measurements
   ```

> If the MetalLB `EXTERNAL-IP` ever changes (e.g. pool edited, Service
> recreated), the NLB target group's registered IP must be updated to match.

Optionally update `FRONTEND_URL` in [`backend/configmap.yaml`](backend/configmap.yaml)
to the NLB's DNS name — purely cosmetic, CORS is moot since nginx proxies
`/api` same-origin (see Design Decisions below).

---

## Update Workflow (Every Code Change)

### Step 1 — Local machine

> **Directory: local machine — kubernetes-3tier-app/**

```bash
# With script (recommended):
bash k8s-LoadBalancer/build-and-push.sh

# Without script — run Phases 2.2 through 2.7 in order
```

### Step 2 — Control-plane

> **Directory: k8s-lab-master — ~/kubernetes-3tier-app**

```bash
# With script:
git pull && bash k8s-LoadBalancer/deploy.sh

# Without script:
git pull
# Then run Phase 2.8 Steps 0, 0.5, 2, 3, 4, 6 (Step 5 MetalLB is one-time setup — skip on routine updates)
```

> `kubectl apply` with a changed image tag triggers a **rolling update**
> automatically. Pods are replaced one at a time — zero downtime.
>
> MetalLB and the AWS NLB are **one-time infrastructure setup** — the
> `bmi-frontend-svc` Service itself doesn't change on a routine code update,
> so its `EXTERNAL-IP` and the NLB's registered target stay stable across
> deploys. You do not need to touch MetalLB or recreate the NLB for
> ordinary app updates.

---

## Rollback

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

> Rollback only affects the `Deployment` objects (backend/frontend pods) — it
> does not touch the `bmi-frontend-svc` Service, MetalLB, or the AWS NLB, so
> the `EXTERNAL-IP` and public NLB DNS name remain unchanged throughout.

---

## Useful Commands

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
bash k8s-LoadBalancer/setup-ecr-secret.sh

# Force restart without image change
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app

# Re-run migrations manually
kubectl delete job bmi-migrations -n bmi-app --ignore-not-found=true
kubectl apply -f k8s-LoadBalancer/postgres/migration-job.yaml
kubectl wait --for=condition=complete job/bmi-migrations -n bmi-app --timeout=90s
```

### MetalLB / LoadBalancer troubleshooting

```bash
# MetalLB component health
kubectl get pods -n metallb-system
kubectl get ipaddresspool,l2advertisement -n metallb-system

# Frontend Service EXTERNAL-IP
kubectl get svc bmi-frontend-svc -n bmi-app

# Speaker logs — check ARP/L2 announcement issues
kubectl logs -n metallb-system -l app=metallb,component=speaker --tail=100

# Controller logs — check IP allocation issues
kubectl logs -n metallb-system -l app=metallb,component=controller --tail=100
```

> **`EXTERNAL-IP` stuck on `<pending>`?** Check, in order: (1) `IPAddressPool`
> and `L2Advertisement` are applied (`kubectl get ipaddresspool,l2advertisement -n metallb-system`),
> (2) the pool isn't exhausted (only 11 IPs in the default range — one per
> `LoadBalancer` Service), (3) `speaker` pods are `Running` on all 3 nodes,
> (4) the range in `metallb/ipaddresspool.yaml` is actually free in your subnet
> (see [Choosing the address pool range](#choosing-the-address-pool-range)).

---

## Design Decisions (delta from `k8s/README.md`)

**Why MetalLB instead of NodePort or ingress-nginx?**
Demonstrates the native `Service type=LoadBalancer` workflow on a self-managed
cluster — the closest bare-metal equivalent to what EKS/GKE/AKS give you
automatically. `k8s/`'s NodePort and `k8s-ingress/`'s ingress-nginx variants
are kept unchanged for comparison.

**Why Layer 2 mode instead of BGP?**
BGP requires a BGP-speaking router peer, which plain AWS EC2 doesn't provide
without extra infrastructure. L2 mode works out of the box on any flat subnet,
including AWS VPC subnets, using ARP-based failover between nodes.

**Why target type `ip` (pointing at the MetalLB VIP) instead of target type
`instance` + NodePort (like `k8s-ingress/`)?**
The MetalLB VIP already floats between nodes automatically — targeting it
directly means the NLB target group never needs to know which physical node
is currently serving traffic, matching how `Service type=LoadBalancer` is
meant to behave.

---

## Reference

| Item | Value |
|---|---|
| App URL | AWS NLB DNS name (manual, see [Create the AWS Network Load Balancer](#create-the-aws-network-load-balancer-manual-one-time)) |
| ECR registry | 388779989543.dkr.ecr.ap-south-1.amazonaws.com |
| Kubernetes namespace | bmi-app |
| PostgreSQL data path | `/data/postgres` on the node labelled `role=postgres-storage` |
| PV reclaim policy | Retain — data not deleted on pod/PVC deletion |
| Image tag strategy | git short SHA — unique per commit |
| ECR token lifetime | 12 hours — must refresh before deploying |
| Secrets in git | Never — `postgres/secret.yaml` and `backend/secret.yaml` are .gitignored |
| MetalLB IP pool | `metallb/ipaddresspool.yaml` — verify range is free in your subnet before deploying |
| NLB target group | type `ip`, pointing at the MetalLB `EXTERNAL-IP` — update if the IP ever changes |

---

## Project Lead

**MD Sarowar Alam**
Lead DevOps Engineer, WPP Production
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
