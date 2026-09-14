# eddie-register-app CI/CD Pipeline — AWS Cloud Deployment

This repository provisions and configures a full GitOps-based DevOps platform on AWS for the
`eddie-register-app` project. The stack mirrors the local Docker smoke test in structure and
behaviour — the goal is the same seamless, automated experience, just running on real AWS
infrastructure instead of containers on your machine.

The local Docker harness in `docker/jenkins-local/` was used to validate plugin compatibility
and JCasC configuration before cloud deployment. If you have not run those smoke tests yet,
start there. This README assumes they passed.

---

## Architecture at a Glance

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE 1 — CI Platform  (terraform/jenkins + Ansible)                   │
│                                                                         │
│  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐   │
│  │  Jenkins Master  │   │  Jenkins Agent   │   │   SonarQube      │   │
│  │  t3.medium       │──▶│  t3.medium       │   │  t3.medium       │   │
│  │  Port 8080       │   │  Docker CE       │   │  Port 9000       │   │
│  └──────────────────┘   └──────────────────┘   │  PostgreSQL      │   │
│                                                 └──────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Ansible Control Node  (t3.micro)                                │  │
│  │  Bootstrapped at Terraform apply — no manual SSH required        │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE 2 — EKS Platform  (terraform/eks)                                │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  EKS Cluster (eddie-register-app-eks, Kubernetes 1.32)           │  │
│  │  2× t3.medium managed nodes in private subnets, NAT egress       │  │
│  │  ArgoCD installed post-apply (scripts/bootstrap-argocd.ps1)      │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────┐                                                   │
│  │  EKS Bootstrap   │  kubectl, helm, argocd CLI, Terraform, AWS CLI   │
│  │  t3.medium       │  SSH access via labs_kp key                       │
│  └──────────────────┘                                                   │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  ONGOING — GitOps Loop                                                  │
│                                                                         │
│  Code push → Jenkins Pipeline → SonarQube → Trivy → OWASP →           │
│  Docker Build/Push → Kustomize manifest update → ArgoCD sync → EKS     │
└─────────────────────────────────────────────────────────────────────────┘
```

All secrets flow exclusively through **AWS SSM Parameter Store**. Nothing sensitive appears
in Git, in Terraform variables, or in any Ansible template that touches disk without
`no_log: true` and correct file permissions.

---

## Versions

| Component | Version |
|---|---|
| Jenkins | 2.580 (Debian package, pinned via apt) |
| SonarQube | 26.1.0.118079 (Community Edition) |
| Java | 21 (OpenJDK 21 JDK) |
| Maven | 3.9.9 (auto-installed by Jenkins tool config) |
| PostgreSQL | Default Ubuntu 22.04 package (SonarQube backend) |
| Kubernetes | 1.32 (EKS managed) |
| ArgoCD | v3.5.2 (pinned in bootstrap script) |
| Terraform AWS Provider | ~> 5.0 |
| Ansible amazon.aws collection | >= 6.0.0 |

These must match the versions in the local smoke test. If you upgrade one, upgrade the other
and re-validate with `docker compose build --no-cache && docker compose up -d`.

---

## What This Automates

| Concern | How It Is Handled |
|---|---|
| Secret storage | AWS SSM Parameter Store (SecureString, KMS-encrypted) |
| Jenkins install | Ansible role — GPG key, apt repo, pinned version |
| Plugin install | `jenkins-plugin-manager-2.13.2.jar` — bulk install from `plugins.txt` |
| Jenkins configuration | JCasC — agent node, tools, SonarQube, credentials, pipeline job |
| SSH keypair | Ansible generates ed25519 keypair on master, pushes public key to SSM, agent pulls it |
| SonarQube install | Ansible role — PostgreSQL backend, credentials from SSM, systemd service |
| Agent Docker install | Ansible role — Docker CE, jenkins user, authorized_keys from SSM |
| EKS cluster | Terraform — control plane, OIDC, managed node group, NAT Gateway |
| ArgoCD install | `scripts/bootstrap-argocd.ps1` — server-side apply, waits for readiness |

## What Stays Manual

| Step | Why |
|---|---|
| Create SSM parameters | You supply the secrets — never the pipeline |
| Jenkins first-run wizard | One-time account creation — JCasC handles everything after |
| SonarQube token generation | Requires a running SonarQube UI session |
| Store SonarQube token in SSM, rerun master.yml | Two-pass token injection (SonarQube must be running first) |
| SonarQube webhook | Configured in SonarQube UI after token is ready |
| ArgoCD manifest repo connection | Requires your repository credentials |
| ArgoCD Application resource | Lives in the separate manifest repository |

---

## Prerequisites

On your deployment workstation:

- AWS CLI (`aws configure` — `us-east-1`)
- Terraform >= 1.5
- OpenSSH client
- PowerShell (for the ArgoCD bootstrap script)
- An AWS account with permissions for EC2, VPC, IAM, EKS, NAT Gateway, SSM, and KMS

Verify your identity before starting:

```powershell
aws sts get-caller-identity
aws configure get region
```

Confirm the `labs_kp` EC2 key pair exists in `us-east-1` and you have the matching `.pem` file:

```powershell
aws ec2 describe-key-pairs --key-names labs_kp --region us-east-1
```

---

## Step 1 — Create SSM Parameters

Store all secrets in SSM **before** running `terraform apply`. Terraform and Ansible read
these values at runtime. Never put them in `.tfvars`, Ansible vars, or anywhere in Git.

```powershell
$region  = "us-east-1"
$keyPath = "$HOME\.ssh\labs_kp.pem"

# EC2 private key — used by the Ansible control node and EKS bootstrap host
aws ssm put-parameter `
  --name "/jenkins/ssh-private-key" `
  --value (Get-Content $keyPath -Raw) `
  --type SecureString `
  --overwrite `
  --region $region

# SonarQube PostgreSQL credentials
aws ssm put-parameter `
  --name "/sonarqube/db-username" `
  --value "sonarqube" `
  --type String `
  --overwrite `
  --region $region

aws ssm put-parameter `
  --name "/sonarqube/db-password" `
  --value "<strong-password>" `
  --type SecureString `
  --overwrite `
  --region $region

# GitHub credentials — used by Jenkins JCasC for SCM and pipeline jobs
aws ssm put-parameter `
  --name "/jenkins/github-username" `
  --value "<your-github-username>" `
  --type String `
  --overwrite `
  --region $region

aws ssm put-parameter `
  --name "/jenkins/github-token" `
  --value "<your-github-pat>" `
  --type SecureString `
  --overwrite `
  --region $region
```

> `/jenkins/master-public-key` and `/jenkins/sonarqube-token` are created automatically
> during the Ansible run — do not pre-create them.

### All SSM Parameters Reference

| Parameter | Type | Created By | Purpose |
|---|---|---|---|
| `/jenkins/ssh-private-key` | SecureString | You (above) | Private key for control node and EKS bootstrap host |
| `/sonarqube/db-username` | String | You (above) | PostgreSQL username |
| `/sonarqube/db-password` | SecureString | You (above) | PostgreSQL password |
| `/jenkins/github-username` | String | You (above) | GitHub username for JCasC credential |
| `/jenkins/github-token` | SecureString | You (above) | GitHub PAT for JCasC credential |
| `/jenkins/master-public-key` | String | Ansible (master role) | Master SSH public key — read by agent role |
| `/jenkins/sonarqube-token` | SecureString | You (Step 6) | SonarQube analysis token for JCasC |

---

## Step 2 — Review Terraform Variables

Open `terraform/jenkins/terraform.tfvars` and `terraform/eks/terraform.tfvars`.

Restrict SSH access to your own IP before applying:

```hcl
allowed_ssh_cidrs = ["YOUR.PUBLIC.IP.ADDRESS/32"]
```

The default `0.0.0.0/0` is intentionally left open for disposable lab use only. Verify the
AMI ID is current for `us-east-1` — AMIs are region-specific and expire.

---

## Step 3 — Deploy the Jenkins/SonarQube Platform

```powershell
Set-Location terraform\jenkins
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

**What this creates:**

| Resource | Spec |
|---|---|
| VPC | 10.10.0.0/16, 2 public subnets, IGW |
| Jenkins Master EC2 | t3.medium, Ubuntu 22.04, 15 GB gp3 encrypted |
| Jenkins Agent EC2 | t3.medium, Ubuntu 22.04, 15 GB gp3 encrypted |
| SonarQube EC2 | t3.medium, Ubuntu 22.04, 15 GB gp3 encrypted |
| Ansible Control Node EC2 | t3.micro, Ubuntu 22.04, 15 GB gp3 encrypted |
| IAM roles | Per-instance, least-privilege SSM access |
| Security groups | SSH + service ports per instance |

The control node is the last resource created (`depends_on` master, agent, and SonarQube).
Its userdata bootstraps itself automatically:

1. Installs Python3, Git, Ansible, AWS CLI, boto3/botocore
2. Fetches `/jenkins/ssh-private-key` from SSM → `~/.ssh/labs_kp.pem` (chmod 600)
3. Clones `https://github.com/EddieByte/cicd-eks-pipeline` to `/home/ubuntu/cicd-eks-pipeline`
4. Runs `ansible-galaxy collection install -r requirements.yml`

**The control node is ready to run Ansible immediately after `terraform apply` finishes.
No manual SSH to any instance is required to reach this point.**

Record the outputs:

```powershell
terraform output
```

| Output | Description |
|---|---|
| `jenkins_url` | Jenkins UI — `http://<ip>:8080` |
| `jenkins_master_public_ip` | Jenkins Master public IP |
| `jenkins_master_private_ip` | Jenkins Master private IP |
| `jenkins_agent_public_ip` | Jenkins Agent public IP |
| `jenkins_agent_private_ip` | Jenkins Agent private IP |
| `sonarqube_url` | SonarQube UI — `http://<ip>:9000` |
| `control_node_public_ip` | Ansible Control Node public IP |
| `control_node_ssh` | Ready-to-paste SSH command |

---

## Step 4 — Run Ansible Configuration

SSH to the control node using the key you stored in SSM:

```powershell
ssh -i "$HOME\.ssh\labs_kp.pem" ubuntu@<control_node_public_ip>
```

The repository is already cloned and Ansible is already installed from userdata. Run the
playbooks:

```bash
cd /home/ubuntu/cicd-eks-pipeline/ansible

# Verify the inventory discovers all instances before running
ansible all -m ping

# Run the full site playbook
ansible-playbook playbooks/site.yml
```

`site.yml` runs four playbooks in order:

| Playbook | Target | What It Does |
|---|---|---|
| `master.yml` | Jenkins Master | Installs Jenkins, bulk-installs all plugins, renders JCasC config from SSM secrets, generates master SSH keypair, pushes public key to SSM |
| `sonarqube.yml` | SonarQube | Installs PostgreSQL, creates DB and user from SSM credentials, installs SonarQube, starts service |
| `agent.yml` | Jenkins Agent | Installs Docker CE, creates `jenkins` user, pulls master public key from SSM into `authorized_keys` |
| `summary.yml` | localhost | Verifies master→agent SSH, reads initial admin password, writes `summary.md` and `summary.yml` |

The run is idempotent — safe to repeat. Existing services are brought to declared state.

After the playbook completes, read the generated summary on the control node:

```bash
cd /home/ubuntu/cicd-eks-pipeline
less summary.md
```

It contains all connection info, URLs, and the master→agent connectivity result.

### Troubleshooting the Inventory

If `ansible all -m ping` finds no hosts, confirm the instances are running and tagged:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=eddie-register-app" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{Name:Tags[?Key=='Name']|[0].Value,IP:PublicIpAddress}" \
  --output table \
  --region us-east-1
```

The dynamic inventory groups by the `Name` tag. Expected groups:
`Jenkins_Master`, `Jenkins_Agent`, `SonarQube`, `Ansible_Control_Node`.

---

## Step 5 — Complete Jenkins First-Run Setup

Open the Jenkins URL from Terraform output: `http://<jenkins-master-public-ip>:8080`

Retrieve the initial administrator password:

```powershell
ssh -i "$HOME\.ssh\labs_kp.pem" ubuntu@<jenkins-master-public-ip> `
  "sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
```

Or read it from `summary.md` on the control node — it is recorded there if it existed at
playbook time.

1. Paste the password into the setup wizard.
2. Select **Install suggested plugins** (or skip — JCasC installs what is needed).
3. Create a permanent administrator account.

**After the wizard completes, JCasC takes over automatically.** On the first Jenkins start
after Ansible, the following are already configured without any UI interaction:

- The `Jenkins-Agent` node (SSH, using the agent's private IP from dynamic inventory)
- Maven 3.9.9 (auto-install) and Java 21 tool paths
- `sonarqube-server` integration (URL from Ansible vars)
- Credentials: `jenkins-agent-ssh`, `labs-kp`, `github` (from SSM via jcas.env)
- The `infrastructure-config` pipeline job (created via Job DSL)

Verify in **Manage Jenkins → Nodes** that `Jenkins-Agent` is **online**. If it shows
offline, check the node log — the most common cause is the agent not yet fully started.
Give it 2–3 minutes after the Ansible run and refresh.

---

## Step 6 — Configure SonarQube

Open `http://<sonarqube-public-ip>:9000`. Default login is `admin` / `admin` on first start.
SonarQube will require you to change the password immediately.

1. Complete the SonarQube setup wizard.
2. Go to **My Account → Security → Generate Tokens**.
3. Name it `jenkins-token`, type `User Token`, click **Generate**.
4. Copy the token — it is shown once only.
5. Store it in SSM:

```powershell
aws ssm put-parameter `
  --name "/jenkins/sonarqube-token" `
  --value "sqa_<your-token>" `
  --type SecureString `
  --overwrite `
  --region us-east-1
```

6. Re-run the Jenkins master playbook from the control node to inject the token into JCasC:

```bash
# On the control node
cd /home/ubuntu/cicd-eks-pipeline/ansible
ansible-playbook playbooks/master.yml
```

7. Configure the SonarQube webhook pointing back at Jenkins. In SonarQube:
   **Administration → Configuration → Webhooks → Create**

```
Name:  jenkins
URL:   http://<jenkins-master-public-ip>:8080/sonarqube-webhook/
```

After this, Jenkins Quality Gates will receive SonarQube callback results and the pipeline
can block on a failed quality gate.

---

## Step 7 — Run the Infrastructure-Config Pipeline

The `infrastructure-config` job was created by JCasC automatically. It keeps the control
node and Ansible configuration in sync with the repository.

In Jenkins, open the `infrastructure-config` pipeline and verify:

- `CONTROL_NODE_IP` matches `control_node_private_ip` from Terraform output.
- `SSH_CREDENTIAL_ID` is `labs-kp`.

Run the job once. It SSHes to the control node, does a `git pull --ff-only`, and runs
`ansible-playbook playbooks/site.yml`. This is the same as running the playbook manually —
it is just driven by Jenkins from now on.

---

## Step 8 — Deploy the EKS Cluster

The EKS stack has its own VPC and Terraform state, independent of the Jenkins stack.

```powershell
Set-Location terraform\eks
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

**What this creates:**

| Resource | Spec |
|---|---|
| VPC | 10.20.0.0/16, 2 public + 2 private subnets, NAT Gateway |
| EKS Cluster | `eddie-register-app-eks`, Kubernetes 1.32, public+private endpoint |
| OIDC provider | For IRSA (IAM Roles for Service Accounts) |
| EKS Managed Node Group | 2× t3.medium in private subnets (min 1, max 3) |
| EKS Bootstrap EC2 | t3.medium, public subnet, kubectl/helm/argocd CLI/terraform/awscli |
| SSM parameter | `/eks/eddie-register-app-eks/kubeconfig-command` |

The bootstrap EC2's userdata fetches `/jenkins/ssh-private-key` from SSM and installs all
client tools automatically — no manual setup required.

**t3.medium is the minimum viable node size.** t2.micro and t3.small are insufficient for
the EKS system pods and will OOM. Do not downsize.

Verify the cluster is reachable from your workstation:

```powershell
$clusterName = terraform output -raw cluster_name
aws eks update-kubeconfig --region us-east-1 --name $clusterName
kubectl get nodes
kubectl get pods --all-namespaces
```

All nodes must show `Ready` before proceeding.

---

## Step 9 — Install ArgoCD

Run the bootstrap script from the repository root. It is reusable and idempotent:

```powershell
.\scripts\bootstrap-argocd.ps1
```

The script does the following in order:

1. Reads the cluster name from `terraform output`
2. Updates your local kubeconfig
3. Waits for all EKS nodes to reach `Ready`
4. Creates the `argocd` namespace
5. Applies the pinned ArgoCD manifests using `--server-side` (required to avoid the 256 KB CRD annotation limit)
6. Waits for all ArgoCD deployments and the `argocd-application-controller` StatefulSet
7. Retrieves the initial admin password → copies to clipboard
8. Starts `kubectl port-forward service/argocd-server 8080:443 -n argocd` in the background
9. Opens `https://localhost:8080` in your browser

Useful overrides:

```powershell
.\scripts\bootstrap-argocd.ps1 `
  -TerraformDirectory .\terraform\eks `
  -Region us-east-1 `
  -ArgoCdVersion v3.5.2 `
  -LocalPort 8081
```

Stop the port-forward when done:

```powershell
Stop-Process -Id <port-forward-process-id>
```

The script does not store credentials, expose ArgoCD publicly, or run Terraform.

---

## Step 10 — Connect the Manifest Repository and Deploy

ArgoCD manages application deployment from a separate manifest repository. This repository
does not contain those manifests.

In the ArgoCD UI (`https://localhost:8080`, password from clipboard):

1. **Settings → Repositories → Connect Repo** — add your manifest repository URL and
   credentials.
2. **Applications → New App** — or apply the `Application` resource from your manifest
   repository directly:

```bash
kubectl apply -f argocd-application.yaml -n argocd
```

3. Verify the application is `Synced` and `Healthy`:

```bash
kubectl get applications -n argocd
kubectl get pods --all-namespaces
```

ArgoCD watches the manifest repository continuously. Every time the Jenkins application
pipeline updates the image tag (via Kustomize), ArgoCD detects the commit and reconciles
the EKS cluster automatically.

---

## Differences From the Local Smoke Test

| Concern | Local Docker (`docker/jenkins-local`) | Cloud (this repo) |
|---|---|---|
| Secret storage | `.env` file (local only, throwaway values) | AWS SSM Parameter Store (SecureString, KMS-encrypted) |
| Jenkins install | Docker image `jenkins/jenkins:lts-jdk21` | Debian package, pinned to `2.580` via apt |
| SonarQube database | H2 (embedded, smoke test only) | PostgreSQL (credentials from SSM) |
| Agent host | `jenkins-agent` (Docker service name) | EC2 private IP from dynamic inventory |
| Agent connectivity | Docker bridge network | SSH (master ed25519 keypair, public key via SSM) |
| JCasC secrets | `${ENV_VAR}` from `.env` loaded by Docker Compose | `${ENV_VAR}` from `/etc/jenkins/jcas.env` loaded by systemd |
| Controller executors | 2 (builds run on controller for local convenience) | 0 (all builds run on the agent node) |
| User password | Plaintext `clouduser/password` in `jenkins.yaml` | Admin account created via first-run wizard only |
| SonarQube token | Manual (UI → update `.env` → restart) | Automated via SSM → Ansible `master.yml` second pass |
| Kubernetes | None | EKS managed cluster (1.32) |
| CD | None | ArgoCD (GitOps, watches manifest repo) |

---

## What Each Directory Does

| Path | Purpose |
|---|---|
| `terraform/jenkins/` | Provisions the Jenkins/SonarQube/Ansible platform on EC2 |
| `terraform/eks/` | Provisions the EKS cluster, node group, NAT, and bootstrap host |
| `ansible/` | Configures all EC2 instances after Terraform creates them |
| `ansible/roles/jenkins_master/` | Jenkins install, plugin bulk-install, JCasC, SSH keypair |
| `ansible/roles/sonarqube/` | PostgreSQL, SonarQube install and service |
| `ansible/roles/jenkins_agent/` | Docker CE, jenkins user, authorized_keys |
| `ansible/roles/common/` | Java 21, dist-upgrade, conditional reboot |
| `ansible/inventory/aws_ec2.yml` | Dynamic EC2 inventory filtered by `Project=eddie-register-app` tag |
| `jenkins/infrastructure-config/Jenkinsfile` | Jenkins pipeline that runs Ansible from the control node |
| `scripts/bootstrap-argocd.ps1` | Post-Terraform ArgoCD install, waits for readiness, starts port-forward |
| `scripts/audit_dependencies.py` | Checks current vs. latest versions of Terraform providers, Ansible collections, SonarQube, and Jenkins |
| `docker/jenkins-local/` | Local Docker smoke test — validate before deploying to cloud |
| `docs/` | Architecture notes, setup guides, troubleshooting, and lessons learned |

---

## Credential Security Rules

These apply to the cloud deployment exactly as they apply to the local smoke test.

1. **Never commit secrets to Git.** SSM is the only secret store. `.tfvars` files contain
   paths to SSM parameters, not values.
2. **All secrets in `/etc/jenkins/jcas.env` are runtime-injected.** The file is `0640
   root:jenkins` and never appears in Git. Jenkins reads it as a systemd EnvironmentFile.
3. **`no_log: true` is set on every Ansible task that touches a secret value.** Playbook
   output never echoes a credential.
4. **IMDSv2 is enforced on all EC2 instances** (`http_tokens = required`). Userdata uses
   the token-based metadata fetch pattern.
5. **The `labs_kp.pem` private key never touches application code or playbooks directly.**
   It is fetched from SSM at runtime and written to disk with `chmod 600`. It is not baked
   into any AMI or image.
6. **Terraform state may contain sensitive outputs.** Use an S3 backend with encryption and
   state locking for anything beyond a personal lab.

---

## Verification Checklist

Before considering the deployment complete:

- [ ] `aws sts get-caller-identity` returns the expected account and region.
- [ ] All five pre-deployment SSM parameters exist in `us-east-1`.
- [ ] `terraform validate` passes in both `terraform/jenkins` and `terraform/eks`.
- [ ] `ansible all -m ping` succeeds from the control node.
- [ ] `ansible-playbook playbooks/site.yml` completes without failures.
- [ ] `summary.md` shows master→agent SSH as **connected**.
- [ ] Jenkins is accessible at `http://<jenkins-master>:8080` and the agent is **online**.
- [ ] SonarQube is accessible at `http://<sonarqube>:9000` and the PostgreSQL service is healthy.
- [ ] SonarQube token is stored in SSM and `master.yml` has been re-run to inject it.
- [ ] SonarQube webhook is configured and points to `http://<jenkins-master>:8080/sonarqube-webhook/`.
- [ ] `kubectl get nodes` shows all EKS nodes as `Ready`.
- [ ] ArgoCD pods are running in the `argocd` namespace.
- [ ] ArgoCD application is `Synced` and `Healthy`.
- [ ] The application is reachable through its Kubernetes service or ingress.

---

## Updating After Initial Deployment

To pull new configuration changes and reapply Ansible:

```bash
# On the control node
cd /home/ubuntu/cicd-eks-pipeline
git pull --ff-only origin main
cd ansible
ansible-playbook playbooks/site.yml
```

Or trigger the `infrastructure-config` Jenkins pipeline — it does the same thing from Jenkins.

For Terraform changes, always plan before applying:

```powershell
terraform fmt -check
terraform validate
terraform plan
```

---

## Teardown

Destroy the Jenkins stack:

```powershell
Set-Location terraform\jenkins
terraform destroy
```

Destroy the EKS stack separately:

```powershell
Set-Location terraform\eks
terraform destroy
```

SSM parameters are not destroyed by Terraform. Delete them manually when no longer needed:

```powershell
$region = "us-east-1"

@(
  "/jenkins/ssh-private-key",
  "/jenkins/master-public-key",
  "/jenkins/github-username",
  "/jenkins/github-token",
  "/jenkins/sonarqube-token",
  "/sonarqube/db-username",
  "/sonarqube/db-password"
) | ForEach-Object {
  aws ssm delete-parameter --name $_ --region $region
  Write-Host "Deleted $_"
}
```

---

## Production Hardening

This repository is configured for a personal lab environment. Before using it in a shared
or production context:

- Restrict `allowed_ssh_cidrs` to your IP (`x.x.x.x/32`) in both `terraform.tfvars` files.
- Restrict SonarQube port 9000 to known CIDRs or place it behind an authenticated ALB.
- Restrict EKS public access CIDRs from `0.0.0.0/0` to your IP.
- Move Terraform state to an encrypted S3 backend with DynamoDB locking.
- Narrow the EKS bootstrap IAM policy — the current policy is broad for lab convenience.
- Pin all tool versions in bootstrap scripts (ArgoCD CLI, kubectl) instead of fetching `latest`.
- Add EBS volume snapshots for Jenkins home and SonarQube PostgreSQL data.
- Use a separate AWS account or isolated VPC for production workloads.

---

## Reference Documentation

| Doc | What It Covers |
|---|---|
| `docker/jenkins-local/README.md` | Local smoke test — validate plugins and JCasC before cloud deployment |
| `docs/deployment-guide.md` | Step-by-step deployment reference with all commands |
| `docs/gitops-cicd-architecture.md` | Architecture decisions, GitOps philosophy, pipeline design |
| `docs/jenkins-automation-setup.md` | JCasC automation details, SSM parameter reference, troubleshooting |
| `docs/jenkins-credentials-reference.md` | All Jenkins credential IDs, types, and their sources |
| `docs/jenkins-setup-notes.md` | Lessons learned: GPG key rotation, Java version, Trivy Docker API fix |
| `docs/argocd-bootstrap-server.md` | ArgoCD setup options — local workstation vs. EKS bootstrap host |
| `docs/argocd-next-steps.md` | Post-EKS: manifest repo connection, Application YAML, sync verification |
| `docs/eks-gitops.md` | EKS troubleshooting — node sizing, CRD annotation limits, VPC cleanup |
| `docs/sonarqube-postgres.md` | SonarQube PostgreSQL recovery and emergency password reset |
| `docs/terraform-ansible-setup-notes.md` | IaC decisions, IMDSv2 pattern, PowerShell compatibility notes |
