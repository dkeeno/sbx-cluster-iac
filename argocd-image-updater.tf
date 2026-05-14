# =============================================================================
# argocd-image-updater.tf — Image Updater Helm release + IRSA for ECR
# =============================================================================
#
# WORK IN PROGRESS — for the v1 cluster bringup, the IRSA role is created
# but the Helm release config is intentionally minimal: no ECR registry
# configuration yet. Reason: the chart's initContainer + extraVolumes
# pattern doesn't merge volumes into the same pod spec the initContainer
# expects (Kubernetes admission rejects with "spec.template.spec.initContainers
# [0].volumeMounts[0].name: Not found"). Need a custom image with aws-cli
# baked in OR a different ECR auth scheme. Defer to phase 2.5.
#
# What works in this v1:
# - IRSA role exists, ECR read policy attached, SA annotation set
# - Image Updater pod runs and watches ArgoCD Applications
# - But it has no ECR registry registered, so it won't bump ECR images
#
# Until we fix this, image bumps in the gitops repo are manual:
#   sed -i 's/newTag: .*/newTag: '"$NEW_SHA"'/' overlays/dev/kustomization.yaml
#   git commit -m "bump online-shop to <sha>" && git push

# -----------------------------------------------------------------------------
# IRSA — IAM role + policy for ECR reads (will be used once ECR config wired)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "image_updater_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-image-updater"]
    }
  }
}

resource "aws_iam_role" "image_updater" {
  name               = "${var.cluster_name}-image-updater"
  assume_role_policy = data.aws_iam_policy_document.image_updater_assume.json
}

resource "aws_iam_role_policy_attachment" "image_updater_ecr" {
  role       = aws_iam_role.image_updater.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# -----------------------------------------------------------------------------
# Helm release — minimal install for now
# -----------------------------------------------------------------------------
resource "helm_release" "image_updater" {
  name       = "argocd-image-updater"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = "0.11.0"

  timeout = 480
  wait    = true

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "argocd-image-updater"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.image_updater.arn
        }
      }

      podAnnotations = {
        "karpenter.sh/do-not-disrupt" = "true"
      }

      # Talk to argocd-server in-cluster (ClusterIP service)
      config = {
        argocd = {
          insecure      = false
          plaintext     = false
          serverAddress = "argocd-server.argocd.svc.cluster.local:80"
        }
        # registries: [] — phase 2.5 will add ECR config once aws-cli
        # available in the IU pod.
      }
    })
  ]

  depends_on = [
    helm_release.argocd,
    aws_iam_role_policy_attachment.image_updater_ecr,
  ]
}
