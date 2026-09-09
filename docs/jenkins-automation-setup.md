# Jenkins Automation Setup

This is the first reusable Jenkins automation pass for this repository.

The current default is **manual-first mode**. The Ansible master play installs Jenkins and prepares master-to-agent SSH trust, but it does not install the plugin manifest, load JCasC, retrieve GitHub credentials, or create Jenkins jobs. This allows the first cloud deployment to be configured and verified manually before exporting a known-good configuration.

The design separates responsibilities:

```text
Terraform -> EC2, IAM, networking, and SSM access
Ansible -> Jenkins installation and host files
Jenkins plugin manifest -> plugin installation
Jenkins Configuration as Code -> nodes, tools, SonarQube, and credential IDs
AWS SSM Parameter Store -> secret values
Application Jenkinsfile -> build and delivery behavior
```

## What Was Added

The Jenkins master role now manages:

- Jenkins plugins from `ansible/roles/jenkins_master/files/plugins.txt`.
- JCasC configuration from `ansible/roles/jenkins_master/templates/jenkins.yaml.j2`.
- The Jenkins master-to-agent SSH key.
- The EC2 private key used by the infrastructure pipeline.
- A protected environment file containing secret values retrieved from SSM.
- A systemd override that enables JCasC at Jenkins startup.

Those configuration tasks are enabled only when `jenkins_manage_configuration: true` is set in `ansible/playbooks/master.yml`.

## Manual-First Deployment

Run the normal site playbook without creating the GitHub or SonarQube token parameters for JCasC:

```bash
ansible-playbook --syntax-check playbooks/site.yml
ansible all -m ping
ansible-playbook playbooks/site.yml
```

In this mode, manually complete the Jenkins UI setup, install and verify plugins, configure tools, connect the agent, configure SonarQube, add credentials, and run a successful application pipeline. Then export and sanitize Jenkins Configuration as Code.

Do not rerun `ansible/playbooks/master.yml` with configuration management enabled against that manually configured instance until the exported configuration has been reviewed. JCasC is intentionally declarative and may reconcile or replace UI-managed settings.

## Enable Configuration Automation Later

After the manual configuration has been proven and the JCasC export has been reviewed, change this variable in `ansible/playbooks/master.yml`:

```yaml
jenkins_manage_configuration: true
```

Before running the playbook in this mode, create the required SSM parameters:

```text
/jenkins/ssh-private-key
/jenkins/github-username
/jenkins/github-token
```

The `/jenkins/sonarqube-token` parameter remains optional during the first automation pass because SonarQube is provisioned by the same infrastructure workflow. Add it after generating the token in SonarQube, then rerun `ansible-playbook playbooks/master.yml`.

The automation discovers the Jenkins agent private IP and SonarQube URL from the EC2 dynamic inventory. They are not hardcoded in the JCasC file.

## How to Pass Credentials Securely

Store secret values in AWS SSM Parameter Store. Store only the parameter names and Jenkins credential IDs in Git.

Required parameters for the current JCasC configuration:

| SSM parameter | Type | Used for |
|---|---|---|
| `/jenkins/ssh-private-key` | `SecureString` | `labs-kp` credential and infrastructure pipeline SSH |
| `/jenkins/github-username` | `String` | `github` credential username |
| `/jenkins/github-token` | `SecureString` | `github` credential token |
| `/jenkins/sonarqube-token` | `SecureString` | `sonarqube-token` credential; create after SonarQube initialization |

Create them from the deployment workstation. Do not put real values into this document or into Terraform variables committed to Git:

```powershell
$region = "us-east-1"
$keyPath = "$HOME\.ssh\labs_kp.pem"

aws ssm put-parameter `
  --name "/jenkins/ssh-private-key" `
  --value (Get-Content $keyPath -Raw) `
  --type SecureString `
  --overwrite `
  --region $region

aws ssm put-parameter `
  --name "/jenkins/github-username" `
  --value "<github-username>" `
  --type String `
  --overwrite `
  --region $region

aws ssm put-parameter `
  --name "/jenkins/github-token" `
  --value "<github-token>" `
  --type SecureString `
  --overwrite `
  --region $region

```

The SonarQube parameter is intentionally optional during the first Ansible run. SonarQube is provisioned by `site.yml`, so its analysis token cannot exist beforehand.

After SonarQube is running, generate a token in **SonarQube -> My Account -> Security**, store it in SSM, and rerun only the Jenkins master play:

```powershell
aws ssm put-parameter `
  --name "/jenkins/sonarqube-token" `
  --value "<sonarqube-token>" `
  --type SecureString `
  --overwrite `
  --region us-east-1
```

```bash
cd /home/ubuntu/cicd-eks-pipeline/ansible
ansible-playbook playbooks/master.yml
```

The second pass detects the parameter, creates the `sonarqube-token` Jenkins credential, and attaches it to the `sonarqube-server` configuration. Until then, Jenkins can start normally, but SonarQube analysis remains unauthenticated.

The Jenkins master IAM role already allows SSM access under `arn:aws:ssm:<region>:*:parameter/jenkins/*`, which covers these paths. For production, narrow that policy to the exact parameters.

Ansible retrieves the values with `--with-decryption`, writes them to `/etc/jenkins/jcas.env`, and sets the file to root ownership with mode `0640`. Jenkins reads the file at startup. The secret values are never rendered into the tracked JCasC YAML.

## Credential IDs

These IDs are intentionally stable and are safe to reference from Jenkinsfiles:

| Jenkins ID | Type | Purpose |
|---|---|---|
| `jenkins-agent-ssh` | SSH private key | Launches the `jenkins` user on the agent at `/home/jenkins` |
| `labs-kp` | SSH private key | Connects the infrastructure pipeline to the control node as `ubuntu` |
| `github` | Username and password/token | GitHub checkout |
| `sonarqube-token` | Secret text | SonarQube analysis |
| `sonarqube-server` | Server configuration name | Jenkins SonarQube integration; this is not a credential |

## First Deployment

1. Create the SSM parameters above.
2. Confirm the Jenkins, agent, and SonarQube instances are running and tagged `Project=eddie-register-app`.
3. SSH to the Ansible control node.
4. Refresh its repository checkout.
5. Run the syntax check and connectivity check.
6. Run the site playbook.

```bash
cd /home/ubuntu/cicd-eks-pipeline
git pull --ff-only origin main
cd ansible
ansible-playbook --syntax-check playbooks/site.yml
ansible-inventory --graph
ansible all -m ping
ansible-playbook playbooks/site.yml
```

The master playbook renders and activates JCasC as part of the normal `site.yml` run.

## Verification

Check the Jenkins service:

```bash
ssh -i ~/.ssh/labs_kp.pem ubuntu@<jenkins-master-public-ip> \
  "sudo systemctl status jenkins --no-pager"
```

Check the JCasC files without printing secret values:

```bash
ssh -i ~/.ssh/labs_kp.pem ubuntu@<jenkins-master-public-ip> \
  "sudo test -s /var/lib/jenkins/casc_configs/jenkins.yaml && sudo stat -c '%a %U %G' /etc/jenkins/jcas.env"
```

Check startup errors:

```bash
ssh -i ~/.ssh/labs_kp.pem ubuntu@<jenkins-master-public-ip> \
  "sudo journalctl -u jenkins --no-pager -n 100"
```

Then open Jenkins and verify:

- The `Jenkins-Agent` node is online.
- The remote root is `/home/jenkins`.
- The `github` credential exists.
- The `sonarqube-token` credential exists.
- The SonarQube server is named `sonarqube-server`.
- The `labs-kp` credential exists for `infrastructure-config`.

## Plugin Version Control

The initial manifest lists plugin IDs and lets Jenkins resolve compatible versions. This is convenient for the first automation test but is not the final production control.

After the configuration works:

1. Record the installed plugin versions.
2. Replace unversioned entries in `plugins.txt` with tested versions.
3. Rebuild a disposable Jenkins instance.
4. Run the infrastructure and application smoke tests.
5. Commit the tested plugin manifest.

Do not upgrade all plugins directly on production. Change the manifest, rebuild or test, and then promote the known-good versions.

## Troubleshooting

### Jenkins fails during JCasC startup

Check:

```bash
sudo journalctl -u jenkins --no-pager -n 150
```

Typical causes are a missing plugin, invalid JCasC YAML, missing SSM parameter, or an unavailable credential source file.

### A required SSM parameter is missing

Verify names without displaying values:

```bash
aws ssm get-parameters-by-path \
  --path /jenkins \
  --query 'Parameters[].Name' \
  --output table \
  --region us-east-1
```

### The agent is offline

Confirm the source key and target file:

```bash
sudo test -s /var/lib/jenkins/.ssh/id_ed25519
sudo test -s /home/jenkins/.ssh/authorized_keys
```

The master connects as `jenkins`, not `ubuntu`.

### SonarQube analysis says Not authorized

Confirm that the `sonarqube-token` SSM parameter contains a valid token and that the Jenkins SonarQube server configuration is named exactly `sonarqube-server`.

## Security Rules

- Never commit token values, private keys, or passwords.
- Never print `/etc/jenkins/jcas.env` in a troubleshooting command.
- Use short-lived or least-privilege GitHub tokens.
- Rotate tokens in SSM and rerun Ansible to update Jenkins.
- Restrict the Jenkins master IAM role to only the SSM parameters it needs.
- Keep Jenkins and SonarQube security-group ingress restricted to trusted networks.
