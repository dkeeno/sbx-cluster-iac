# =============================================================================
# ingress.tf — IngressClass + IngressClassParams enforcing ONE shared ALB
# =============================================================================
#
# HARD RULE (feedback_one_shared_alb.md): every Ingress on this cluster
# must share ONE internal ALB. Per-Ingress `group.name` annotations are
# unreliable (race conditions on simultaneous Ingress creation); enforce
# at the IngressClass level via IngressClassParams.spec.group.name.
#
# Default class is set to true — apps in sbx-manifests don't need to
# specify ingressClassName; they get this one automatically and inherit
# the shared-ALB grouping.

# IngressClassParams: forces group + scheme on every Ingress using class `alb`
resource "kubectl_manifest" "ingress_class_params" {
  yaml_body = yamlencode({
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "IngressClassParams"
    metadata = {
      name = "alb-shared"
      labels = {
        "managed-by" = "terraform"
      }
    }
    spec = {
      scheme = "internal"
      group = {
        name = "sbx-shared"
      }
    }
  })

  depends_on = [aws_eks_cluster.this]
}

resource "kubernetes_ingress_class_v1" "alb" {
  metadata {
    name = "alb"
    annotations = {
      "ingressclass.kubernetes.io/is-default-class" = "true"
    }
    labels = {
      "managed-by" = "terraform"
    }
  }

  spec {
    controller = "eks.amazonaws.com/alb"

    parameters {
      api_group = "eks.amazonaws.com"
      kind      = "IngressClassParams"
      name      = "alb-shared"
    }
  }

  depends_on = [kubectl_manifest.ingress_class_params]
}
