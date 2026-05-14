# =============================================================================
# eks.tf — EKS Auto Mode cluster + access entries
# =============================================================================
#
# EKS Auto Mode (GA Dec 2024) ≈ "AWS-managed Karpenter + add-ons" — the
# closest AWS analog to GKE Autopilot. Key differences from EKS Standard:
#
#   - NO node groups to manage (Karpenter under the hood handles scaling)
#   - NO add-on installs needed for: VPC CNI, kube-proxy, CoreDNS,
#     EBS CSI, ALB controller (the last via the EKS-managed BlockStore /
#     LoadBalancer features). Less Helm noise downstream.
#   - Nodes scale from zero; you specify node_pools to control instance
#     types/AZs Karpenter is allowed to use.
#   - cluster_compute_config block is REQUIRED for Auto Mode.
#
# Endpoint mode (per user decision):
#   public + private — public IAM-gated, reachable from GitHub Actions
#   runners; private reachable from inside the VPC (bastion).
#
# Access entries (the modern aws-auth replacement — REQUIRED for Auto Mode):
#   We grant cluster-admin to:
#   1. The IAM user agentic-ai-user (for local kubectl from this machine)
#   2. The IAM role sbx-github-actions (for kubectl/Helm during CI applies)
#   Future: a role for the bastion would also need an access entry.

# -----------------------------------------------------------------------------
# IAM role for the EKS control plane itself
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# Auto Mode requires these additional managed policies on the cluster role
# so EKS can manage the underlying compute, storage, networking on your behalf.
resource "aws_iam_role_policy_attachment" "eks_compute_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_block_storage_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_load_balancing_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_networking_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# IAM role used by Auto Mode worker nodes (Karpenter spins them up)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.eks_node.name
}

# -----------------------------------------------------------------------------
# The cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  # Auto Mode — the magic block. node_pools=["general-purpose"] is the
  # default Karpenter pool that handles most workloads; you can add
  # "system" for bound-to-system-namespace pods.
  compute_config {
    enabled       = true
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.eks_node.arn
  }

  # Auto Mode also needs these enabled at the cluster level:
  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"] # IAM-gated; relax for sandbox
  }

  # Required by Auto Mode — switches the cluster off the legacy aws-auth
  # ConfigMap onto the modern EKS access-entry API.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_compute_policy,
    aws_iam_role_policy_attachment.eks_block_storage_policy,
    aws_iam_role_policy_attachment.eks_load_balancing_policy,
    aws_iam_role_policy_attachment.eks_networking_policy,
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_ecr,
  ]
}

# -----------------------------------------------------------------------------
# Access entries — modern replacement for aws-auth ConfigMap
# -----------------------------------------------------------------------------
# EKS Auto Mode cannot use the legacy ConfigMap. Each principal that needs
# to talk to the cluster API needs an access entry + a policy association.
#
# The cluster creator (whoever ran `aws_eks_cluster` first) gets implicit
# admin via bootstrap_cluster_creator_admin_permissions=true. We add
# explicit entries for the OTHER principals (GH Actions role, etc.) so
# they don't depend on which IAM identity ran terraform.

resource "aws_eks_access_entry" "admins" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins_cluster_admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}

# -----------------------------------------------------------------------------
# OIDC provider for IRSA (IAM Roles for Service Accounts)
# -----------------------------------------------------------------------------
# Cluster has its own OIDC issuer URL. Required for any pod in the cluster
# to assume an AWS IAM role (e.g. the Image Updater pod assuming a role
# with ECR read access).

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}
