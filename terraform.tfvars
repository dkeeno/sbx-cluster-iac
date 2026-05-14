# =============================================================================
# terraform.tfvars — committed values (no secrets)
# =============================================================================

aws_account_id = "784916389752"
aws_region     = "us-east-1"
name_prefix    = "sbx"

# ----- Network -----
vpc_cidr             = "10.0.0.0/16"
azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]

# ----- EKS -----
cluster_name       = "sbx-eks-01"
kubernetes_version = "1.31"

# Both the user that runs terraform locally AND the GH Actions role need
# cluster-admin via EKS Access Entries (the modern replacement for the
# aws-auth ConfigMap). Without these, no `kubectl` from either side works
# even though IAM gives them every AWS-side permission.
cluster_admin_principal_arns = [
  "arn:aws:iam::784916389752:user/agentic-ai-user",
  "arn:aws:iam::784916389752:role/sbx-github-actions",
]

# ----- Bastion -----
bastion_instance_type = "t3.medium"

# ----- ECR -----
ecr_repos = [
  "sbx-images/online-shop",
  "sbx-images/art-gallery",
]

ecr_pull_through_caches = {
  docker-hub = {
    upstream_registry_url = "public.ecr.aws"
  }
}
