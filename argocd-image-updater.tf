# =============================================================================
# argocd-image-updater.tf — Image Updater Helm release with ECR auth
# =============================================================================
#
# Watches ECR for new tags on images referenced by ArgoCD Applications.
# When a new tag matches the per-app allow-tags regex, IU commits a
# Kustomize image bump to the gitops repo. ArgoCD then syncs the new
# commit and rolls the pods. Hands-off CI/CD loop.
#
# AWS specifics for ECR auth:
#   1. IRSA: Image Updater pod assumes an IAM role to call ECR APIs.
#   2. The pod needs an aws CLI to call `aws ecr get-authorization-token`.
#      The chart's image (alpine + IU only) doesn't include aws CLI.
#      An initContainer copies aws CLI v2 from the official image into
#      an emptyDir volume both containers share. The main container's
#      PATH is extended to include the shared bin.
#   3. Image Updater config registers an `ext:` credentials script that
#      runs `aws ecr get-authorization-token` and outputs user:password
#      to stdout. IU re-runs the script every credsexpire (11h).
#
# Why initContainer + emptyDir vs custom IU image:
#   Custom image would need a build pipeline + ECR push + version
#   management. The initContainer approach lets us pin two off-the-shelf
#   images (IU chart default + amazon/aws-cli) without owning a Dockerfile.
#
# CHART VALUE NAME GOTCHA:
#   Chart uses `volumes:` / `volumeMounts:` (NOT `extraVolumes:` /
#   `extraVolumeMounts:`). My earlier attempt with the `extra*` variants
#   silently put the volumes nowhere — the initContainer's volumeMount
#   couldn't find them and the deployment failed with
#   "spec.template.spec.initContainers[0].volumeMounts[0].name: Not found".

# -----------------------------------------------------------------------------
# IRSA — IAM role + policy for ECR reads
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
# Helm release — Image Updater + aws-cli initContainer + ECR registry config
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
      # IRSA-bound SA — pod gets eks.amazonaws.com/role-arn annotation
      # so the AWS SDK in aws-cli picks up the IAM role automatically.
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

      # Image Updater config — registers ECR registry with an external
      # credentials script that uses the bundled aws CLI.
      config = {
        argocd = {
          insecure      = false
          plaintext     = false
          serverAddress = "argocd-server.argocd.svc.cluster.local:80"
        }
        registries = [{
          name        = "ecr"
          api_url     = "https://${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
          prefix      = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
          ping        = true
          credentials = "ext:/scripts/ecr-login.sh"
          credsexpire = "11h"
        }]
      }

      # Top-level volumes — these get APPENDED to the chart's existing
      # `volumes:` block via `with .Values.volumes`. (Chart key is
      # `volumes:` not `extraVolumes:`.)
      volumes = [
        {
          name     = "aws-cli-bin"
          emptyDir = {}
        },
        {
          name = "ecr-login-script"
          configMap = {
            name        = "argocd-image-updater-ecr-login"
            defaultMode = 493 # 0755
          }
        }
      ]

      # Mounts on the main IU container.
      volumeMounts = [
        {
          name      = "aws-cli-bin"
          mountPath = "/shared-bin"
        },
        {
          name      = "ecr-login-script"
          mountPath = "/scripts"
        }
      ]

      # initContainer copies the aws CLI v2 install into the shared
      # emptyDir so the main IU container can exec it via PATH.
      initContainers = [{
        name  = "install-aws-cli"
        image = "amazon/aws-cli:2.17.0"
        command = [
          "sh", "-c",
          "cp -r /usr/local/aws-cli /shared-bin/aws-cli && ln -sfn /shared-bin/aws-cli/v2/current/bin/aws /shared-bin/aws && echo done"
        ]
        volumeMounts = [{
          name      = "aws-cli-bin"
          mountPath = "/shared-bin"
        }]
      }]

      # Extend PATH so `aws` is found from /shared-bin without absolute paths
      extraEnv = [
        { name = "PATH", value = "/shared-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      # Sibling ConfigMap holding the ECR-login script.
      # IU calls it via `ext:/scripts/ecr-login.sh` — the script outputs
      # `AWS:<base64-decoded-token>` which IU treats as docker auth.
      extraObjects = [{
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name = "argocd-image-updater-ecr-login"
        }
        data = {
          "ecr-login.sh" = <<-EOT
            #!/bin/sh
            # IU expects user:password on stdout (one line). aws ecr
            # get-authorization-token returns a base64 of "AWS:<token>"
            # which IS the docker auth format IU wants.
            set -eu
            aws ecr get-authorization-token \
              --region ${var.aws_region} \
              --output text \
              --query 'authorizationData[].authorizationToken' \
              | base64 -d
          EOT
        }
      }]
    })
  ]

  depends_on = [
    helm_release.argocd,
    aws_iam_role_policy_attachment.image_updater_ecr,
  ]
}
