# CI/CD GitOps Platform on AWS EKS

A fully automated DevSecOps pipeline on AWS — from code push to a live, monitored web app
with real user accounts in Amazon RDS. No secrets in Git, no persistent credentials. Every
component is provisioned by Terraform, configured by Ansible, and driven by Git, with build,
deploy and alert notifications in Slack.

→ [Architecture](docs/architecture.md) · [Redeploy runbook](docs/redeploy-runbook.md) · [Monitoring & Slack](docs/monitoring-setup.md)

---

## What This Project Demonstrates

| Capability | Implementation |
|---|---|
| Infrastructure as Code | Terraform — two independent stacks (CI platform + EKS cluster), remote state in S3 with native locking |
| Configuration Management | Ansible — idempotent, EC2 dynamic inventory, zero manual SSH for config |
| Secrets Management | AWS SSM Parameter Store — KMS-encrypted, IAM-scoped, zero secrets in Git |
| CI Pipeline | Jenkins with JCasC — fully declarative, self-configuring on every deploy |
| Code Quality Gate | SonarQube 26.1 + PostgreSQL — blocks pipeline on quality failures |
| Container Security | Trivy image scan (report-only: findings are logged, the build continues) |
| GitOps Delivery | ArgoCD v3.5.2 — continuous reconciliation of EKS cluster from Git |
| Container Orchestration | AWS EKS (Kubernetes 1.32) — private node subnets, NAT egress |
| Database | Amazon RDS PostgreSQL 16 (db.t4g.micro) — private subnets, reachable only from the cluster |
| Observability | Prometheus, Grafana, Alertmanager (kube-prometheus-stack via ArgoCD) + blackbox uptime and database-health probes |
| ChatOps | Slack: Jenkins build results, ArgoCD deploy events, Alertmanager alerts with separate "Recovered" messages |
| Application | Java JSP/Servlet app with register, login, account, delete and community pages; PBKDF2 password hashing, CSRF protection, login lockout |
| Automated Token Lifecycle | SonarQube token generated via API, stored in SSM, injected into Jenkins — no manual steps |

---

## How It Works

```
Code push → GitHub webhook → Jenkins Pipeline
  → Maven build + unit tests → SonarQube quality gate → Trivy scan → Docker push
  → Kustomize updates manifest repo                         (Slack: #ci-builds)
    → ArgoCD detects commit → deploys to EKS                (Slack: #deployments)
      → app pods ↔ Amazon RDS PostgreSQL (private subnets)
      → Prometheus probes the site and /health → Alertmanager (Slack: #alerts)
```

Two independent AWS VPCs. One Git-driven delivery loop. Full architecture in
[docs/architecture.md](docs/architecture.md).

---

## Repository Layout

```
cicd-eks-pipeline/
├── terraform/
│   ├── jenkins/       CI platform — Jenkins, SonarQube, Ansible control node
│   └── eks/           EKS cluster, node group, NAT, bootstrap host, RDS PostgreSQL
│
├── ansible/
│   ├── playbooks/     site.yml → master → sonarqube → agent → summary
│   └── roles/         jenkins_master · jenkins_agent · sonarqube · common
│
├── docker/
│   └── jenkins-local/ Local smoke test — validates plugins and JCasC before AWS deploy
│
├── scripts/
│   ├── bootstrap-state-bucket.ps1  Creates the S3 bucket for Terraform state (once)
│   ├── setup-secrets.example.ps1   Prompts for, validates and stores all SSM secrets; go/no-go check
│   │                               (copy to setup-secrets.ps1, which is git-ignored, for your own defaults)
│   ├── bootstrap-argocd.ps1        Installs ArgoCD post-EKS, retrieves password, opens UI
│   └── sync-k8s-secrets.ps1        Creates all Kubernetes Secrets (DB, Grafana, Slack) from SSM
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
private subnets, NAT Gateway, a bootstrap EC2 with `kubectl`, `helm`, and the
ArgoCD CLI pre-installed, and an RDS PostgreSQL 16 instance reachable only from the
cluster's private subnets.

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
0.  Create the state bucket (once)    .\scripts\bootstrap-state-bucket.ps1
1.  Store SSM parameters              .\scripts\setup-secrets.example.ps1
2.  Deploy CI platform                terraform init -backend-config="../backend.hcl"
                                      terraform apply  (terraform/jenkins/)
3.  Run Ansible                       ansible-playbook playbooks/site.yml
4.  Complete Jenkins setup wizard     one-time, manual
5.  Deploy EKS cluster                terraform init -backend-config="../backend.hcl"
                                      terraform apply  (terraform/eks/)
6.  Install ArgoCD                    .\scripts\bootstrap-argocd.ps1
6b. Create Kubernetes secrets         .\scripts\sync-k8s-secrets.ps1  (DB, Grafana, Slack)
7.  Deploy apps + monitoring          kubectl apply -f argocd/*.yaml  (manifests repo)
8.  Configure GitHub webhook          App repo → Settings → Webhooks
9.  Push a commit                     Full pipeline runs automatically
```

Redeploying after a teardown: [docs/redeploy-runbook.md](docs/redeploy-runbook.md) (exact order, checks, and troubleshooting).

---

## SSM Parameters

All must exist before `terraform apply`; `scripts/setup-secrets.example.ps1` creates and
validates them. The last two are created automatically by Ansible.

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
| `/jenkins/slack-token` | SecureString | Slack bot token (Jenkins + ArgoCD notifications) |
| `/monitoring/slack-webhook-url` | SecureString | Slack webhook for Alertmanager alerts |
| `/monitoring/grafana-admin-password` | SecureString | Grafana admin login |
| `/app/db-password` | SecureString | RDS PostgreSQL password for the app |
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

**Database alert after a redeploy.**
After a rebuild, the cluster first ran an image built *before* the database code existed,
so `/health` returned 404 and the `RegisterAppDatabaseDown` alert fired. Fixed with unique
image tags (`<version>-<build>-<git commit>`, so a rebuilt Jenkins can't overwrite an old tag)
and a written [redeploy order](docs/redeploy-runbook.md) that syncs secrets before the app.

**Windows PowerShell 5.1 argument passing.**
Inline arrays passed to helper functions were joined into a single word, and short flags
like `-o` were swallowed as PowerShell parameters. The scripts now build argument lists
explicitly and use simple `$args` functions for native commands.

**PEM encoding on Windows.**
PowerShell's `>` redirection writes UTF-16 LE with BOM. OpenSSH rejects UTF-16 PEM
files on both Windows and Linux. Fixed by using `[System.IO.File]::WriteAllText` with
explicit ASCII encoding and `icacls` with the full `DOMAIN\user` format for permissions.

---

## Tooling

The helper scripts in `scripts/` are **PowerShell** (Windows PowerShell 5.1+ or
PowerShell 7+) because this platform was built and operated from Windows. They need the
AWS CLI v2, Terraform, Git and kubectl on `PATH`. Ansible runs on the control node in AWS,
so it is not needed locally. On macOS or Linux, install PowerShell 7 (`pwsh`) to run the
scripts unchanged.

---

## Design Decisions and Cost Trade-offs

This platform runs in a **sandbox AWS account that is torn down weekly**, so many choices
favour low cost and easy rebuilds over production-grade resilience. Each is deliberate and
easy to change:

| Decision | Why | Production alternative |
|---|---|---|
| No Elastic IPs for Jenkins | EIPs are billed while held, and the account is rebuilt weekly | EIP or a DNS name, so the GitHub webhook URL never changes |
| Single NAT Gateway | One NAT costs half of two | One NAT per AZ for resilience |
| Classic Load Balancer from a `LoadBalancer` Service | No extra controller to install or pay for | AWS Load Balancer Controller + ALB Ingress |
| Plain HTTP | A domain and certificate cost money | HTTPS via ACM on an ALB, or CloudFront in front of the LB (free default certificate) |
| RDS `db.t4g.micro`, single AZ, no final snapshot | Smallest instance; data is disposable in a lab | Multi-AZ, deletion protection, snapshots, longer backups |
| Prometheus without persistent volumes | Avoids EBS volumes and the CSI driver | EBS-backed storage or Amazon Managed Prometheus |
| S3 state bucket without versioning | Kept minimal | Turn versioning on (`-EnableVersioning`) |
| Public subnets for CI instances | No second NAT or VPN needed | Private subnets behind a bastion/SSM or VPN |
| Trivy report-only | Builds aren't blocked by base-image CVEs in a lab | `--exit-code 1` for HIGH/CRITICAL |

Rough running cost while everything is up: about USD 0.50/hour (EKS control plane, NAT
Gateway, EC2 instances, RDS). Tear down when not in use: see the
[redeploy runbook](docs/redeploy-runbook.md).

---

## Human-in-the-Loop Checkpoints

Most of the platform is automated, but a few steps are **deliberately manual**: they are
the points where a person should confirm something before the next stage runs.

| Checkpoint | Why a human |
|---|---|
| `setup-secrets` READY / NOT READY | Confirms the right AWS account and valid credentials before anything is created |
| `terraform plan` before every `apply` | Review exactly what will be created or destroyed |
| Jenkins setup wizard and admin user | The first administrator is chosen by a person, not a script |
| GitHub webhook URL | Connecting a repo to a CI server is an explicit trust decision |
| Applying the ArgoCD Applications | Decides which environments go live |
| Deleting the app before `terraform destroy` | Prevents orphaned load balancers and makes data loss intentional |

---

## Adapting This for Your Own App

Everything project-specific lives in a few places:

1. **Your app repo** needs a `Dockerfile` and a `Jenkinsfile` like
   [eddie-register-app](https://github.com/EddieByte/eddie-register-app)'s (build → scan →
   push → update manifests). Change the `APP_NAME`, `DOCKER_USER` and `GITHUB_USER` parameters.
2. **A manifests repo** with Kustomize `base/` + `overlays/` and the ArgoCD Applications,
   like [eddie-register-app-manifests](https://github.com/EddieByte/eddie-register-app-manifests).
3. **This repo:** set `key_name`, `ami_id` and `allowed_ssh_cidrs` in both
   `terraform.tfvars` files, the cluster and database names in `terraform/eks/variables.tf`,
   and `jenkins_slack_team_domain` in `ansible/playbooks/master.yml`.
4. **Secrets:** run `scripts/setup-secrets.example.ps1` (it asks for everything and stores
   nothing in Git), then `bootstrap-state-bucket.ps1` once per AWS account.

---

## Tech Stack

| Layer | Tool | Version |
|---|---|---|
| IaC | Terraform + AWS provider | >= 1.10 / ~> 5.0 (S3 backend, native locking) |
| Config Management | Ansible + amazon.aws | pip / >= 6.0.0 |
| CI | Jenkins (Debian, apt-pinned) | 2.580+ |
| Code Quality | SonarQube Community | 26.1.0.118079 |
| Container Scanning | Trivy | 0.76.2 |
| Kubernetes | AWS EKS | 1.32 |
| GitOps | ArgoCD | v3.5.2 |
| Build | Maven + OpenJDK | 3.9.9 / 21 |
| Database | Amazon RDS PostgreSQL | 16 |
| Monitoring | kube-prometheus-stack / blackbox exporter | 92.21.2 / 11.21.1 |
| Notifications | Slack (Jenkins plugin, ArgoCD Notifications, Alertmanager) | — |

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

Delete the app first: its Classic Load Balancer is created by Kubernetes, not Terraform,
and would otherwise block VPC deletion. `terraform destroy` in `terraform/eks` also
removes the RDS database **and every registered account**. Full commands and checks:
[docs/redeploy-runbook.md](docs/redeploy-runbook.md#teardown-reverse-order).

```powershell
kubectl delete -f argocd/application-dev.yaml          # in the manifests repo
kubectl delete namespace eddie-register-app-dev        # removes the load balancer
Set-Location terraform\eks    ; terraform destroy        # EKS + RDS
Set-Location ..\jenkins       ; terraform destroy        # CI servers
```

SSM parameters are not managed by Terraform — delete them manually if no longer needed.

The S3 state bucket is kept on purpose: it is tiny, costs almost nothing, and holds the
record of what Terraform created. Only delete it after both stacks are destroyed and you
are finished with the project:

```powershell
aws s3 rb s3://cicd-eks-pipeline-tfstate-<account-id> --force
```

---

## Production Hardening

This is a personal lab configuration. Before any production use:

- Restrict SSH CIDRs to known IPs in both `terraform.tfvars` files
- Restrict SonarQube port 9000 or place behind an authenticated load balancer
- Lock down EKS public endpoint CIDRs
- Enable versioning on the Terraform state bucket (`bootstrap-state-bucket.ps1 -EnableVersioning`)
- Use private subnets for CI platform EC2 instances
- Serve the app over HTTPS (domain + ACM certificate on an ALB); it is plain HTTP today
- RDS: enable deletion protection, a final snapshot, longer backups and Multi-AZ
- Make Trivy a blocking gate (`--exit-code 1`) and add a promotion step for prod

---

## Related Repositories

| Repository | Purpose |
|---|---|
| `eddie-register-app` | Application source — Java JSP/Servlet WAR on Tomcat 9, Jenkinsfile |
| `eddie-register-app-manifests` | Kubernetes manifests — Kustomize base + overlays |
| `cicd-eks-pipeline` *(this repo)* | Infrastructure, CI config, GitOps platform |
