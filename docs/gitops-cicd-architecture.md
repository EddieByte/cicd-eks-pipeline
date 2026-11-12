# GitOps + CI/CD Architecture for eddie-register-app

## Overview
This document captures the key architectural decisions, operational patterns, and lessons learned from implementing a GitOps-powered DevOps platform for eddie-register-app. It is intended to complement the existing notes in `eks-gitops.md`, `jenkins-setup-notes.md`, and `sonarqube-postgres.md`.

> Git is the single source of truth. Infrastructure is managed as code, and deployment is controlled through versioned manifests.

## 1. Architectural Philosophy: The GitOps Paradigm

### Dual-Repository Separation
A strict two-repository model was adopted:
- **Application repository (eddie-register-app)**: Holds the Java web application (JSP pages + a servlet, packaged as a WAR and run on Tomcat 9).
- **Manifest repository (eddie-register-app-manifests)**: Holds Kubernetes desired-state manifests and GitOps configuration.

This separation enforces a clean boundary between application logic and deployment infrastructure. It also supports:
- independent CI and CD workflows
- traceable change history for cluster state
- automatic drift correction by Argo CD

### Why This Matters
- Prevents environment drift caused by manual console changes
- Ensures the Kubernetes cluster always converges to the manifest in Git
- Provides a clear audit trail for both application and deployment changes

## 2. The CI/CD "Autopilot" Engine

### Security First: DevSecOps Pipeline
The Jenkins pipeline was designed as a quality gate, with security checks built into every release path.
Key stages include:
- **SonarQube analysis** of the Java source
- **Trivy container scanning** to detect HIGH/CRITICAL vulnerabilities
- **Pipeline fail-fast behavior** on SonarQube quality gate failures

The SonarQube quality gate is blocking: a failed gate stops the pipeline before an image is built. The Trivy scan is deliberately report-only in this lab: findings appear in the build log for review but do not stop the deployment. Switching Trivy to `--exit-code 1` turns it into a blocking gate.

### The Manifest Bridge
Instead of using insecure, imperative deployments with `kubectl`, the pipeline updates Git manifests directly:
- Jenkins uses `kustomize` to modify `kustomization.yaml`
- Updated manifests are committed and pushed back to the manifest repository
- Argo CD observes the new manifest state and deploys it automatically

Benefits:
- secure change flow with Git history
- no uncontrolled cluster access from the CI server
- full auditability of deployment updates

## 3. Kubernetes Orchestration on AWS EKS

### Resource Optimization
A modern DevOps stack was deployed to EKS with the following sizing lessons:
- **t2.micro and t3.small are too small** for Jenkins agents and JVM-based workloads
- Upgrading to **t3.medium** or larger provides headroom and prevents OOMKilled failures

This sizing decision minimizes instability from noisy system pods and stabilizes the cluster control plane.

### Kustomize Overlays
A base/overlay pattern was applied for environment-specific deployment configuration:
- **Base manifests** define common application resources
- **Overlays** apply environment differences for Dev, QA, and Prod

This pattern avoids YAML duplication and keeps the deployment model maintainable across multiple environments.

## 4. FinOps: Cluster Lifecycle and Cost Discipline

### Graceful Shutdown
The environment is torn down in a fixed order (see [redeploy-runbook.md](redeploy-runbook.md)):
- delete the ArgoCD Application and the app namespace first, so Kubernetes removes the
  Classic Load Balancer it created (Terraform doesn't know about it, and it would block
  VPC deletion)
- then `terraform destroy` the EKS stack (cluster, NAT gateway and RDS), then the CI stack
- a final set of AWS CLI checks confirms no instances, load balancers, volumes, IPs or
  databases are left running

### State Preservation
Because the infrastructure is defined in Git, destroying the cluster is not destructive work.
- Terraform state lives in an S3 bucket, so either stack can be rebuilt from any machine
- secrets stay in SSM Parameter Store between rebuilds
- manifests restore the desired state in minutes via Argo CD, starting from the last image
  Jenkins built
- the only thing lost is application data: RDS is destroyed with the stack (lab setting)

## 5. Practical Lessons and Cross-Reference Notes

### Existing Documentation Links
- `docs/eks-gitops.md`: EKS troubleshooting, Free Tier restrictions, OOM and Argo CD apply issues
- `docs/jenkins-setup-notes.md`: Jenkins installation, Java 21 requirement, pipeline configuration, Trivy Docker API issues
- `docs/sonarqube-postgres.md`: SonarQube PostgreSQL troubleshooting and password recovery notes

### Core Lessons
- Treat Git as the source of truth for both application and infrastructure
- Use declarative GitOps deployment rather than imperative `kubectl` pushes
- Size cluster nodes for real workloads, not textbook minimums
- Build a CI pipeline that fails on security-critical vulnerabilities
- Keep manifest updates auditable by committing changes back to Git

## 6. Recommended Next Steps

1. Keep the manifest repo as the primary deployment control plane.
2. Enforce branch protection and PR review on both repos.
3. Extend the overlay model for additional environments and feature flags.
4. Add a short README link in the root `README.md` to this doc for visibility.

---
