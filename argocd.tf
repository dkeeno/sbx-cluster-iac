# =============================================================================
# argocd.tf — ArgoCD Helm release + bootstrap Application + GitHub credentials
# =============================================================================
#
# Same chart, same version family as the GCP project. AWS-specific bits:
#
# 1. Service type ClusterIP (NOT internal NLB) — access via SSM port-
#    forward to the bastion. Matches the dev-eks-project convention and
#    avoids a 2nd ALB just for the UI.
#
# 2. Repo credential Secret holds the GitHub PAT (not GitLab token). The
#    PAT lives in our local env (~/.mcp-servers/github-mcp-server/.env)
#    and gets injected via Terraform var → k8s Secret.
#
# 3. NAP-equivalent eviction protection — Karpenter under Auto Mode
#    consolidates underused nodes. Add safe-to-evict=false to keep
#    ArgoCD's UI WebSocket + repo-server caches alive across consolidator
#    cycles. Same lesson as GCP `autopilot_pin_long_lived_pods`.
#
# 4. The bootstrap Application is the "app of apps" — points at the
#    sbx-manifests gitops repo's argocd-apps/ folder. ArgoCD reads the
#    ApplicationSet YAML there, generates per-app Applications, syncs
#    them. Same pattern as sbx-02.

# -----------------------------------------------------------------------------
# Inputs not in variables.tf — keeps the secret-handling local
# -----------------------------------------------------------------------------
variable "github_pat_for_argocd" {
  description = "GitHub PAT with read access to the sbx-manifests repo. Sourced from GITHUB_TOKEN env var via TF_VAR_github_pat_for_argocd."
  type        = string
  sensitive   = true
}

variable "gitops_repo_url" {
  description = "Full HTTPS URL of the gitops repo ArgoCD reads. e.g. https://github.com/dkeeno/sbx-manifests.git"
  type        = string
  default     = "https://github.com/dkeeno/sbx-manifests.git"
}

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "managed-by" = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Helm release — argo-cd chart
# -----------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.5" # pin — bump deliberately

  # 12 min — Auto Mode needs ~2 min to provision the first Karpenter node before
  # any pod can schedule. Then ArgoCD's 5 pods (controller, server, repo-server,
  # redis, applicationset-controller) image-pull + start. 5 min was too tight.
  timeout = 720
  wait    = true

  values = [
    yamlencode({
      global = {
        # Annotations applied to every chart-managed pod. Pin against
        # Karpenter consolidation so UI WebSockets + caches survive.
        podAnnotations = {
          "karpenter.sh/do-not-disrupt" = "true"
        }
      }

      configs = {
        params = {
          # Sandbox: --insecure means no TLS on argocd-server. We access
          # via SSM port-forward over loopback, so the cleartext is local-
          # only. Production: enable TLS via cert-manager + Let's Encrypt.
          "server.insecure" = true
        }

        # Tighten the git poll interval. Default 3 min; we want < 1 min
        # so the Image Updater commit lands in pods quickly.
        cm = {
          "timeout.reconciliation" = "30s"
        }
      }

      controller = {
        # Run as 1 replica for sandbox. Production uses 2-3 with sharding.
        replicas = 1
      }

      server = {
        # ClusterIP — access via `kubectl port-forward` from bastion or
        # via SSM port-forward from laptop. NOT exposed via internal ALB
        # (saves an LB + simpler initial bringup).
        service = {
          type = "ClusterIP"
        }
      }

      # Image Updater write-back uses git push to gitops repo via PAT.
      # No further config needed here — the repo credential secret below
      # is what ArgoCD reads.

      # Disable dex (no SSO for sandbox). 1 less pod, 1 less thing to break.
      dex = {
        enabled = false
      }

      # Notifications: off in sandbox. Add later if we want Slack/PagerDuty.
      notifications = {
        enabled = false
      }
    })
  ]

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_access_policy_association.admins_cluster_admin,
  ]
}

# -----------------------------------------------------------------------------
# Repo credential — GitHub PAT for sbx-manifests
# -----------------------------------------------------------------------------
# ArgoCD reads any Secret in the argocd namespace labeled
# argocd.argoproj.io/secret-type=repository as a repo credential.
resource "kubernetes_secret" "gitops_repo_credentials" {
  metadata {
    name      = "argocd-repo-credentials-sbx-manifests"
    namespace = kubernetes_namespace.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = "git" # any non-empty string works; PAT goes in password
    password = var.github_pat_for_argocd
  }

  type = "Opaque"

  depends_on = [helm_release.argocd]
}

# -----------------------------------------------------------------------------
# Bootstrap Application — the "app of apps" entry point
# -----------------------------------------------------------------------------
# Points ArgoCD at the gitops repo's argocd-apps/ folder. ArgoCD then
# discovers the ApplicationSet there and generates per-app Applications.
resource "kubectl_manifest" "bootstrap_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "bootstrap"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      labels = {
        "managed-by" = "terraform"
      }
      finalizers = [
        # Cascade-delete child resources when the bootstrap App is deleted.
        "resources-finalizer.argocd.argoproj.io"
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "HEAD"
        path           = "argocd-apps"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.gitops_repo_credentials,
  ]
}
