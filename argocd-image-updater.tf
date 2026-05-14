# =============================================================================
# argocd-image-updater.tf — Image Updater Helm release + IRSA for ECR
# =============================================================================
#
# Watches ECR for new tags on images referenced by ArgoCD Applications.
# When a new tag matches the allow-tags regex, it commits a Kustomize
# image bump to the gitops repo. ArgoCD then syncs the new commit and
# rolls the pods. Hands-off CI/CD loop.
#
# Same Helm chart as GCP. AWS-specific differences:
#
# 1. IRSA — Image Updater pod assumes an IAM role to read ECR. Replaces
#    GCP's Workload Identity binding. Uses the cluster's OIDC provider
#    we created in eks.tf.
#
# 2. Auth to git — uses the SAME GitHub PAT secret ArgoCD does (declared
#    in argocd.tf). Image Updater's `git-credentials` reference points
#    at it via repo URL match.
#
# 3. write-back-method=git — committed convention (not configurable per
#    chart value here; set per-Application via annotation in the AppSet
#    in Phase 4 manifests).
#
# 4. NAP-equivalent eviction protection — same safe-to-evict annotation
#    as ArgoCD pods.

# -----------------------------------------------------------------------------
# IRSA — IAM role + policy for ECR reads
# -----------------------------------------------------------------------------
# Image Updater needs ecr:GetAuthorizationToken (account-wide), and
# ecr:DescribeImages / ListImages on the specific repos it tracks.

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

# Sandbox: just attach the AWS-managed read-only ECR policy. Production
# would scope to specific repos using a custom policy.
resource "aws_iam_role_policy_attachment" "image_updater_ecr" {
  role       = aws_iam_role.image_updater.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# -----------------------------------------------------------------------------
# Helm release — argocd-image-updater chart
# -----------------------------------------------------------------------------
resource "helm_release" "image_updater" {
  name       = "argocd-image-updater"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = "0.11.0" # pin

  # 8 min — single pod, but Auto Mode node provisioning + image pull adds time
  timeout = 480
  wait    = true

  values = [
    yamlencode({
      # Bind the chart's ServiceAccount to the IRSA IAM role. This is what
      # makes the pod-side ECR auth work.
      serviceAccount = {
        create = true
        name   = "argocd-image-updater"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.image_updater.arn
        }
      }

      # Pin against Karpenter consolidation
      podAnnotations = {
        "karpenter.sh/do-not-disrupt" = "true"
      }

      config = {
        # Tighten the registry poll interval. Default 2 min; we want fast
        # detection so pods roll within ~3 min of CI image push.
        argocd = {
          insecure  = false
          plaintext = false
          # In-cluster talks to argocd-server via ClusterIP — no TLS round-trip
          serverAddress = "argocd-server.argocd.svc.cluster.local:80"
        }

        # ECR registry config — Image Updater uses the IRSA role to call
        # ecr:GetAuthorizationToken for the docker pull.
        registries = [{
          name        = "ecr"
          api_url     = "https://${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
          prefix      = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
          ping        = true
          credentials = "ext:/scripts/ecr-login.sh"
          credsexpire = "10h"
        }]
      }

      # Mount a tiny shell script that calls `aws ecr get-login-password`
      # to get a fresh ECR token. The script runs inside the pod, picks
      # up IRSA-injected AWS creds via the SDK, and prints user:pass to
      # stdout in the format Image Updater expects.
      extraObjects = [
        {
          apiVersion = "v1"
          kind       = "ConfigMap"
          metadata = {
            name = "argocd-image-updater-scripts"
          }
          data = {
            "ecr-login.sh" = <<-EOT
              #!/bin/sh
              # Output: user:pass on stdout (one line). Image Updater treats
              # the entire stdout as the docker auth string.
              aws ecr get-authorization-token --region ${var.aws_region} \
                --output text --query 'authorizationData[].authorizationToken' \
                | base64 -d
            EOT
          }
        }
      ]

      # Mount the ConfigMap script + install awscli on first pod start
      # via a tiny initContainer. The default chart image is alpine-based
      # without aws CLI.
      initContainers = [
        {
          name  = "install-aws-cli"
          image = "amazon/aws-cli:2.17.0"
          command = [
            "/bin/sh", "-c",
            "cp /usr/local/aws-cli/v2/current/bin/aws /shared-bin/aws && cp -r /usr/local/aws-cli/v2/current/dist /shared-bin/dist"
          ]
          volumeMounts = [{
            name      = "shared-bin"
            mountPath = "/shared-bin"
          }]
        }
      ]

      extraVolumes = [
        {
          name     = "shared-bin"
          emptyDir = {}
        },
        {
          name = "scripts"
          configMap = {
            name        = "argocd-image-updater-scripts"
            defaultMode = 493 # 0755
          }
        }
      ]

      extraVolumeMounts = [
        {
          name      = "shared-bin"
          mountPath = "/usr/local/bin/aws-cli"
        },
        {
          name      = "scripts"
          mountPath = "/scripts"
        }
      ]

      extraEnv = [
        # Make the bundled awscli usable from PATH
        { name = "PATH", value = "/usr/local/bin/aws-cli:/usr/local/bin:/usr/bin:/bin" },
        # IRSA token path — chart picks this up automatically but explicit doesn't hurt
        { name = "AWS_REGION", value = var.aws_region },
      ]
    })
  ]

  depends_on = [
    helm_release.argocd,
    aws_iam_role_policy_attachment.image_updater_ecr,
  ]
}
