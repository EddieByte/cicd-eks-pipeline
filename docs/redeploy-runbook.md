# Redeploy Runbook (from nothing to a live app)

Use this after a full `terraform destroy`. The order matters: each step depends on the
one before it. Commands are PowerShell, run from `D:\eddie-register-app\Project`.

| # | Step | Command / action | Check |
|---|------|------------------|-------|
| 1 | Secrets in SSM | `cd cicd-eks-pipeline; .\scripts\setup-secrets.ps1` (your local copy) or `setup-secrets.example.ps1`; press **K** to keep each one | Ends with **READY** |
| 2 | CI servers | `cd terraform\jenkins; terraform init -backend-config="..\backend.hcl"; terraform apply` | `27 added` |
| 3 | Configure CI | SSH to the control node, then `cd ~/cicd-eks-pipeline && git pull && cd ansible && nohup ansible-playbook playbooks/site.yml > ~/site-run.log 2>&1 &` | PLAY RECAP `failed=0` |
| 4 | EKS + RDS (can run during step 3) | `cd terraform\eks; terraform init -backend-config="..\backend.hcl"; terraform apply` | Outputs show `db_endpoint` |
| 5 | Connect kubectl | `aws eks update-kubeconfig --region us-east-1 --name eddie-register-app-eks` | `kubectl get nodes`: 3 Ready |
| 6 | ArgoCD | `.\scripts\bootstrap-argocd.ps1 -LocalPort 8081` | "Argo CD is ready" |
| 7 | **Kubernetes secrets** | `.\scripts\sync-k8s-secrets.ps1` | Every line `[OK]` |
| 8 | ArgoCD → Slack | In the manifests repo: `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/notifications_catalog/install.yaml` then `kubectl -n argocd patch configmap argocd-notifications-cm --type merge --patch-file argocd/notifications/slack-service-patch.yaml` | No errors |
| 9 | App + monitoring | `kubectl apply -f argocd/application-dev.yaml`, `argocd/monitoring.yaml`, `argocd/blackbox-exporter.yaml` | Pods Running |
| 10 | Jenkins UI | Unlock, plugins **None**, admin user, Slack **Test Connection**, create the `eddie-register-app` pipeline job | Slack test message |
| 11 | GitHub webhook | App repo → Settings → Webhooks → Payload URL `http://<new Jenkins IP>:8080/github-webhook/` | Green tick |
| 12 | First build | Jenkins → **Build Now** | `#ci-builds` then `#deployments` |
| 13 | Verify | `curl.exe -s -i http://<load balancer>/health` | `200 OK: database reachable` |

## Why the "database down" alert won't repeat

The first time, the cluster ran an **old image built before the database code existed**: it
had no `/health` page, so the database check failed. That is now prevented by:

- **The manifests repo keeps the last image Jenkins built.** It already contains the
  database-enabled app, so ArgoCD deploys working code from the very first sync.
- **Unique image tags.** Tags are `<version>-<build>-<git commit>` (e.g. `1.1.0-3-a1b2c3d`),
  so a rebuilt Jenkins (whose build numbers restart at 1) can never overwrite an old tag
  with different code.
- **Secrets before the app (step 7 before step 9).** The app also tolerates a missing secret
  (it starts and shows "database unavailable"), and the sync script restarts it once the
  secret exists.

A short alert during the first few minutes of a deploy can still happen while pods start.
It clears by itself, and Slack then shows a green **Recovered** message.

## If the database alert fires anyway

```powershell
kubectl get deploy -n eddie-register-app-dev -o jsonpath="{.items[0].spec.template.spec.containers[0].image}"
kubectl get secret register-app-db -n eddie-register-app-dev
$lb = kubectl get svc -n eddie-register-app-dev -o jsonpath="{.items[0].status.loadBalancer.ingress[0].hostname}"
curl.exe -s -i "http://$lb/health"
```

| `/health` returns | Meaning | Fix |
|---|---|---|
| `404` | An image from before the database code is running | Jenkins → Build Now |
| `503` | New app, database not reachable | `kubectl logs -n eddie-register-app-dev deploy/dev-eddie-register-app-deployment --tail=100` and look for "Database error" |
| Secret `NotFound` | Step 7 was skipped | `.\scripts\sync-k8s-secrets.ps1` |

## Data

`terraform destroy` deletes the RDS database, **including all registered accounts**
(lab setting: no final snapshot). Each redeploy starts with an empty database.

## Teardown (reverse order)

```powershell
cd eddie-register-app-manifests
kubectl delete -f argocd/application-dev.yaml
kubectl delete namespace eddie-register-app-dev      # removes the load balancer
aws elb describe-load-balancers --region us-east-1 --query "LoadBalancerDescriptions[].DNSName" --output text   # repeat until empty
kubectl delete -f argocd/blackbox-exporter.yaml
kubectl delete -f argocd/monitoring.yaml

cd ..\cicd-eks-pipeline\terraform\eks;  terraform destroy     # EKS + RDS
cd ..\jenkins;                          terraform destroy     # CI servers
```

SSM secrets and the S3 state bucket are kept for next time.
