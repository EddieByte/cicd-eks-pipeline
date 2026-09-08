# eddie-register-app CI/CD & GitOps Documentation

This repository captures the implementation notes and operational lessons from building an AWS EKS GitOps pipeline with Jenkins, Argo CD, SonarQube, and container security scanning for the eddie-register-app project.

## Key Docs

- `docs/gitops-cicd-architecture.md` — architecture, GitOps philosophy, CI/CD flow, and lifecycle guidance.
- `docs/eks-gitops.md` — EKS deployment troubleshooting and cluster issues.
- `docs/jenkins-setup-notes.md` — Jenkins installation, pipeline behavior, and security integration.
- `docs/sonarqube-postgres.md` — SonarQube + PostgreSQL deployment notes and recovery steps.
- `docs/terraform-ansible-setup-notes.md` — Terraform IaC and Ansible configuration management setup, issues, and architecture decisions.

---

## Infrastructure Deployment Walkthrough

### Prerequisites

Before running `terraform apply`, ensure the following are in place:

1. AWS CLI configured (`aws configure`)
2. Terraform installed
3. Your EC2 private key file and key pair name
4. The following SSM parameters stored in your selected AWS region:

```bash
AWS_REGION="<aws-region>"
SSH_KEY_PATH="<path-to-private-key>"
SSH_PARAMETER_NAME="<ssm-parameter-for-private-key>"
SONAR_DB_USERNAME_PARAMETER="<ssm-parameter-for-db-username>"
SONAR_DB_PASSWORD_PARAMETER="<ssm-parameter-for-db-password>"

# EC2 private key — used by Ansible control node to SSH into instances
aws ssm put-parameter --name "$SSH_PARAMETER_NAME" \
  --value "$(cat "$SSH_KEY_PATH")" --type SecureString --region "$AWS_REGION"

# SonarQube PostgreSQL credentials
aws ssm put-parameter --name "$SONAR_DB_USERNAME_PARAMETER" \
  --value "<database-username>" --type String --region "$AWS_REGION"

aws ssm put-parameter --name "$SONAR_DB_PASSWORD_PARAMETER" \
  --value "<strong-database-password>" --type SecureString --region "$AWS_REGION"
```

5. Code pushed to your Git repository (the control node clones it at boot)
6. The AWS key pair named by `key_name` must exist in the selected region and match the private key stored in `ssm_ssh_key_path`.

---

### What `terraform apply` Does — Step by Step

```
Step 1 — Jenkins Master EC2 created
  - Ubuntu 22.04, t3.medium, 15GB encrypted gp3
  - Hostname set to Jenkins-Master
  - IAM role attached with SSM write permission
  - Python3 and awscli installed via userdata

Step 2 — Jenkins Agent EC2 created (depends on master)
  - Same specs as master
  - Hostname set to Jenkins-Agent
  - Python3 and awscli installed via userdata

Step 3 — SonarQube EC2 created
  - Ubuntu 22.04, t3.medium, 15GB encrypted gp3
  - Hostname set to SonarQube
  - Port 9000 open on security group
  - IAM role attached with SSM read permission

Step 4 — Ansible Control Node EC2 created (depends on master, agent, sonarqube)
  - Ubuntu 22.04, t3.micro
  - Hostname set to Ansible-Control-Node
  - Ansible, Git, and awscli installed via userdata
  - Pulls the configured private key from SSM and places it at the configured SSH path
  - Clones the configured Git repository into the configured repository directory

Step 5 — Ansible control node bootstrapped
  - The control node clones this repository
  - The AWS EC2 dynamic inventory discovers running instances by Project tag
  - The control node receives the private key from SSM at ~/.ssh/labs_kp.pem
```

---

### Outputs After Apply

| Output | Description |
|---|---|
| `jenkins_url` | Jenkins UI — `http://<ip>:8080` |
| `jenkins_master_public_ip` | Jenkins Master public IP |
| `jenkins_master_private_ip` | Jenkins Master private IP |
| `jenkins_agent_public_ip` | Jenkins Agent public IP |
| `jenkins_agent_private_ip` | Jenkins Agent private IP — use when registering node in Jenkins |
| `sonarqube_url` | SonarQube UI — `http://<ip>:9000` |
| `control_node_public_ip` | Ansible Control Node public IP |
| `control_node_ssh` | SSH command to access the control node |

---

### Run Ansible From The Control Node

Terraform creates the control node and installs Ansible automatically. After Terraform finishes, use the output command or:

```bash
ssh -i ~/.ssh/labs_kp.pem ubuntu@<control_node_public_ip>
cd /home/ubuntu/cicd-eks-pipeline/ansible
ansible-galaxy collection install -r /home/ubuntu/cicd-eks-pipeline/ansible/requirements.yml
ansible-playbook playbooks/site.yml
```

`site.yml` runs these stages in order:

1. `master.yml` installs Jenkins and creates the master-to-agent SSH key.
2. `sonarqube.yml` configures SonarQube and PostgreSQL.
3. `agent.yml` installs Docker and authorizes the Jenkins master key.
4. `summary.yml` verifies the master-agent connection and writes `summary.yml` and `summary.md` at the repository root.

The run is safe to repeat. Existing services and configuration are brought to the declared state. If Jenkins has already completed initial setup, the one-time password file will be absent; the summary records that fact and provides the command that works during first-run setup.

View the generated reports:

```bash
cd /home/ubuntu/cicd-eks-pipeline
less summary.md
less summary.yml
```

For a preflight check that makes no changes:

```bash
cd /home/ubuntu/cicd-eks-pipeline/ansible
ansible-playbook --syntax-check playbooks/site.yml
ansible all -m ping
```

To refresh the control node checkout before running again:

```bash
cd /home/ubuntu/cicd-eks-pipeline
git pull --ff-only origin main
cd ansible
ansible-playbook playbooks/site.yml
```

**Jenkins first-run login:**
1. Open the `jenkins_url` output in a browser.
2. During first setup, run `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` on the Jenkins master.
3. Install suggested plugins and create the permanent administrator credentials.
4. After setup, the initial password file may no longer exist. Use the permanent credentials instead.
5. The generated summary confirms whether the master-agent SSH connection is working.

**Step 3 — Create the Infrastructure Configuration Pipeline:**
1. `Dashboard → New Item → Pipeline → Name: infrastructure-config`
2. Under Pipeline, select `Pipeline script from SCM`
3. Set SCM to Git, repo URL: `<repository-url>`
4. Set Script Path to: `jenkins/infrastructure-config/Jenkinsfile`
5. Update `CONTROL_NODE_IP` in the Jenkinsfile with `control_node_private_ip` from Terraform outputs
6. Commit and push, then run the job

This job runs once after Jenkins is set up. It configures the agent and SonarQube via Ansible.
The Jenkinsfile is at `jenkins/infrastructure-config/Jenkinsfile`.

**Step 4 — Configure SonarQube:**
1. Open `sonarqube_url` in browser and sign in with the credentials configured for your SonarQube instance
2. Generate a global analysis token
3. Add token to Jenkins credentials as `Secret text`
4. Configure SonarQube webhook pointing back to Jenkins:
   `http://<jenkins_master_ip>:8080/sonarqube-webhook/`

---

### Teardown

```bash
cd <terraform-jenkins-directory>
terraform destroy -auto-approve
```

This removes all EC2 instances, security groups, and IAM roles. SSM parameters are not destroyed — delete them manually if needed:

```bash
aws ssm delete-parameter --name "<ssm-parameter-for-private-key>" --region "<aws-region>"
aws ssm delete-parameter --name "<ssm-parameter-for-master-public-key>" --region "<aws-region>"
aws ssm delete-parameter --name "<ssm-parameter-for-db-username>" --region "<aws-region>"
aws ssm delete-parameter --name "<ssm-parameter-for-db-password>" --region "<aws-region>"
```

> **Production Notes:**
> - Restrict `allowed_ssh_cidrs` to your IP (`x.x.x.x/32`)
> - Restrict SonarQube port 9000 to known CIDRs or place behind an ALB
> - Migrate Terraform state to S3 + DynamoDB for team environments
> - Use private subnets with NAT gateways for EKS clusters instead of the default VPC's public subnets
