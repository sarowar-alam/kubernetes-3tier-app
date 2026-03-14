# Deployment Guide

**Repo:** https://github.com/sarowar-alam/kubernetes-3tier-app  
**App:** http://13.127.88.162:30080

---

## One-Time Setup (fresh cluster)

### 1. AWS — Create and attach IAM role to both EC2 instances

#### Create the IAM role (once)

1. Go to **AWS Console → IAM → Roles → Create role**
2. **Trusted entity type:** AWS service
3. **Use case:** EC2
4. **Permissions — attach these two policies:**

   | Policy name | Purpose |
   |---|---|
   | `AmazonEC2ContainerRegistryReadOnly` | Allows EC2 nodes to pull images from ECR |
   | `AmazonEC2ReadOnlyAccess` | Optional — allows `aws sts get-caller-identity` for debugging |

5. **Role name:** `k8s-node-ecr-role` (or any name you prefer)
6. Click **Create role**

#### Attach the role to both EC2 instances

AWS Console → **EC2 → Instances** → select each instance → **Actions → Security → Modify IAM role** → select `k8s-node-ecr-role` → **Update IAM role**

Do this for both:
- `k8s-control-plane` — 10.0.5.64
- `k8s-worker-1` — 10.0.130.111

> **Why both nodes?**  
> The control-plane needs it to run `aws ecr get-login-password` (used by `setup-ecr-secret.sh`).  
> The worker nodes need it so kubelet can pull ECR images when scheduling pods.

### 2. Worker node — Create postgres data directory
```bash
ssh ubuntu@10.0.130.111
sudo mkdir -p /data/postgres && sudo chmod 777 /data/postgres
exit
```

### 3. Control-plane — Install AWS CLI
```bash
ssh ubuntu@10.0.5.64
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/a.zip
unzip -q /tmp/a.zip -d /tmp && sudo /tmp/aws/install
aws --version
```

### 4. Control-plane — Clone repo and apply secrets
```bash
git clone https://github.com/sarowar-alam/kubernetes-3tier-app.git
cd kubernetes-3tier-app

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/postgres/secret.yaml   # contains POSTGRES_PASSWORD
kubectl apply -f k8s/backend/secret.yaml    # contains DATABASE_URL (password must match above)
```

### 5. Control-plane — Deploy everything
```bash
bash k8s/deploy.sh
```

`deploy.sh` handles everything in order:
- Refreshes the ECR pull secret
- Deploys PostgreSQL + runs DB migrations
- Deploys backend + frontend
- Waits for all pods to be Ready

---

## Update Workflow (after every code change)

**Local machine:**
```bash
bash k8s/build-and-push.sh
```
Builds both images, tags with git SHA, pushes to ECR, updates deployment YAMLs, commits and pushes to git automatically.

**Control-plane:**
```bash
cd kubernetes-3tier-app && git pull
kubectl rollout restart deployment/bmi-backend  -n bmi-app
kubectl rollout restart deployment/bmi-frontend -n bmi-app
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
kubectl get pods -n bmi-app                      # pod status
kubectl logs -n bmi-app deploy/bmi-backend       # backend logs
kubectl logs -n bmi-app deploy/bmi-frontend      # frontend logs
kubectl describe pod -n bmi-app <pod-name>       # debug a pod
bash k8s/setup-ecr-secret.sh                    # manually refresh ECR token
```

---

## Reference

| Item | Value |
|---|---|
| App URL | http://13.127.88.162:30080 |
| ECR Registry | 388779989543.dkr.ecr.ap-south-1.amazonaws.com |
| Kubernetes namespace | bmi-app |
| DB data path (worker-1) | /data/postgres |
| ECR token lifetime | 12 hours (auto-refreshed by `deploy.sh`) |
| Secrets committed to git | ❌ Never — apply manually on cluster |

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, Hogarth Worldwide  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
