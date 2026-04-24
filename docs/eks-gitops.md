EKS & GitOps Deployment (Argo CD)

## Infrastructure Details
- **Cluster Tool:** eksctl
- **Control Plane:** AWS EKS (v1.30)
- **Node Type:** c7i-flex.large (Free-tier trial)
- **Nodes:** 2 Managed Nodes
- **CD Tool:** Argo CD (GitOps)

### Issue 4 — EKS Creation Blocked (Free Tier Restricted)
- **Error:** `InvalidParameterCombination - Not eligible for Free Tier`
- **Root Cause:** New AWS accounts are placed in a "Sandbox" mode that restricts API access to `micro` instances only, even if other types are "Free Tier Eligible."
- **Fix:** Upgraded AWS account to "Paid Plan" in Billing Console to unlock full API access (credits still apply to cover usage).

### Issue 5 — Managed Nodes "Out of Memory" (OOM)
- **Error:** Cluster creation timeout / Nodes stuck in `NotReady`
- **Root Cause:** Attempted to use `t2.micro` (1GB RAM). System pods (vpc-cni, kube-proxy, CoreDNS) consumed 80% of resources, leaving no room for the Kubelet to stabilize.
- **Fix:** Switched to `c7i-flex.large` (4GB RAM).
- **Logic:** High-performance instances ensure cluster stability for distributed workloads.

### Issue 6 — Argo CD CRD Metadata Annotation Limit
- **Error:** `metadata.annotations: Too long: must have at most 262144 bytes`
- **Root Cause:** Standard `kubectl apply` tries to store the massive Argo CD manifest in a single annotation, exceeding the 256KB limit.
- **Fix:** Used Server-Side Apply:
  `kubectl apply --server-side -n argocd -f <manifest_url>`

### Issue 7 — VPC/Subnet Deletion Failure
- **Error:** `The following resource(s) failed to delete: [Subnet, VPCGatewayAttachment]`
- **Root Cause:** A Kubernetes LoadBalancer service (created via `kubectl patch`) created a physical AWS ELB that wasn't managed by CloudFormation, locking the subnets.
- **Fix:** Manually deleted the ELB and Target Groups in the EC2 Console before retrying the `eksctl delete cluster` command.

## Key Lessons Learned
- **EKS Cost Management:** The EKS Control Plane costs $0.10/hr regardless of node type. Always `eksctl delete cluster` when not in use to avoid draining credits.
- **Sandbox Restrictions:** "Free Tier Eligible" label in the console does not guarantee API permission on new accounts until a payment method is verified via "Paid Plan" upgrade.
- **GitOps Persistence:** Using Argo CD allows for "disposable clusters." If cost is an issue, delete the cluster and recreate it later; Argo CD will automatically resync the application state from GitHub in minutes.
- **Server-Side Apply:** Use `--server-side` for complex tools like Argo CD or Istio to avoid annotation size limits.