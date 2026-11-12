# Monitoring & Slack Notifications — Rollout Guide

Adds Slack notifications to the pipeline and Prometheus + Grafana monitoring to the EKS
cluster. Every step is independent, can be verified before moving on, and has a rollback.

> **Already set up?** For a routine rebuild after a teardown, follow
> [redeploy-runbook.md](redeploy-runbook.md) instead. This guide explains how each piece
> works and how to add it the first time. Since it was written, all Kubernetes Secrets are
> created in one step by `scripts/sync-k8s-secrets.ps1`, which replaces the manual secret
> commands in Steps 2 and 3b.

| Step | What you get | Touches the running app? |
|---|---|---|
| 0. Slack setup | Slack app, channels, tokens in SSM | No |
| 1. Jenkins → Slack | `#ci-builds`: build passed / failed | No (Jenkins restarts once) |
| 2. ArgoCD → Slack | `#deployments`: deployed / sync failed / degraded | No |
| 3. Monitoring stack | Grafana dashboards, pod health alerts → `#alerts` | No (new `monitoring` namespace) |
| 4. Blackbox probe | Uptime + response time of `/home.jsp`, database health via `/health` → `#alerts` | No |

**What does not change:** the app's Dockerfile, its source code, `base/` and `overlays/`
in the manifests repo, and Terraform (unless Step 3a says you need a third node).

**Files involved**

| Repo | Files |
|---|---|
| `cicd-eks-pipeline` | `ansible/roles/jenkins_master/files/plugins.txt`, `ansible/roles/jenkins_master/tasks/main.yml`, `ansible/roles/jenkins_master/templates/jcas.env.j2`, `ansible/roles/jenkins_master/templates/jenkins.yaml.j2`, `ansible/playbooks/master.yml`, this guide |
| `eddie-register-app` | `Jenkinsfile` (new `post {}` block) |
| `eddie-register-app-manifests` | `argocd/application-dev.yaml`, `argocd/application-prod.yaml` (annotations), new `argocd/monitoring.yaml`, `argocd/blackbox-exporter.yaml`, `argocd/notifications/slack-service-patch.yaml`, `monitoring/*.yaml` |

All commands below are PowerShell, run from your machine with the EKS kubeconfig active
(`aws eks update-kubeconfig --region us-east-1 --name eddie-register-app-eks`).

Names such as `eddie-register-app`, `eddie-register-app-manifests`, `eddie-register-app-eks`
and `eddie-register-app-dev` are this project's repos, cluster and namespaces. If you reuse
the platform, replace them with your own (see "Adapting This for Your Own App" in the README).

---

## Step 0 — Slack setup (about 10 minutes)

1. Create three channels: `#ci-builds`, `#deployments`, `#alerts`.
2. Go to <https://api.slack.com/apps> → **Create New App** → **From a manifest** (pick your
   workspace), switch to **YAML**, and paste:

   ```yaml
   display_information:
     name: CICD Bot
   features:
     bot_user:
       display_name: cicd-bot          # lowercase letters, digits, - _ . only (no "/" or spaces)
       always_online: false
   oauth_config:
     scopes:
       bot:
         - chat:write                  # Jenkins and ArgoCD post messages
         - incoming-webhook            # Alertmanager posts to #alerts
   settings:
     org_deploy_enabled: false
     socket_mode_enabled: false
     token_rotation_enabled: false     # keep false, or the token expires after a few hours
   ```

   Avoid the **Starter app** template: it adds slash commands and event listeners you'd
   have to host.
3. **Install to Workspace** and pick `#alerts` when asked: that creates the incoming webhook.
4. Copy the **Bot User OAuth Token** (`xoxb-...`, under **OAuth & Permissions**) and the
   webhook URL (under **Incoming Webhooks**). Paste them only into the next step, never
   into chat, tickets or Git; if they leak, revoke and reinstall to get new ones.
5. In Slack, invite the bot to the two channels it posts to:
   type `/invite @cicd-bot` in `#ci-builds` and in `#deployments`.
6. Store the secrets in SSM: run `scripts/setup-secrets.example.ps1`, which prompts for
   them (typing is hidden), checks them with Slack and saves them. Or by hand:

```powershell
aws ssm put-parameter --region us-east-1 --type SecureString --name /jenkins/slack-token          --value "xoxb-PASTE-TOKEN"
aws ssm put-parameter --region us-east-1 --type SecureString --name /monitoring/slack-webhook-url  --value "https://hooks.slack.com/services/PASTE"
aws ssm put-parameter --region us-east-1 --type SecureString --name /monitoring/grafana-admin-password --value "PICK-A-STRONG-PASSWORD"
```

The Jenkins token lives under `/jenkins/*`, so the Jenkins master's existing IAM policy
can already read it. No Terraform change is needed.

**Verify** the webhook posts to `#alerts`:

```powershell
$hook = aws ssm get-parameter --region us-east-1 --name /monitoring/slack-webhook-url --with-decryption --query Parameter.Value --output text
Invoke-RestMethod -Method Post -Uri $hook -ContentType 'application/json' -Body '{"text":"Webhook test"}'
```

---

## Step 1 — Jenkins → Slack

The order matters. The Jenkinsfile change uses `slackSend`, which only exists once the
Slack plugin is installed. If the Jenkinsfile lands first, every build fails with
`No such DSL method 'slackSend'`. So: **Jenkins first, Jenkinsfile second.**

### 1a. Configure Jenkins (infra repo)

1. In `ansible/playbooks/master.yml`, set `jenkins_slack_team_domain` to your workspace
   subdomain (for `my-team.slack.com` that's `my-team`). The setup script can detect
   it from your bot token and fill it in for you.
2. Commit and push the `cicd-eks-pipeline` changes.
3. Make sure **no build is running**, because installing plugins restarts Jenkins. Then run
   the `infrastructure-config` job, or on the control node:
   `cd ~/cicd-eks-pipeline/ansible && git pull && ansible-playbook -e @group_vars/all.yml playbooks/site.yml`

**Built-in safety:** the Slack settings follow the same "optional" pattern as the SonarQube
token. If `/jenkins/slack-token` doesn't exist, Jenkins is configured exactly as before.

**Verify:** In Jenkins, open **Manage Jenkins → Credentials** and check that `slack-token`
exists. Then open **Manage Jenkins → System → Slack** and click **Test Connection**. A
message should appear in `#ci-builds`.

Tip: run the local smoke test in `docker/jenkins-local` first to confirm the `slack` plugin
installs cleanly alongside the pinned Jenkins version.

### 1b. Update the Jenkinsfile (app repo)

Commit the new `post {}` block in `eddie-register-app/Jenkinsfile` and push. The push
triggers a build, and its result should appear in `#ci-builds`.

`slackSend` never fails a build: if Slack is down or the token is wrong, it only logs a warning.

**Rollback:** remove the `post {}` block. Optionally delete `/jenkins/slack-token` and
re-run Ansible.

---

## Step 2 — ArgoCD → Slack

ArgoCD v3 includes a notifications controller. It only needs templates, a Slack token and
subscriptions.

```powershell
# 1. Install the standard notification templates and triggers (matches your ArgoCD version)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/notifications_catalog/install.yaml

# 2. Give the notifications controller the same Slack bot token (from the cicd-eks-pipeline repo)
.\scripts\sync-k8s-secrets.ps1

# 3. Register Slack as a notification service (run from the manifests repo root)
kubectl -n argocd patch configmap argocd-notifications-cm --type merge --patch-file argocd/notifications/slack-service-patch.yaml
```

Next, commit the annotation changes to `argocd/application-dev.yaml` and
`argocd/application-prod.yaml` and push. These Application objects were applied by hand,
so re-apply them. Re-apply only the ones that already exist in the cluster: applying the
prod file would create the prod app if it isn't deployed yet.

```powershell
kubectl get applications -n argocd               # see which ones exist
kubectl apply -f argocd/application-dev.yaml     # if eddie-register-app-dev exists
kubectl apply -f argocd/application-prod.yaml    # ONLY if eddie-register-app-prod already exists
```

The annotations only subscribe to notifications. They don't change what gets deployed.

**Verify:** after the next Jenkins build updates the dev manifest, `#deployments` shows
"Application eddie-register-app-dev is now running new version...". If nothing arrives:
`kubectl logs -n argocd deploy/argocd-notifications-controller --tail=50`.

**Rollback:** remove the three annotation lines and re-apply the Application file.

---

## Step 3 — Monitoring stack (Prometheus, Alertmanager, Grafana)

### 3a. Check capacity first

On a t3.medium, EKS allows at most **17 pods per node**. The stack adds about **7 pods**
(plus 1 for Step 4) and about **1 GiB of memory requests**.

```powershell
kubectl get pods -A -o wide | Measure-Object -Line          # rough total (minus header line)
kubectl describe nodes | Select-String "^Name:","Non-terminated Pods","  memory"
```

You're fine if:

- the two nodes have **at least 9 free pod slots in total**, and
- each node's memory requests are **under about 60%**.

If not, add a third node *before* continuing. Set `node_desired = 3` in
`terraform/eks/terraform.tfvars`, then run `terraform plan`. It should show
`1 to change, 0 to destroy`, an in-place resize of the node group. Then run `terraform apply`.

### 3b. Create the Secrets the stack expects

`grafana-admin` and `alertmanager-slack` (plus the app's database secret) are created from
SSM by one script, run from the `cicd-eks-pipeline` repo:

```powershell
.\scripts\sync-k8s-secrets.ps1
```

Every line should show `[OK]`. If Grafana or Alertmanager pods were started before the
Secrets existed, they recover once the script has run (Grafana showed
`CreateContainerConfigError` and Alertmanager `Init:0/1` when this step was skipped).

### 3c. Deploy through ArgoCD

Commit and push `argocd/monitoring.yaml` and the `monitoring/` folder to the manifests
repo. ArgoCD reads the values file from Git, so it must be pushed first. Then:

```powershell
kubectl apply -f argocd/monitoring.yaml
kubectl get application monitoring -n argocd -w     # wait for Synced / Healthy (3–5 min)
kubectl get pods -n monitoring
```

Expected pods: `monitoring-operator`, `prometheus-monitoring-prometheus-0`,
`alertmanager-monitoring-alertmanager-0`, `grafana`, `monitoring-kube-state-metrics`, and
one `monitoring-prometheus-node-exporter` per node. A short-lived admission-webhook job also
runs and completes.

**Confirm the app is untouched:** `kubectl get pods -n eddie-register-app-dev` should show the
same pods and ages as before.

### 3d. Look around

```powershell
kubectl -n monitoring port-forward svc/grafana 3000:80                     # http://localhost:3000  (admin / your SSM password)
kubectl -n monitoring port-forward svc/monitoring-prometheus 9090:9090     # http://localhost:9090
kubectl -n monitoring port-forward svc/monitoring-alertmanager 9093:9093   # http://localhost:9093
```

Useful Grafana dashboards (already installed): **Kubernetes / Compute Resources / Namespace (Pods)**,
choosing `eddie-register-app-dev`, and **Node Exporter / Nodes**.

**Test Slack alerting end to end.** This sends a fake alert; it does not touch the app:

```powershell
kubectl -n monitoring exec alertmanager-monitoring-alertmanager-0 -c alertmanager -- amtool alert add RolloutTest severity=warning --annotation=summary="Test alert from the monitoring rollout" --alertmanager.url=http://localhost:9093
```

It appears in `#alerts` within about 30 seconds.

**Day-one noise:** small clusters sometimes trigger default warnings such as
`KubeMemoryOvercommit`. If one keeps firing and isn't useful, silence it in the
Alertmanager UI, or disable its rule group under `defaultRules.rules` in the values file.

**Rollback:** `kubectl delete -f argocd/monitoring.yaml`. The finalizer removes everything
the stack installed. Then `kubectl delete namespace monitoring`.

---

## Step 4 — Uptime and response-time probe (blackbox exporter)

1. In `monitoring/blackbox-exporter-values.yaml`, keep a target only for environments that
   are actually deployed. Remove `register-app-prod` if prod isn't running, or it will
   alert as "down".
2. Commit, push, then:

```powershell
kubectl apply -f argocd/blackbox-exporter.yaml
kubectl get application blackbox-exporter -n argocd -w
```

**Verify:** in Prometheus (`localhost:9090`), run the query `probe_success`. You should see
`1` for each target. `probe_duration_seconds` shows the response time. For a ready-made
view, import dashboard ID **7587** (Prometheus Blackbox Exporter) in Grafana via
**Dashboards → New → Import**.

The alerts `RegisterAppDown` (2 minutes without HTTP 2xx) and `RegisterAppSlow` (over 2s for
5 minutes) are already defined in `monitoring/kube-prometheus-stack-values.yaml`.

**Rollback:** `kubectl delete -f argocd/blackbox-exporter.yaml`.

---

## What alerts you'll get in #alerts

| Alert | Fires when | Severity |
|---|---|---|
| `RegisterAppDown` | `/home.jsp` fails for 2 minutes | critical |
| `RegisterAppSlow` | `/home.jsp` takes over 2s for 5 minutes | warning |
| `RegisterAppMemoryNearLimit` | Tomcat uses over 90% of its 512Mi for 10 minutes | warning |
| `RegisterAppOOMKilled` | The container ran out of memory and restarted | warning |
| `RegisterAppDatabaseDown` | `/health` fails for 2 minutes (app can't reach RDS) | critical |
| `KubePodCrashLooping` (built in) | A pod keeps restarting | warning |
| `KubeDeploymentReplicasMismatch` (built in) | Fewer pods running than desired | warning |
| `KubeNodeNotReady` (built in) | A worker node is unhealthy | warning |

Each alert posts twice: a red 🚨 message when it fires, and a green ✅ **Recovered**
message with its own wording (e.g. "Database reachable again") when it clears.

## Teardown

The monitoring stack creates **no AWS resources**: no LoadBalancer and no EBS volumes. It
doesn't add anything that blocks `terraform destroy`. For a clean exit, delete
`blackbox-exporter` and `monitoring` Applications along with the app Applications.

Data is kept for 3 days on the node's disk and is lost if the Prometheus pod moves to
another node. That's expected for a lab. To keep history, install the EBS CSI driver
add-on and enable `storageSpec` later.
