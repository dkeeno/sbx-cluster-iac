# sbx-cluster-iac

Terraform for the sandbox EKS Auto Mode cluster + everything that runs on it: VPC, NAT, bastion, ECR, ArgoCD, Image Updater, netshoot.

GitHub Actions equivalent of `gitlab-terraform-gcp/sbx-iac/sbx-02-cluster-iac/`.

---

## What this stack creates

| Component | File | What |
|---|---|---|
| Network | `vpc.tf` | VPC `10.0.0.0/16`, 3 public subnets, 3 private subnets, IGW, single NAT in `us-east-1a` |
| Cluster | `eks.tf` | EKS Auto Mode `sbx-eks-01`, public+private endpoint, access entries, OIDC provider for IRSA |
| Bastion | `bastion.tf` | EC2 t3.medium in private subnet, SSM agent, no SSH, kubectl + helm pre-installed |
| Registry | `ecr.tf` | ECR repos `sbx-images/online-shop` + `sbx-images/art-gallery`, pull-through cache for public.ecr.aws |
| GitOps | `argocd.tf` | ArgoCD via Helm, ClusterIP service, GitHub PAT secret for sbx-manifests, bootstrap Application |
| Image Updater | `argocd-image-updater.tf` | Image Updater via Helm, IRSA for ECR reads |
| Debug | `netshoot.tf` | Persistent netshoot pod in default ns |

Total resource count: ~50.

---

## Pre-requisites

1. **Bootstrap stack applied** — `github-terraform-aws/bootstrap/` must have run successfully. It creates:
   - The S3 bucket this stack uses for state
   - The DynamoDB lock table
   - The IAM role GitHub Actions assumes via OIDC
   - The 5 GitHub repos including this one
   - The `AWS_ROLE_ARN` secret on this repo

2. **Set the additional GitHub secret** — only one secret isn't created by bootstrap:

   ```sh
   # Get a fine-grained PAT with Contents: Read on dkeeno/sbx-manifests
   # Add it via: GitHub → Settings → Secrets and variables → Actions → New repository secret
   #   Name:  GITHUB_PAT_FOR_ARGOCD
   #   Value: <the PAT>
   ```

   This is what ArgoCD uses to pull manifests from the gitops repo. Why it's not in bootstrap: bootstrap's PAT (which terraforms repos) shouldn't be the one ArgoCD holds long-term. Different blast radius.

---

## How changes reach the cluster

```
local edit on .tf file
   ↓
git push to feature branch + open PR
   ↓
GitHub Actions runs:
   1. validate (fmt + init + validate)
   2. plan (against real backend, posted as PR comment)
   ↓
human reviews PR + merges to main
   ↓
GitHub Actions reruns validate + plan on main
   ↓
human triggers `terraform.yml → workflow_dispatch → apply`
   ↓
Environment "production" requires manual approval
   ↓
terraform apply runs against the cluster
```

---

## First-time apply

After both PRs (this stack + the secret) land + merge:

1. Go to **Actions → terraform → Run workflow** (top-right)
2. Branch: `main`
3. Action: `apply`
4. Click **Run workflow**
5. The `apply` job pauses at the `production` environment gate — go to it, click Approve
6. Apply runs ~15-20 min (EKS cluster creation is the slow bit)

After it finishes, the outputs are uploaded as artifact `terraform-outputs-<run-id>` — download and grep for `bastion_instance_id`, `cluster_name`, etc.

---

## Connecting to the cluster

```sh
# 1. Local kubectl (from your laptop)
aws eks update-kubeconfig --name sbx-eks-01 --region us-east-1
kubectl get nodes

# 2. SSM into the bastion (no SSH key, IAM-gated)
aws ssm start-session --target i-<bastion-id> --region us-east-1
# Then on bastion:
aws eks update-kubeconfig --name sbx-eks-01 --region us-east-1
kubectl get pods -A

# 3. ArgoCD UI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo
kubectl -n argocd port-forward svc/argocd-server 8080:80
# open http://localhost:8080 — admin / <password>
```

---

## Tear-down

```
Actions → terraform → Run workflow → action: destroy → Approve at environment gate
```

Removes everything except the bootstrap stack's S3 bucket + DynamoDB + IAM role + GitHub repos. Run `terraform destroy` in `bootstrap/` last if you want a totally clean account.

---

## Conventions enforced

- `.gitignore` excludes `.terraform/` AND `.terraform.lock.hcl` (HARD RULE — both)
- Karpenter `do-not-disrupt` annotation on every long-lived control-plane pod (ArgoCD, Image Updater, netshoot) — same lesson as GCP `autopilot_pin_long_lived_pods`
- ECR pull-through cache for upstream images, never direct Docker Hub (rate limits)
- All AWS resources tagged `Project=sbx-eks-github` for cost tracking
- EKS Access Entries (modern API, NOT aws-auth ConfigMap) — required for Auto Mode

---

## Related

- Bootstrap: `github-terraform-aws/bootstrap/` — created this repo + the IAM role we use
- CI templates: `github-terraform-aws/sbx-ci-templates/build-templates/` — reusable workflow app repos call
- Beginner walkthrough: `IMPORTANT-FILES/Github-important-files/05-eks-auto-mode-explainer.md` (skeleton)
