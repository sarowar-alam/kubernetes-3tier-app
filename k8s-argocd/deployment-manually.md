# Manual Deployment Guide — BMI Health Tracker

> Run every command on the **control-plane node** unless noted otherwise.  
> All paths are relative to the repo root: `~/kubernetes-3tier-app`

---

## Pre-requisites

```bash
# Clone the repo (if not already done)
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app
```

---

## Step 0 — Install AWS CLI

```bash
apt-get install -y unzip
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/aws-cli.zip
unzip -q /tmp/aws-cli.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/aws-cli.zip /tmp/aws
```

**Verify:**
```bash
aws --version
# Expected: aws-cli/2.x.x ...
```

---

## Step 1 — Create Namespaces

```bash
kubectl apply -f k8s-argocd/argocd/namespace.yaml
kubectl apply -f k8s-argocd/app/namespace.yaml
```

**Verify:**
```bash
kubectl get ns argocd bmi-app
# Expected:
# NAME      STATUS   AGE
# argocd    Active   Xs
# bmi-app   Active   Xs
```

---

## Step 2 — Apply Secrets (gitignored — must exist locally)

```bash
kubectl apply -f k8s-argocd/app/postgres/secret.yaml
kubectl apply -f k8s-argocd/app/backend/secret.yaml
```

**Verify:**
```bash
kubectl get secret postgres-secret backend-secret -n bmi-app
# Expected: both secrets listed with TYPE=Opaque
```

---

## Step 3 — Create PersistentVolume

```bash
kubectl apply -f k8s-argocd/app/postgres/pv.yaml
```

**Verify:**
```bash
kubectl get pv postgres-pv
# Expected: STATUS=Available, CAPACITY=5Gi, RECLAIM POLICY=Retain
```

---

## Step 4 — Create `/data/postgres` Directory on worker-1

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
```

Wait for it to complete, then clean up:
```bash
kubectl wait pod/mkdir-postgres -n bmi-app \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s

kubectl logs mkdir-postgres -n bmi-app
# Expected output: DONE

kubectl delete pod mkdir-postgres -n bmi-app --ignore-not-found
```

---

## Step 4.5 — Create ECR Pull Secret

```bash
bash k8s-argocd/setup-ecr-secret.sh
```

**Verify:**
```bash
kubectl get secret ecr-credentials -n bmi-app
# Expected: TYPE=kubernetes.io/dockerconfigjson
```

---

## Step 5 — Install ArgoCD

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for ArgoCD server to be ready (up to 3 minutes):
```bash
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
```

**Verify all ArgoCD pods are Running:**
```bash
kubectl get pods -n argocd
# Expected: all 7 pods at STATUS=Running, READY=1/1
```

---

## Step 6 — Expose ArgoCD UI as NodePort

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort"}}'
```

Get the assigned port and the public IP:
```bash
ARGOCD_PORT=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

echo "ArgoCD UI: http://${PUBLIC_IP}:${ARGOCD_PORT}"
```

**Verify:**
```bash
kubectl get svc argocd-server -n argocd
# Expected: TYPE=NodePort, PORT(S)=80:<port>/TCP
```

---

## Step 7 — Create ArgoCD Application (triggers first sync)

```bash
kubectl apply -f k8s-argocd/argocd/application.yaml
```

Force an immediate sync (don't wait for the 3-minute auto-poll):
```bash
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Verify:**
```bash
kubectl get application bmi-health-tracker -n argocd
# Expected: SYNC STATUS=Synced, HEALTH STATUS=Healthy
```

---

## Step 8 — Verify Everything is Running

```bash
# All app pods
kubectl get pods -n bmi-app
# Expected:
# postgres-0               1/1  Running    
# bmi-migrations-xxxxx     0/1  Completed  
# bmi-backend-xxxxx        1/1  Running    (×2)
# bmi-frontend-xxxxx       1/1  Running    (×2)

# PVC is bound
kubectl get pvc -n bmi-app
# Expected: STATUS=Bound, VOLUME=postgres-pv

# Services are up
kubectl get svc -n bmi-app
# Expected: bmi-frontend-svc NodePort :30080, bmi-backend-svc ClusterIP :3000, bmi-postgres-svc ClusterIP :5432

# Secrets present
kubectl get secret postgres-secret backend-secret ecr-credentials -n bmi-app
```

**Get the live app URL:**
```bash
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/public-ipv4)
echo "App URL: http://${PUBLIC_IP}:30080"
```

---

## Get ArgoCD Admin Password

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
```

Login: **Username:** `admin` | **Password:** output from above command

---

## Troubleshooting

### ArgoCD repo-server connection refused
```bash
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=120s
```

### Migration job stuck in Init:0/1
```bash
# Check if postgres-0 is running
kubectl get pods -n bmi-app
# Check if service endpoint exists
kubectl get endpoints bmi-postgres-svc -n bmi-app
# Check migration logs
kubectl logs -l job-name=bmi-migrations -n bmi-app
```

### Pods in ImagePullBackOff (ECR token expired)
```bash
bash k8s-argocd/setup-ecr-secret.sh
# Pods retry automatically within ~30 seconds
```

### ArgoCD Application deleted accidentally
```bash
kubectl apply -f k8s-argocd/argocd/application.yaml
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Force a full re-sync
```bash
kubectl annotate application bmi-health-tracker -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```
