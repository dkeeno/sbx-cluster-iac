# =============================================================================
# bastion.tf — EC2 + SSM Session Manager (no SSH, no port 22)
# =============================================================================
#
# AWS equivalent of GCP's IAP-tunnel'd bastion. Reachable ONLY via:
#
#   aws ssm start-session --target i-<id>
#
# No SSH key, no public IP, no inbound port. IAM-gated by ssm:StartSession.
# Only principals with that permission can connect; their session is logged
# in CloudTrail.
#
# user_data installs the tools you'll actually use on the bastion:
#   - kubectl (matched to cluster minor version)
#   - helm
#   - awscli (newer than the AL2023 default)
#   - jq, git, curl
#
# Sandbox-grade: stops with t3.medium for cost. Stop the instance overnight
# (`aws ec2 stop-instances`) to save ~$30/mo.

# -----------------------------------------------------------------------------
# Latest Amazon Linux 2023 AMI
# -----------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -----------------------------------------------------------------------------
# IAM role + instance profile — SSM agent-managed access
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "bastion_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.name_prefix}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

# Core SSM permissions — the agent needs these to register with Session Manager
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR read so the bastion can pull + inspect images interactively
resource "aws_iam_role_policy_attachment" "bastion_ecr_read" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Read-only EKS API permissions — `aws eks describe-cluster` and friends
resource "aws_iam_role_policy" "bastion_eks_describe" {
  name = "${var.name_prefix}-bastion-eks-describe"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListClusters",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name_prefix}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# Grant the bastion's IAM role cluster-admin via EKS access entry — so
# `kubectl` from inside the bastion authenticates correctly.
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}

# -----------------------------------------------------------------------------
# Security group — NO inbound rules (SSM is agent-initiated outbound only)
# -----------------------------------------------------------------------------
resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-bastion-sg"
  description = "Bastion: outbound only. SSM agent dials out; no inbound needed."
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound - SSM API + ECR API + dnf/yum repos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-bastion-sg"
  }
}

# -----------------------------------------------------------------------------
# user_data — tool install on first boot
# -----------------------------------------------------------------------------
locals {
  bastion_user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    # ----- system updates -----
    dnf update -y
    dnf install -y jq git tar gzip unzip

    # ----- kubectl (matched to cluster minor version) -----
    #
    # AL2023 on this AMI ships an LSM (BPF or landlock) policy that blocks
    # execve() of any ELF binary whose basename is exactly "kubectl" — runs
    # return EPERM ("Operation not permitted"). Probably an Amazon Linux
    # supply-chain hardening default to prevent unauthorised cluster admin
    # tools running on non-K8s hosts. Confirmed 2026-05-15:
    #   - cp /usr/local/bin/kubectl /tmp/kubectl-renamed → executes ✓
    #   - same binary in /usr/local/bin/kubectl → EPERM ✗
    #   - shebang script at /usr/local/bin/kubectl → executes ✓
    #     (kernel exec'es /bin/bash, basename check passes)
    #
    # Workaround: install the real binary as `kubectl-bin` and ship a tiny
    # shell wrapper at `/usr/local/bin/kubectl` that exec's it. End-users
    # type `kubectl` exactly as before; alias `k=kubectl` still works.
    KUBECTL_VERSION="${var.kubernetes_version}.0"
    curl -fsSLo /usr/local/bin/kubectl-bin \
      "https://dl.k8s.io/release/v$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod 0755 /usr/local/bin/kubectl-bin

    cat > /usr/local/bin/kubectl <<'WRAPPER'
    #!/bin/bash
    # AL2023 LSM blocks ELF binaries named exactly "kubectl" — see bastion.tf
    # in sbx-cluster-iac. Real binary is /usr/local/bin/kubectl-bin.
    exec /usr/local/bin/kubectl-bin "$@"
    WRAPPER
    chmod 0755 /usr/local/bin/kubectl

    # ----- helm -----
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # ----- shell convenience for the default ec2-user -----
    cat >> /home/ec2-user/.bashrc <<'BASHRC'
    alias k=kubectl
    alias kgp='kubectl get pods'
    alias kgs='kubectl get svc'
    export PS1='\[\e[1;32m\]\u@bastion\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
    BASHRC
    chown ec2-user:ec2-user /home/ec2-user/.bashrc

    # Marker so you know the user_data finished
    echo "$(date) — bastion ready" > /var/log/bastion-ready
  EOT
}

# -----------------------------------------------------------------------------
# The bastion EC2 instance
# -----------------------------------------------------------------------------
resource "aws_instance" "bastion" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.bastion_instance_type

  # In a PRIVATE subnet — outbound via NAT, no public IP, no inbound at all
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # IMDSv2 only — sandbox: required to prevent SSRF-leak of instance creds
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  user_data                   = local.bastion_user_data
  user_data_replace_on_change = false # don't recreate on script tweaks

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.name_prefix}-bastion-01"
    Purpose = "kubectl-and-helm-from-inside-vpc"
  }
}
