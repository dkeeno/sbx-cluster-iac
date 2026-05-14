# =============================================================================
# versions.tf — Terraform + provider version pins
# =============================================================================
#
# Pinned conservatively. Matches the bootstrap stack's AWS + GitHub provider
# pins so a fleet-wide upgrade is one decision, not per-stack negotiation.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }

    # Provider that talks to the EKS cluster's k8s API. Used for k8s
    # resources (Namespaces, ServiceAccounts, the ArgoCD bootstrap
    # Application) that have no AWS counterpart.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.34"
    }

    # For installing ArgoCD, Image Updater via Helm charts.
    # v3 dropped the nested `kubernetes {}` block in favor of an attribute
    # `kubernetes = { ... }`. Provider behaviour is otherwise compatible
    # with our existing helm_release resources.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }

    # Used for raw kubectl-style YAML apply where the kubernetes provider
    # doesn't have a typed resource (e.g. CRDs, Gateway API objects).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }

    # Pulls additional details from EKS that the AWS provider doesn't
    # surface directly (e.g. cluster CA, tokens for short-lived auth).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}






