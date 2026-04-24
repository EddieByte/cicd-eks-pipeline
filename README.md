# DevPulse CI/CD & GitOps Documentation

This repository captures the implementation notes and operational lessons from building an AWS EKS GitOps pipeline with Jenkins, Argo CD, SonarQube, and container security scanning.

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
3. `labs_kp.pem` at `C:\Users\<you>\.ssh\labs_kp.pem`
4. The following SSM parameters stored in `us-east-1`:

```bash
# EC2 private key — used by Ansible control node to SSH into instances
aws ssm put-parameter --name "/jenkins/ssh-private-key" \
  --value "$(cat ~/.ssh/labs_kp.pem)" --type SecureString --region us-east-1

# SonarQube PostgreSQL credentials
aws ssm put-parameter --name "/sonarqube/db-username" \
  --value "sonar" --type String --region us-east-1

aws ssm put-parameter --name "/sonarqube/db-password" \
  --value "<your-strong-password>" --type SecureString --region us-east-1
```

5. Code pushed to GitHub (control node clones this repo at boot)

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
  - Pulls labs_kp.pem from SSM → placed at ~/.ssh/labs_kp.pem
  - Clones this GitHub repo → /home/ubuntu/cicd-eks-pipeline

Step 5 — Ansible inventory generated (hosts.ini)
  - Terraform writes public IPs of all instances into
    ansible/inventory/hosts.ini
    (file is gitignored — generated fresh on every apply)
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

### Post-Deploy Manual Steps

**Step 1 — Bootstrap Jenkins Master (run once from control node):**

Before accessing the Jenkins UI, run the master playbook from the control node to install Jenkins:

```bash
ssh -i ~/.ssh/labs_kp.pem ubuntu@<control_node_public_ip>
cd /home/ubuntu/cicd-eks-pipeline/ansible
ansible-playbook -i inventory/hosts.ini \
  --private-key ~/.ssh/labs_kp.pem \
  -e @group_vars/all.yml \
  playbooks/master.yml
```

**Step 2 — Unlock Jenkins:**
1. Open `jenkins_url` in browser
2. Unlock Jenkins using the initial admin password:
   ```bash
   ssh -i ~/.ssh/labs_kp.pem ubuntu@<jenkins_master_public_ip>
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```
3. Install suggested plugins
4. Register the agent node — `Dashboard → Manage Jenkins → Nodes → New Node`
   - Use `jenkins_agent_private_ip` as the host
   - Add the master private key to credentials:
     ```bash
     sudo cat /var/lib/jenkins/.ssh/id_rsa
     ```

**Step 3 — Create the Infrastructure Configuration Pipeline:**
1. `Dashboard → New Item → Pipeline → Name: infrastructure-config`
2. Under Pipeline, select `Pipeline script from SCM`
3. Set SCM to Git, repo URL: `https://github.com/EddieByte/cicd-eks-pipeline`
4. Set Script Path to: `jenkins/infrastructure-config/Jenkinsfile`
5. Update `CONTROL_NODE_IP` in the Jenkinsfile with `control_node_private_ip` from Terraform outputs
6. Commit and push, then run the job

This job runs once after Jenkins is set up. It configures the agent and SonarQube via Ansible.
The Jenkinsfile is at `jenkins/infrastructure-config/Jenkinsfile`.

**Step 4 — Configure SonarQube:**
1. Open `sonarqube_url` in browser (default login: `admin` / `admin`)
2. Generate a global analysis token
3. Add token to Jenkins credentials as `Secret text`
4. Configure SonarQube webhook pointing back to Jenkins:
   `http://<jenkins_master_ip>:8080/sonarqube-webhook/`

---

### Teardown

```bash
cd terraform/jenkins
terraform destroy -auto-approve
```

This removes all EC2 instances, security groups, and IAM roles. SSM parameters are not destroyed — delete them manually if needed:

```bash
aws ssm delete-parameter --name "/jenkins/ssh-private-key" --region us-east-1
aws ssm delete-parameter --name "/jenkins/master-public-key" --region us-east-1
aws ssm delete-parameter --name "/sonarqube/db-username" --region us-east-1
aws ssm delete-parameter --name "/sonarqube/db-password" --region us-east-1
```

> **Production Notes:**
> - Restrict `allowed_ssh_cidrs` to your IP (`x.x.x.x/32`)
> - Restrict SonarQube port 9000 to known CIDRs or place behind an ALB
> - Migrate Terraform state to S3 + DynamoDB for team environments
