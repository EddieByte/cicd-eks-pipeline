# Jenkins Credentials Reference

Use these names consistently when rebuilding Jenkins.

| ID / Name | Jenkins type | Purpose | Status |
|---|---|---|---|
| `labs-kp` | SSH Username with private key | Jenkins connects to the Ansible control node as `ubuntu` | Managed by JCasC |
| `jenkins-agent-ssh` | SSH Username with private key | Jenkins master launches the agent as `jenkins` | Managed by JCasC |
| `github` | Username with password/token | GitHub checkout and repository access | Managed by JCasC |
| `DockerHub` | Username with password/token | DockerHub image push in the application pipeline | Managed by JCasC |
| `sonarqube-token` | Secret text | SonarQube analysis authentication | Managed by JCasC (injected after SonarQube runs) |

## Jenkins System Configuration

| Name | Configuration type | Purpose |
|---|---|---|
| `sonarqube-server` | Jenkins SonarQube server configuration | Name passed to `withSonarQubeEnv('sonarqube-server')`; it is not itself a credential |

## Notes

- The `labs-kp` ID must match the `SSH_CREDENTIAL_ID` parameter in the infrastructure pipeline.
- The SonarQube server configuration should reference the `sonarqube-token` credential.
- Do not store private keys, GitHub tokens, or SonarQube tokens in this file or in Git.
- Docker registry credentials and application-specific manifest-repository credentials are not defined in this repository. Add them only when the application Jenkinsfile specifies their exact IDs.
