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

# exec auth is more robust than data.aws_eks_cluster_auth.token — the token
# approach refreshes only when the data source is re-evaluated, and Terraform
# can use a stale token across plan/apply cycles. exec re-runs `aws eks get-token`
# on EVERY API call, always getting a fresh token.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}
