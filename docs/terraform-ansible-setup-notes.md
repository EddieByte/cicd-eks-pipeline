# Terraform & Ansible Infrastructure Setup

## Infrastructure Details
- **Tool:** Terraform (IaC) + Ansible (Configuration Management)
- **Instances:** Jenkins Master, Jenkins Agent, SonarQube, Ansible Control Node
- **Region:** us-east-1
- **Instance Type:** t3.medium (all servers), t3.micro (control node)
- **OS:** Ubuntu 22.04

---

### Issue 11 — AWS CLI not installed on EC2 instances

- **Error:** `Command 'aws' not found`
- **Root Cause:** The userdata script attempted to call `aws ssm put-parameter` before the AWS CLI was installed on the instance. The base Ubuntu 22.04 AMI does not include the AWS CLI by default.
- **Fix:** Added `apt-get install -y awscli` to the userdata script before any SSM calls.

---

### Issue 12 — SSM `put-parameter` failed with empty `--region` argument

- **Error:** `aws: error: argument --region: expected one argument`
- **Root Cause:** The region was being fetched using the IMDSv1 endpoint (`curl -s http://169.254.169.254/latest/meta-data/placement/region`) inline inside the `aws` command. The instance had IMDSv2 enforced (`http_tokens = required`), so the unauthenticated IMDSv1 request returned an empty string, causing `--region` to receive no value.
- **Fix:** Switched to IMDSv2-compliant metadata fetch — first obtaining a session token via a `PUT` request, then using that token in the metadata request:
  ```bash
  TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
  REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
  ```

---

### Issue 13 — Terraform `local-exec` bash commands failed on Windows

- **Error:** `sleep`, multi-line `\` continuations, and SSH commands not recognised by `cmd.exe`
- **Root Cause:** Terraform's `local-exec` provisioner defaults to `cmd.exe` on Windows, which does not support bash syntax.
- **Fix:** Switched the `local-exec` interpreter to PowerShell for Windows-specific runs, then later migrated Ansible execution to a cloud-based Ansible Control Node to remove the local machine dependency entirely.
  ```hcl
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    ...
  }
  ```

---

### Issue 14 — `terraform apply -replace` flag rejected by PowerShell

- **Error:** `Invalid force-replace address` / `Too many command line arguments`
- **Root Cause:** PowerShell interprets the `=` sign in `-replace=resource.name` as a separate token, breaking the argument parsing.
- **Fix:** Wrap the flag in quotes so PowerShell treats it as a single argument:
  ```bash
  terraform apply "-replace=module.master.aws_instance.jenkins_master" -auto-approve
  ```

---

### Issue 15 — Terraform module restructure required to enforce provisioning order

- **Root Cause:** The initial setup used two separate Terraform state directories (`Jenkins-Master/` and `Jenkins-Agent/`), meaning there was no way to enforce that the master was fully provisioned before the agent started. The agent's userdata pulled the master's SSH public key from SSM, so if it ran first the key would not exist yet.
- **Fix:** Restructured into a single root module with child modules under `terraform/jenkins/modules/`. The agent module uses `depends_on = [module.master]`, enforcing the correct provisioning order in a single `terraform apply`.

---

### Issue 16 — Pending OS updates visible after instance boot despite userdata upgrade

- **Root Cause:** `apt-get upgrade` in userdata runs at launch time. By the time SSH access is established, Ubuntu's package mirrors may have published new updates, causing the MOTD to report pending upgrades. Some kernel-related packages (e.g. `linux-aws`) are also held back by `apt-get upgrade` and require `apt-get dist-upgrade` to apply.
- **Fix:** This is expected behaviour and not a bug. Run the following after SSHing in:
  ```bash
  sudo apt-get dist-upgrade -y
  sudo reboot
  ```

---

## Architecture Decisions

- **SSM Parameter Store** used for all secrets (Jenkins SSH public key, SonarQube DB credentials, EC2 private key) — avoids hardcoding secrets in code or userdata scripts.
- **IMDSv2 enforced** on all instances (`http_tokens = required`) — prevents SSRF-based metadata attacks.
- **Ansible Control Node** deployed as a dedicated EC2 instance — removes dependency on the local machine for configuration management, enables Jenkins to trigger playbooks as a pipeline stage.
- **Terraform root module pattern** — a single root `main.tf` calls all child modules and controls dependency order, keeping variables DRY with a single `terraform.tfvars`.

## Key Lessons Learned
- Always install the AWS CLI explicitly in userdata — do not assume it is present on the base AMI.
- IMDSv2 must be used consistently — mixing IMDSv1 calls on an IMDSv2-enforced instance causes silent empty responses, not errors.
- PowerShell and bash are not interchangeable — any shell scripting in Terraform `local-exec` on Windows must account for the interpreter.
- Separate Terraform state directories cannot enforce cross-module dependencies — use a root module with `depends_on` instead.
- Migrating configuration management to a cloud control node makes the setup portable and CI/CD-friendly.

## Production Notes
- SonarQube port 9000 is currently open to `0.0.0.0/0` — restrict to known CIDRs or place behind an ALB in production.
- SSH CIDR (`allowed_ssh_cidrs`) is set to `0.0.0.0/0` for lab purposes — restrict to your IP (`x.x.x.x/32`) in production.
- Consider migrating Terraform state to S3 for team environments.
