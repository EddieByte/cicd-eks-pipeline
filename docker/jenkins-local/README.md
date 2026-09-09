# Local Jenkins Smoke Test

This harness tests the Jenkins plugin manifest and JCasC configuration locally with Docker before deploying to AWS.

## What It Tests

- Jenkins starts on Java 21.
- The plugin manifest can be installed.
- JCasC loads successfully.
- `sonarqube-server` is created.
- `sonarqube-token` and `github` credentials are created from environment variables.
- Jenkins remains usable after a container restart.

## What It Does Not Test

- Ansible execution.
- AWS SSM access or decryption.
- EC2 dynamic inventory.
- Jenkins master-to-agent SSH connectivity.
- Private IP discovery.
- IAM permissions.
- The cloud SonarQube host.

Those require the Ansible control-node test after the local smoke test passes.

## Prerequisites

Install Docker Desktop and confirm it is running:

```powershell
docker version
docker compose version
```

## Start the Local Jenkins Container

Run these commands from this directory:

```powershell
Copy-Item .env.example .env
notepad .env

docker compose build --no-cache
docker compose up -d
```

Use throwaway values in `.env`. Do not paste production GitHub or SonarQube tokens into this file.

Check startup logs:

```powershell
docker compose logs -f jenkins
```

Wait until Jenkins reports that it is ready, then open:

```text
http://localhost:8080
```

The first local run may still show the Jenkins setup wizard because this test uses a fresh Jenkins home volume. Complete it, or inspect the logs for the generated initial password:

```powershell
docker compose exec jenkins bash -c 'cat /var/jenkins_home/secrets/initialAdminPassword'
```

## Verify JCasC and Plugins

Check the installed plugins:

```powershell
docker compose exec jenkins bash -c 'ls /var/jenkins_home/plugins | Select-Object -First 20'
```

Check the Jenkins log for JCasC errors:

```powershell
docker compose logs jenkins | Select-String 'Configuration as Code|SEVERE|ERROR'
```

In Jenkins, verify:

- **Manage Jenkins -> System** contains `sonarqube-server`.
- **Manage Jenkins -> Credentials** contains `github`.
- **Manage Jenkins -> Credentials** contains `sonarqube-token`.
- The Jenkins Configuration as Code plugin is installed.
- The SonarQube plugin is installed.
- Docker Pipeline support is installed.

## Test Restart and Idempotency

```powershell
docker compose restart jenkins
docker compose logs -f jenkins
```

Jenkins should restart without requiring the values to be entered again. This validates the containerized JCasC path.

## Clean Rebuild

Use this when testing from a completely empty Jenkins installation:

```powershell
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

The `-v` option deletes the local Jenkins home volume and all local Jenkins state.

## Move to the Cloud Test

After this local test passes:

1. Ensure the cloud SSM parameters exist for GitHub username and token.
2. Deploy the Jenkins Terraform stack.
3. Refresh the control-node repository.
4. Run `ansible-playbook --syntax-check playbooks/site.yml`.
5. Run `ansible all -m ping`.
6. Run `ansible-playbook playbooks/site.yml`.
7. Create the SonarQube token after SonarQube starts.
8. Store the token in `/jenkins/sonarqube-token`.
9. Rerun `ansible-playbook playbooks/master.yml`.

The local JCasC file is deliberately separate from the cloud JCasC template because the cloud version discovers EC2 private IPs and uses files/credentials created by Ansible.
