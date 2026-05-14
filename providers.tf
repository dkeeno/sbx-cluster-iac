# =============================================================================
# providers.tf — provider configuration
# =============================================================================
#
# AWS — credentials from the standard chain (AWS_PROFILE, env vars, or
# the IAM role assumed via OIDC in CI).
#
# Kubernetes / Helm / kubectl — point at the EKS cluster created in
# eks.tf using the cluster's API endpoint + CA + a short-lived token from
# `aws_eks_cluster_auth`. Token is regenerated on every plan/apply.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "sbx-eks-github"
      ManagedBy = "terraform"
      Stack     = "sbx-cluster-iac"
    }
  }
}

# Pull cluster info AFTER eks.tf creates it. data sources lazy-resolve at
# apply time so this works on a clean apply.
data "aws_eks_cluster" "this" {
  name       = aws_eks_cluster.this.name
  depends_on = [aws_eks_cluster.this]
}

data "aws_eks_cluster_auth" "this" {
  name       = aws_eks_cluster.this.name
  depends_on = [aws_eks_cluster.this]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}
