# Platform Architecture

Two independent AWS VPCs, one Git-driven delivery loop. The CI platform builds, scans,
and publishes. The EKS platform runs and reconciles.

---

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  CI Platform VPC — 10.10.0.0/16                                         │
│                                                                         │
│  ┌─────────────────┐  SSH  ┌─────────────────┐  HTTP  ┌─────────────┐  │
│  │  Jenkins Master │──────▶│  Jenkins Agent  │───────▶│  SonarQube  │  │
│  │  JCasC-managed  │       │  Docker CE       │        │  PostgreSQL │  │
│  │  Port 8080      │◀──────│  Trivy · OWASP  │        │  Port 9000  │  │
│  └─────────────────┘  wbhk └─────────────────┘        └─────────────┘  │
│                                      │                                   │
│  ┌─────────────────────────────────┐ │ docker push / kustomize update   │
│  │  Ansible Control Node           │ ▼                                   │
│  │  Self-bootstrapped by Terraform │ DockerHub · GitHub Manifest Repo   │
│  └─────────────────────────────────┘                                     │
└─────────────────────────────────────────────────────────────────────────┘
                                        │ ArgoCD detects manifest commit
┌─────────────────────────────────────────────────────────────────────────┐
│  EKS VPC — 10.20.0.0/16                                                 │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Private Subnets — EKS Managed Node Group (2× t3.medium)         │  │
│  │  ArgoCD · kube-system · application workloads                    │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                          │ NAT Gateway egress (image pull)               │
│  AWS Load Balancer ◀─────┘ provisioned by cloud-controller-manager      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## CI Platform (terraform/jenkins)

| Component | Spec | Role |
|---|---|---|
| Jenkins Master | t3.medium, Port 8080 | Orchestrates all builds — zero executors on controller |
| Jenkins Agent | t3.medium, Docker CE | Runs every build stage — Maven, Trivy, OWASP, Docker |
| SonarQube | t3.medium, Port 9000, PostgreSQL | Static analysis + quality gate callback to Jenkins |
| Ansible Control Node | t3.micro | Provisions all three above — bootstrapped by Terraform userdata |

All instances are in public subnets (lab trade-off). Master ↔ Agent communication uses
private IPs. The two stacks share no VPC peering.

---

## EKS Platform (terraform/eks)

| Component | Spec | Role |
|---|---|---|
| EKS Control Plane | Kubernetes 1.32, public+private endpoint | Managed by AWS |
| Managed Node Group | 2× t3.medium, private subnets | Worker nodes — no public IPs |
| NAT Gateway | Elastic IP, us-east-1a | Outbound internet for private nodes |
| EKS Bootstrap EC2 | t3.medium, public subnet | kubectl/helm/argocd CLI host |
| ArgoCD | v3.5.2, `argocd` namespace | GitOps controller — watches manifest repo |
| AWS Load Balancer | Classic ELB | Provisioned by Kubernetes for the application service |

---

## Secrets Flow

All secrets originate in **AWS SSM Parameter Store** and flow into services at runtime.
Nothing sensitive is in Git, Terraform variables, or environment variables that persist
beyond the running process.

```
Operator → SSM (before terraform apply)
  ↓
Terraform userdata → fetches /jenkins/ssh-private-key at boot
  ↓
Ansible master role → fetches all Jenkins credentials from SSM
  → writes /etc/jenkins/jcas.env (0640 root:jenkins)
  → renders /var/lib/jenkins/casc_configs/jenkins.yaml
  → systemd loads jcas.env as EnvironmentFile
  → JCasC substitutes ${ENV_VAR} references at JVM startup

Ansible sonarqube role → generates analysis token via SonarQube API
  → writes token to /jenkins/sonarqube-token in SSM
  → second Ansible pass on master picks it up automatically

Ansible agent role → pulls /jenkins/master-public-key from SSM
  → writes to /home/jenkins/.ssh/authorized_keys
```

Each EC2 instance has a scoped IAM instance profile — no long-lived AWS keys anywhere.

---

## GitOps Delivery Loop

```
1. Developer pushes to app repo
2. GitHub webhook → Jenkins :8080/github-webhook/
3. Jenkins pipeline on Agent:
   ├── Maven build + unit tests
   ├── SonarQube analysis (blocks on quality gate failure)
   ├── Docker build + Trivy scan
   ├── OWASP dependency check
   ├── Docker push to DockerHub
   └── kustomize edit set image → commit + push to manifest repo
4. ArgoCD detects manifest repo commit (within 3 minutes)
5. ArgoCD applies updated Deployment to EKS
6. EKS nodes pull new image from DockerHub via NAT
7. AWS Load Balancer routes traffic to updated pods
```

---

## Network Topology

### CI Platform VPC — 10.10.0.0/16

| Subnet | CIDR | AZ | Instances |
|---|---|---|---|
| public_a | 10.10.1.0/24 | us-east-1a | Jenkins Master, SonarQube |
| public_b | 10.10.2.0/24 | us-east-1b | Jenkins Agent, Control Node |

Security groups follow least-privilege: SSH restricted to operator CIDRs, service ports
(8080, 9000) open to `0.0.0.0/0` for lab access (noted for production hardening).

### EKS VPC — 10.20.0.0/16

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| public_a | 10.20.1.0/24 | us-east-1a | NAT Gateway, Bootstrap EC2 |
| public_b | 10.20.2.0/24 | us-east-1b | Bootstrap EC2 (HA) |
| private_a | 10.20.11.0/24 | us-east-1a | EKS worker node |
| private_b | 10.20.12.0/24 | us-east-1b | EKS worker node |

Worker nodes have no public IPs. All egress (DockerHub pulls, AWS API calls) exits via
the single NAT Gateway in public_a.
