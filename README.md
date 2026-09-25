# CI/CD GitOps Platform on AWS EKS

A fully automated DevSecOps pipeline on AWS — from code push to live application, with
no manual secret entry and no persistent credential management. Every component is
provisioned by Terraform, configured by Ansible, and driven by Git.

→ [Architecture overview](docs/architecture.md) · [Deployment guide](docs/deployment-guide.md)

---

## What This Project Demonstrates

| Capability | Implementation |
|---|---|
| Infrastructure as Code | Terraform — two independent stacks (CI platform + EKS cluster) |
| Configuration Management | Ansible — idempotent, EC2 dynamic inventory, zero manual SSH for config |
| Secrets Management | AWS SSM Parameter Store — KMS-encrypted, IAM-scoped, zero secrets in Git |
| CI Pipeline | Jenkins with JCasC — fully declarative, self-configuring on every deploy |
| Code Quality Gate | SonarQube 26.1 + PostgreSQL — blocks pipeline on quality failures |
| Container Security | Trivy (vulnerability scan) + OWASP Dependency Check |
| GitOps Delivery | ArgoCD v3.5.2 — continuous reconciliation of EKS cluster from Git |
| Container Orchestration | AWS EKS (Kubernetes 1.32) — private node subnets, NAT egress |
| Automated Token Lifecycle | SonarQube token generated via API, stored in SSM, injected into Jenkins — no manual steps |

---

## How It Works

```
Code push → GitHub webhook → Jenkins Pipeline
  → Maven build → SonarQube quality gate → Trivy scan → Docker push
  → Kustomize updates manifest repo
    → ArgoCD detects commit → deploys to EKS → live application
```

Two independent AWS VPCs. One Git-driven delivery loop. Full architecture in
[docs/architecture.md](docs/architecture.md).

---

## Repository Layout

```
cicd-eks-pipeline/
├── terraform/
│   ├── jenkins/       CI platform — Jenkins, SonarQube, Ansible control node
│   └── eks/           EKS cluster — control plane, node group, NAT, bootstrap host
│
├── ansible/
│   ├── playbooks/     site.yml → master → sonarqube → agent → summary
│   └── roles/         jenkins_master · jenkins_agent · sonarqube · common
│
├── docker/
│   └── jenkins-local/ Local smoke test — validates plugins and JCasC before AWS deploy
│
├── scripts/
│   └── bootstrap-argocd.ps1  Installs ArgoCD post-EKS, retrieves password, opens UI
│
├── jenkins/
│   └── infrastructure-config/Jenkinsfile  Re-runs Ansible from Jenkins
│
└── docs/              Architecture, deployment guides, credentials reference, lessons learned
```

**terraform/jenkins** provisions four EC2 instances (Jenkins Master, Agent, SonarQube,
Ansible Control Node) with scoped IAM roles and a VPC. The control node bootstraps
itself from SSM at Terraform boot time.

**terraform/eks** provisions a separate VPC, EKS cluster with a managed node group in
private subnets, NAT Gateway, and a bootstrap EC2 with `kubectl`, `helm`, and the
ArgoCD CLI pre-installed.

**ansible** configures all EC2 instances. The `jenkins_master` role fetches credentials
from SSM and renders them into a JCasC configuration that Jenkins loads at startup. The
`sonarqube` role generates an analysis token via the SonarQube API and writes it back to
SSM automatically. All tasks that touch secrets use `no_log: true`.

**docker/jenkins-local** is a self-contained Docker Compose stack for pre-flight
validation. Run it before every cloud deployment to catch plugin compatibility issues
early.

---

## Deployment Overview

> All SSM parameters must be stored **before** `terraform apply`. The control node
> fetches `/jenkins/ssh-private-key` at boot — if it doesn't exist, the bootstrap fails.

```
1.  Store SSM parameters              aws ssm put-parameter ...
2.  Deploy CI platform                terraform apply  (terraform/jenkins/)
3.  Run Ansible                       ansible-playbook playbooks/site.yml
4.  Complete Jenkins setup wizard     one-time, manual
5.  Deploy EKS cluster                terraform apply  (terraform/eks/)
6.  Install ArgoCD                    .\scripts\bootstrap-argocd.ps1
7.  Connect manifest repository       ArgoCD UI → Settings → Repositories
8.  Configure GitHub webhook          App repo → Settings → Webhooks
9.  Push a commit                     Full pipeline runs automatically
```

Full step-by-step commands with verification checks: [docs/deployment-guide.md](docs/deployment-guide.md)

---

## SSM Parameters

All must exist before `terraform apply`. The last two are created automatically by Ansible.

| Parameter | Type | Purpose |
|---|---|---|
| `/jenkins/ssh-private-key` | SecureString | EC2 key — control node + EKS bootstrap |
| `/jenkins/github-username` | String | GitHub SCM credential |
| `/jenkins/github-token` | SecureString | GitHub PAT |
| `/jenkins/dockerhub-username` | String | DockerHub image push |
| `/jenkins/dockerhub-token` | SecureString | DockerHub access token |
| `/sonarqube/db-username` | String | PostgreSQL user |
| `/sonarqube/db-password` | SecureString | PostgreSQL password |
| `/sonarqube/admin-password` | SecureString | SonarQube API authentication |
| `/jenkins/master-public-key` | String | ← Created by Ansible |
| `/jenkins/sonarqube-token` | SecureString | ← Created by Ansible |

---

## Notable Challenges

**JCasC + plugin version mismatch.**
The `fileOnMaster` SSH credential source was silently removed in an updated SSH
Credentials plugin bundled with Jenkins 2.581 (apt delivered a newer build than the
pinned version). Resolved by embedding SSH private key content directly into the JCasC
YAML as block scalars via Ansible's `slurp` module.

**Multiline PEM keys in systemd EnvironmentFiles.**
Systemd `EnvironmentFile` does not support multiline values. Routing SSH keys through
`jcas.env` as escaped strings caused OpenSSH to reject them. Moved key injection
directly into the rendered `jenkins.yaml` instead.

**ELB blocks VPC deletion on `terraform destroy`.**
Kubernetes creates an AWS Classic Load Balancer and a matching security group for
`LoadBalancer` services. Terraform cannot delete the VPC while these exist. Fix:
delete the ArgoCD `Application` resource first — Kubernetes then deprovisions the ELB
cleanly before Terraform runs.

**SSM parameter race condition at boot.**
The control node userdata uses `set -euo pipefail`. If `/jenkins/ssh-private-key` does
not exist when the instance boots, the entire script aborts silently. Documented as a
hard prerequisite — SSM parameters must be created before `terraform apply`.

**PEM encoding on Windows.**
PowerShell's `>` redirection writes UTF-16 LE with BOM. OpenSSH rejects UTF-16 PEM
files on both Windows and Linux. Fixed by using `[System.IO.File]::WriteAllText` with
explicit ASCII encoding and `icacls` with the full `DOMAIN\user` format for permissions.

---

## Tech Stack

| Layer | Tool | Version |
|---|---|---|
| IaC | Terraform + AWS provider | >= 1.5 / ~> 5.0 |
| Config Management | Ansible + amazon.aws | pip / >= 6.0.0 |
| CI | Jenkins (Debian, apt-pinned) | 2.580+ |
| Code Quality | SonarQube Community | 26.1.0.118079 |
| Container Scanning | Trivy | 0.69.3 |
| Kubernetes | AWS EKS | 1.32 |
| GitOps | ArgoCD | v3.5.2 |
| Build | Maven + OpenJDK | 3.9.9 / 21 |

---

## Local Smoke Test

Validates the plugin manifest and JCasC config before touching AWS:

```bash
cd docker/jenkins-local
cp .env.example .env   # fill in throwaway values
docker compose build --no-cache && docker compose up -d
```

Open `http://localhost:8080`. See `docker/jenkins-local/README.md` for the full
validation checklist.

---

## Teardown

Delete the ArgoCD application first — this lets Kubernetes deprovision the AWS Load
Balancer before Terraform removes the VPC.

```powershell
kubectl delete application <app-name> -n argocd
kubectl get services -n <app-namespace> -w    # wait for EXTERNAL-IP to clear

Set-Location terraform\eks    && terraform destroy
Set-Location ..\jenkins       && terraform destroy
```

SSM parameters are not managed by Terraform — delete them manually if no longer needed.

---

## Production Hardening

This is a personal lab configuration. Before any production use:

- Restrict SSH CIDRs to known IPs in both `terraform.tfvars` files
- Restrict SonarQube port 9000 or place behind an authenticated load balancer
- Lock down EKS public endpoint CIDRs
- Move Terraform state to S3 + DynamoDB backend
- Use private subnets for CI platform EC2 instances

---

## Related Repositories

| Repository | Purpose |
|---|---|
| `eddie-register-app` | Application source — Java/React, Jenkinsfile |
| `eddie-register-app-manifests` | Kubernetes manifests — Kustomize base + overlays |
| `cicd-eks-pipeline` *(this repo)* | Infrastructure, CI config, GitOps platform |
