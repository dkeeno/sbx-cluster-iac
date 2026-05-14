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

# Use cluster RESOURCE attributes directly (not via data source). Terraform
# evaluates resource attributes during refresh; data sources with depends_on
# can be deferred and return empty, causing the kubernetes provider to fall
# back to "host = localhost" -> connection refused.
#
# exec auth re-runs `aws eks get-token` on every k8s API call so the token
# is always fresh.

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.aws_region]
  }
}
