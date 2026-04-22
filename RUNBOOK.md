# GDS Mission — Deployment Runbook

## Project structure
```
gds-project/
├── app/
│   ├── app.py          ← Flask app (port 5000)
│   └── Dockerfile
├── terraform/
│   ├── main.tf         ← Provider + Terraform block
│   ├── variables.tf    ← All input variables
│   ├── vpc.tf          ← VPC, subnets, IGW, NAT, routes, SGs
│   ├── iam.tf          ← Cluster role, node role, IRSA, ECR
│   ├── eks.tf          ← EKS cluster + node group
│   └── outputs.tf      ← Useful values after apply
├── k8s/
│   └── manifests.yaml  ← Deployment, Service, Ingress
└── RUNBOOK.md
```

---

## Step 1 — Download the LB Controller IAM policy
```bash
curl -o terraform/lb_controller_iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

---

## Step 2 — Apply Terraform
```bash
cd terraform
terraform init
terraform apply -var="aws_account_id=<YOUR_ACCOUNT_ID>"
```
Copy the outputs — you'll need them in the next steps.

---

## Step 3 — Point kubectl at the cluster
```bash
# Terraform prints this exact command as the configure_kubectl output
aws eks update-kubeconfig --region eu-central-1 --name gds-mission-cluster
kubectl get nodes   # should show 2 nodes in Ready state
```

---

## Step 4 — Install AWS Load Balancer Controller via Helm
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=gds-mission-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<lb_controller_role_arn output>
  --set vpcId=$(terraform output -raw vpc_id)

# Verify the controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller
```

---

## Step 5 — Build and push the Flask image
```bash
# Terraform prints these exact commands as the ecr_push_commands output
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <ecr_repository_url>

docker build -t gds-app ./app
docker tag  gds-app:latest <ecr_repository_url>:latest
docker push <ecr_repository_url>:latest
```

---

## Step 6 — Update the image in manifests.yaml
Replace the placeholder in k8s/manifests.yaml:
```yaml
image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/gds-app:latest
# ↓
image: <ecr_repository_url>:latest   # paste the Terraform output here
```

---

## Step 7 — Apply Kubernetes manifests
```bash
kubectl apply -f k8s/manifests.yaml

# Watch rollout
kubectl rollout status deployment/mission-dashboard

# The LB Controller will create the ALB — takes ~90 seconds
kubectl get ingress mission-dashboard-ingress
# Look for the ADDRESS column — that's your ALB DNS name
```

---

## Step 8 — Verify
```bash
ALB=$(kubectl get ingress mission-dashboard-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$ALB/          # → {"message": "GDS Mission Dashboard running"}
curl http://$ALB/health    # → {"status": "healthy"}
```

---

## Port map (end to end)
```
Internet → ALB :80 → Service :80 → Pod :5000 (Flask)
                       ↑
              targetPort: 5000 in Service
              healthcheck port: 5000 in Ingress annotation
```
