# Argo CD Setup: Local Workstation and EKS Bootstrap Server

This document explains how Argo CD is installed for the current EKS design, how to use the EKS bootstrap server as an administration host, and why the repository currently runs the automation from the local workstation.

## Architecture in One Sentence

Argo CD runs **inside the EKS cluster** as Kubernetes workloads. The local workstation and the EKS bootstrap EC2 instance are only clients that use `kubectl` or the Argo CD CLI to administer those workloads.

```text
Local workstation or EKS bootstrap server
        |
        | kubectl / AWS CLI / Argo CD CLI
        v
EKS Kubernetes API
        |
        v
Argo CD pods in the argocd namespace
        |
        v
Application manifest repository
```

Argo CD is therefore not installed as a Linux service on the bootstrap EC2 host.

## What Terraform Creates

The EKS Terraform stack creates:

- EKS control plane
- Managed worker node group
- VPC, public subnets, private subnets, NAT Gateway, and routes
- EKS bootstrap EC2 instance
- IAM role for the bootstrap instance
- SSM parameter containing the kubeconfig command

The relevant bootstrap user-data script is:

```text
terraform/eks/modules/bootstrap/userdata.sh
```

It installs these client tools on the bootstrap host:

- AWS CLI
- Terraform
- `kubectl`
- Helm
- Argo CD CLI

It also retrieves the EC2 SSH private key from SSM into:

```text
/home/ubuntu/.ssh/labs_kp.pem
```

The user-data script does **not** install the Argo CD server. The Argo CD server is installed into EKS with Kubernetes resources.

## What the Local PowerShell Script Does

The post-Terraform script is:

```text
scripts/bootstrap-argocd.ps1
```

Run it from the repository root after `terraform apply`:

```powershell
.\scripts\bootstrap-argocd.ps1 `
  -TerraformDirectory .\terraform\eks `
  -Region us-east-1 `
  -ClusterName eddie-register-app-eks `
  -ArgoCdVersion v3.5.2 `
  -LocalPort 8081
```

The script performs these controlled steps:

1. Verifies that Terraform, AWS CLI, and `kubectl` are installed.
2. Reads the cluster name from Terraform output unless `-ClusterName` is supplied.
3. Reads the region from AWS CLI configuration unless `-Region` is supplied.
4. Requires a pinned Argo CD semantic version.
5. Checks that the local port is available.
6. Updates the local kubeconfig with `aws eks update-kubeconfig`.
7. Waits for every EKS node to become `Ready`.
8. Creates the `argocd` namespace if needed.
9. Applies the pinned Argo CD manifest with server-side apply.
10. Waits for all Argo CD deployments and the application controller.
11. Retrieves the initial admin password from the Kubernetes secret.
12. Copies the password to the local clipboard without writing it to disk.
13. Starts a local port-forward to the Argo CD service.
14. Opens the local HTTPS login page unless `-SkipBrowser` is used.

The script does not run Terraform, store passwords in Git, or expose the Argo CD service publicly.

## Why Run the Script Locally?

Running it locally is the preferred path for this repository because:

### 1. Local access already works

The cluster creator's AWS identity can already update kubeconfig and access the EKS API. The local workstation successfully ran:

```powershell
kubectl get nodes
kubectl get pods --all-namespaces
```

No extra bootstrap-host access configuration is needed for this path.

### 2. The script is designed for Windows

The script uses PowerShell features that are intended for the local workstation:

- `Set-Clipboard` to copy the admin password
- `Start-Process` to launch `kubectl port-forward`
- `Start-Process` to open the browser
- `Get-NetTCPConnection` to protect the selected local port
- Reading the local Terraform output directory

These behaviors do not map directly to the Ubuntu bootstrap host.

### 3. The UI remains private

The script forwards the Argo CD service to:

```text
https://localhost:8081
```

The Argo CD UI is not exposed through a public AWS load balancer. The port-forward exists only on the local machine and can be stopped when finished.

### 4. Secrets stay on the operator workstation

The temporary Argo CD admin password is copied to the local clipboard and is not printed or saved by the script. Running from the bootstrap host would require a different secure handling method.

### 5. Terraform output is local

The script reads `cluster_name` from the Terraform working directory. The bootstrap host does not automatically contain the Terraform state or repository checkout used by the local script.

## When to Use the EKS Bootstrap Server

Use the bootstrap server when you want a persistent Linux administration host inside AWS, or when the local workstation cannot reach the EKS API.

It already has the client tools installed by user data and can use the EC2 instance role to call AWS APIs.

The Terraform output provides the SSH command:

```powershell
terraform -chdir=.\terraform\eks output -raw bootstrap_ssh_command
```

For the current environment, the equivalent command is:

```powershell
ssh -i "$HOME\.ssh\labs_kp.pem" ubuntu@<bootstrap-public-ip>
```

## Bootstrap Server Prerequisite: EKS Access

Installing the client tools on the bootstrap host is not enough. The bootstrap IAM role must also be authorized to access Kubernetes through EKS.

The current Terraform creates the IAM role but does not create an EKS access entry for it. The cluster creator can therefore access the cluster locally while the bootstrap role may receive an authorization error.

From the local workstation, identify the role and cluster:

```powershell
$accountId = aws sts get-caller-identity --query Account --output text
$clusterName = terraform -chdir=.\terraform\eks output -raw cluster_name
$region = aws configure get region
```

Check existing access entries:

```powershell
aws eks list-access-entries `
  --cluster-name $clusterName `
  --region $region
```

Create an access entry for the bootstrap role if it does not already exist:

```powershell
$bootstrapRole = "arn:aws:iam::$accountId:role/eks-bootstrap-role"

aws eks create-access-entry `
  --cluster-name $clusterName `
  --principal-arn $bootstrapRole `
  --type STANDARD `
  --region $region
```

Grant the required access policy. Use cluster-admin only for a controlled lab; use a narrower policy for production:

```powershell
aws eks associate-access-policy `
  --cluster-name $clusterName `
  --principal-arn $bootstrapRole `
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy `
  --access-scope type=cluster `
  --region $region
```

Do not run `create-access-entry` repeatedly. If the entry already exists, only verify or update its policy.

## Set Up and Use the Bootstrap Server

### 1. Connect over SSH

```powershell
ssh -i "$HOME\.ssh\labs_kp.pem" ubuntu@<bootstrap-public-ip>
```

### 2. Confirm the tools

```bash
aws --version
terraform version
kubectl version --client
helm version
argocd version --client
```

### 3. Configure kubeconfig

Run the command generated by Terraform:

```bash
aws eks update-kubeconfig \
  --region <aws-region> \
  --name <cluster-name>
```

For the current environment:

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name eddie-register-app-eks
```

The kubeconfig is written for the `ubuntu` user at:

```text
/home/ubuntu/.kube/config
```

### 4. Verify Kubernetes access

```bash
kubectl config current-context
kubectl get nodes
kubectl get pods --all-namespaces
```

The bootstrap host is ready to administer the cluster only when these commands succeed.

### 5. Install or refresh Argo CD from the bootstrap host

The following commands install Argo CD into the cluster. They do not install Argo CD on the EC2 operating system:

```bash
kubectl create namespace argocd \
  --dry-run=client \
  -o yaml | kubectl apply -f -

kubectl apply --server-side \
  --namespace argocd \
  --filename https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml
```

Wait for readiness:

```bash
kubectl wait \
  --for=condition=Available \
  --timeout=10m \
  deployment --all \
  --namespace argocd

kubectl rollout status \
  statefulset/argocd-application-controller \
  --namespace argocd \
  --timeout=10m

kubectl get pods --namespace argocd
```

### 6. Retrieve the initial password on the bootstrap host

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

This prints the password in the SSH terminal. Avoid shell history capture and do not paste it into Git or shared logs.

### 7. Access the Argo CD UI from the bootstrap host

Start a port-forward on the bootstrap host:

```bash
kubectl port-forward \
  --namespace argocd \
  service/argocd-server \
  8080:443
```

This binds the UI to the bootstrap host's loopback interface. It is not automatically reachable from your local browser.

From a second local PowerShell terminal, create an SSH tunnel through the bootstrap host:

```powershell
ssh -i "$HOME\.ssh\labs_kp.pem" `
  -N `
  -L 8080:127.0.0.1:8080 `
  ubuntu@<bootstrap-public-ip>
```

Then open locally:

```text
https://localhost:8080
```

Keep both the Kubernetes port-forward and SSH tunnel running while using the UI.

## Local versus Bootstrap Workflow

| Task | Local workstation | Bootstrap server |
|---|---|---|
| Run Terraform | Yes | Optional, not required by this workflow |
| Run `kubectl` | Yes | Yes, after EKS access is granted |
| Install Argo CD into EKS | Yes | Yes |
| Read local Terraform output | Yes | No, unless the repository/state is copied there |
| Copy password to clipboard | Yes | No, normally terminal output only |
| Open browser automatically | Yes | No, use an SSH tunnel |
| Keep admin access private | Local port-forward | Kubernetes port-forward plus SSH tunnel |

## Recommended Operating Model

For this repository, use the local workstation as the default Argo CD administration point:

```text
terraform apply
  -> scripts/bootstrap-argocd.ps1
  -> local https://localhost:8081
  -> Argo CD Application
  -> manifest repository sync
```

Use the bootstrap server as a fallback or persistent AWS-side administration host:

```text
ssh to bootstrap server
  -> grant EKS access to its IAM role
  -> aws eks update-kubeconfig
  -> kubectl administers Argo CD in EKS
  -> SSH tunnel provides local browser access
```

This keeps infrastructure provisioning, cluster administration, and application deployment clearly separated:

- Terraform owns AWS infrastructure.
- The local PowerShell script owns repeatable post-Terraform initialization.
- The bootstrap server provides optional Linux-based operations access.
- Argo CD owns Kubernetes application reconciliation from Git.

## Security and Reproducibility Notes

- The current bootstrap user data downloads some tools using latest-version URLs. Pin these versions before production use.
- The current EKS API endpoint allows public access from `0.0.0.0/0`. Restrict `public_access_cidrs` before production use.
- The bootstrap IAM policy is intentionally broad for the lab. Reduce it to the exact AWS actions required.
- Use a pinned Argo CD version rather than the `stable` URL.
- Change the initial Argo CD admin password immediately.
- Prefer an Argo CD repository deploy key or least-privilege token for private manifest repositories.
- Never commit kubeconfig files, admin passwords, Git tokens, deploy keys, or Kubernetes secret values.
