# Deploying a Flask App on AWS EKS with Terraform

## What i built — and why every piece exists

This is the story of deploying a production-grade Flask application on Amazon EKS, wired end-to-end with Terraform for infrastructure and Kubernetes for workload management. What looks simple on the surface — "run a Python app on AWS" — turns out to be a journey through VPC networking, IAM identity federation, container orchestration, and the subtle art of knowing which tool owns which resource.

---

## The architecture

```
Internet → ALB (port 80) → EKS Nodes (private subnets) → Flask pods (port 5000)
```

Traffic enters through an Application Load Balancer sitting in public subnets. The ALB forwards requests to pods running in private subnets. The pods never talk to the internet directly — outbound traffic routes through a NAT Gateway. The entire lifecycle of pod IP registration into the ALB Target Group is handled dynamically by the AWS Load Balancer Controller running inside the cluster.

---

## The application

A minimal Flask app — two routes, one port:

```python
from flask import Flask
app = Flask(__name__)

@app.route("/health")
def health():
    return {"status": "healthy"}, 200

@app.route("/")
def index():
    return {"message": "GDS Mission Dashboard running"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

The `/health` route matters more than it seems. Every health check in the system — the ALB, the Kubernetes readiness probe, the liveness probe — hits this endpoint. If it returns 200, the pod receives traffic. If it stops, Kubernetes restarts it and the ALB drains the connection.

---

## Project structure

```
gds-project/
├── app/
│   ├── app.py              ← Flask app (port 5000)
│   └── Dockerfile
├── terraform/
│   ├── main.tf             ← Provider + required_providers
│   ├── variables.tf        ← Input variables
│   ├── vpc.tf              ← VPC, subnets, IGW, NAT, routes, security groups
│   ├── iam.tf              ← EKS roles, IRSA, ECR repository
│   ├── eks.tf              ← EKS cluster + managed node group
│   └── outputs.tf          ← ECR URL, kubectl command, push commands
├── k8s/
│   └── manifests.yaml      ← Deployment, Service (ClusterIP), Ingress
└── RUNBOOK.md
```

The split is intentional. Terraform owns static infrastructure — things that exist before any pod runs. Kubernetes owns dynamic workload resources — things that change as pods come and go.

---

## The Terraform / Kubernetes boundary

This is the most important architectural decision in the project, and it's worth explaining clearly.

**Terraform owns:**
- VPC, subnets, internet gateway, NAT gateway, route tables
- Security groups
- EKS cluster and managed node group
- IAM roles for the cluster, nodes, and the Load Balancer Controller
- ECR repository

**Kubernetes owns:**
- The ALB, Target Group, and Listener (created dynamically by the AWS Load Balancer Controller)
- Pod scheduling and lifecycle (Deployment)
- Internal routing (Service ClusterIP)
- Routing rules (Ingress)

The AWS Load Balancer Controller is the bridge between these two worlds. It runs as a pod inside the cluster, watches for Ingress resources, and calls the AWS API to create and manage the ALB. This is called **Mode 1** — fully dynamic — as opposed to creating the ALB in Terraform and attaching to it from Kubernetes.

The controller's ability to call AWS APIs comes from **IRSA** (IAM Roles for Service Accounts), which federates Kubernetes service account identity with AWS IAM using the cluster's OIDC provider. No hardcoded credentials, no instance profile abuse — the pod assumes its IAM role via a short-lived web identity token.

---

## Networking — the full picture

### VPC layout

```
10.0.0.0/16
├── 10.0.1.0/24  public-1a   ← ALB, NAT Gateway
├── 10.0.2.0/24  public-1b   ← ALB (multi-AZ)
├── 10.0.3.0/24  private-1a  ← EKS nodes and pods
└── 10.0.4.0/24  private-1b  ← EKS nodes and pods
```

Subnets carry tags that the Load Balancer Controller reads to know where to place the ALB:

```hcl
"kubernetes.io/role/elb"          = "1"   # public subnets → internet-facing ALB
"kubernetes.io/role/internal-elb" = "1"   # private subnets → node placement
```

Without these tags, the controller cannot discover which subnets to use and the ALB creation fails silently.

### Security group design

Two security groups, each with a specific job:

**`alb_sg`** — accepts HTTP on port 80 from the internet (`0.0.0.0/0`). This is intentional and correct for a public-facing load balancer.

**`node_sg`** — accepts traffic on port 5000 only from `alb_sg` (not from the VPC CIDR). This means only the ALB can reach Flask pods, even though both live in the same VPC. It also allows node-to-node traffic (required by Kubernetes networking) and port 10250 from the EKS control plane security group (required for kubelet API access).

The key detail: using `security_groups = [aws_security_group.alb_sg.id]` as the source instead of a CIDR range means the rule follows the security group — not an IP range that might grow to include other resources.

### Port translation

```
Internet → ALB :80 → Service :80 → Pod :5000
                          ↑
                    targetPort: 5000
```

The Service acts as a port translator. External traffic arrives on port 80; the Service rewrites the destination to port 5000 before forwarding to the pod. This keeps the ALB configuration standard while letting Flask use its native port.

---

## IAM — the invisible glue

Three IAM roles make the cluster work:

**`eks_cluster_role`** — assumed by the EKS control plane. Attaches `AmazonEKSClusterPolicy`, which gives AWS permission to manage ENIs, load balancers, and security groups on behalf of the cluster.

**`eks_node_role`** — assumed by EC2 instances in the node group. Attaches three policies: `AmazonEKSWorkerNodePolicy` (allows nodes to register with the cluster), `AmazonEKS_CNI_Policy` (allows the VPC CNI to assign pod IPs), and `AmazonEC2ContainerRegistryReadOnly` (allows nodes to pull images from ECR).

**`lb_controller_role`** — assumed by the Load Balancer Controller pod via IRSA. This is the most interesting one. It uses `AssumeRoleWithWebIdentity` with a condition that pins the trust to a specific Kubernetes service account:

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.us-east-1.amazonaws.com/id/XXXX:sub":
      "system:serviceaccount:kube-system:aws-load-balancer-controller"
  }
}
```

If the service account name doesn't match exactly, the pod gets `Unauthorized` and crashes on startup — which is exactly what happened during this project. The fix was ensuring the Helm install created the service account (`serviceAccount.create=true`) and that the role ARN annotation was present on it.

---

## Kubernetes manifests

### Deployment

Three replicas of the Flask container, with health probes on `/health:5000`:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 10
  periodSeconds: 5
```

The readiness probe gates traffic. A pod only enters the load balancer rotation after `/health` returns 200. The liveness probe restarts pods that pass readiness but later stop responding.

### Service (ClusterIP)

Internal only. The Ingress controller uses this to resolve pod IPs:

```yaml
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 5000
```

### Ingress

The resource the Load Balancer Controller watches. Critical annotations:

```yaml
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/healthcheck-path: /health
  alb.ingress.kubernetes.io/healthcheck-port: "5000"
spec:
  ingressClassName: alb      # ← must be a spec field, not an annotation
```

The `ingressClassName` placement caused a significant debugging session. When set as an annotation (`kubernetes.io/ingress.class: alb`), the controller ignores the Ingress entirely — the ALB is never created and the ADDRESS field stays empty. It must be `spec.ingressClassName`.

---

## Issues encountered and resolved

**EKS 1.29 AMI no longer available** — AWS stopped publishing AMIs for versions entering end-of-extended-support. EKS only allows single minor version upgrades, so upgrading from 1.29 to 1.32 requires stepping through 1.30 → 1.31 → 1.32, or destroying and recreating the cluster. For a dev environment, recreating is faster.

**Security group protocol error** — `protocol = "-1"` (all protocols) requires `from_port = 0, to_port = 0`. Specifying a port range with protocol `-1` is contradictory and AWS rejects it. The rule for node-to-node traffic was corrected to use `0/0` on the ports.

**Load Balancer Controller VPC ID** — the controller attempts to auto-detect the VPC ID from EC2 instance metadata on startup. In some cluster configurations this times out. The fix is to pass `--set vpcId=<vpc-id>` explicitly in the Helm install command.

**IRSA misconfiguration** — the controller pod crashed with `Unauthorized` because the Helm upgrade used `serviceAccount.create=false` before the service account had been created. The service account had no IAM role annotation, so web identity token exchange failed. The fix was a clean uninstall and reinstall with `serviceAccount.create=true`.

**Ingress not reconciled** — the ALB ADDRESS field stayed empty despite the controller running cleanly. The Ingress had `kubernetes.io/ingress.class: alb` as an annotation but not `spec.ingressClassName: alb`. The controller only processes Ingresses with the correct spec field set.

---

## What Mode 1 means in practice

The project uses what can be called Mode 1: the AWS Load Balancer Controller creates and manages the ALB, Target Group, and Listener entirely from Kubernetes. Terraform has no ALB resources.

The alternative (Mode 2) is to create the ALB in Terraform and pass its ARN to the controller via annotations. Mode 2 is useful when the ALB ARN must exist before Kubernetes is deployed — for example, to set a DNS record in Route 53 via Terraform, or when organizational policy requires all AWS resources to be declared in IaC.

For this project, Mode 1 is the right choice. The ALB lifecycle is tied to the Ingress resource. When the Ingress is deleted, the ALB is deleted. When the Ingress is updated with new routing rules, the ALB listener rules update. No Terraform state drift is possible because Terraform doesn't know the ALB exists.

---

## The state management lesson

One important operational insight emerged from this project: resources created outside Terraform — whether by the CLI, the console, or by Kubernetes controllers — are invisible to Terraform's state.

The ALB created by the Load Balancer Controller is intentionally invisible. The boundary is clear: Terraform owns the cluster, Kubernetes owns the workload infrastructure. Neither side touches the other's resources.

The rule to follow: if Terraform created it, manage it with Terraform. If Kubernetes created it, manage it with kubectl or Helm. If the CLI created it, either import it with `terraform import` or reference it with a `data` source. Never mix without a clear boundary.

---

## Verification

```bash
ALB=$(kubectl get ingress mission-dashboard-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$ALB/
# {"message": "GDS Mission Dashboard running"}

curl http://$ALB/health
# {"status": "healthy"}
```

---

## What comes next

The natural extensions to this setup are HTTPS termination at the ALB (ACM certificate + port 443 on the ALB security group + HTTPS listener), a Route 53 record pointing a real domain at the ALB DNS name, cluster autoscaling to handle traffic spikes, and tightening the node egress rule to only allow traffic to specific AWS service endpoints rather than the open internet.

The foundation is solid. The networking is correct, the IAM is least-privilege, and the workload is observable through health probes and Kubernetes events.
