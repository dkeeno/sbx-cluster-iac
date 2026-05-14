# =============================================================================
# variables.tf — input declarations
# =============================================================================
#
# Values committed in terraform.tfvars (sandbox: nothing secret).

# ----- Project identity -----

variable "aws_account_id" {
  description = "12-digit AWS account ID. Used in resource ARNs and ECR registry URL."
  type        = string
}

variable "aws_region" {
  description = "AWS region for ALL resources in this stack."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for AWS resource names — e.g. \"sbx\". All Names + tags use this."
  type        = string
}

# ----- Network -----

variable "vpc_cidr" {
  description = "VPC CIDR. /16 allows ~65k IPs — plenty for sandbox."
  type        = string
}

variable "azs" {
  description = "Availability zones. 3 for HA-ish layout (single NAT in [0])."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "/24 public subnets, one per AZ. Hosts NAT Gateway + internal ALB ENIs."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "/24 private subnets, one per AZ. EKS Auto Mode places worker ENIs here."
  type        = list(string)
}

# ----- EKS -----

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Auto Mode requires >= 1.29."
  type        = string
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs (users + roles) granted cluster-admin via EKS access entries."
  type        = list(string)
}

# ----- Bastion -----

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion. t3.medium is enough for kubectl + helm + occasional terraform."
  type        = string
}

# ----- ECR -----

variable "ecr_repos" {
  description = "ECR repos to create for app images. Each gets immutable tags + scan-on-push."
  type        = list(string)
}

variable "ecr_pull_through_caches" {
  description = "ECR pull-through cache rules. Map key = upstream registry alias used in image URLs."
  type = map(object({
    upstream_registry_url = string
  }))
}
