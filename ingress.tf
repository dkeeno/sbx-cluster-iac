# =============================================================================
# ingress.tf — IngressClass routing Ingress resources to EKS Auto Mode's
# built-in AWS Load Balancer Controller (ALB).
# =============================================================================
#
# Without this, Ingress resources have no controller to provision the ALB
# and stay in <pending> forever. Mirrors the loadBalancerClass requirement
# we hit on the ArgoCD NLB Service.
#
# Default class is set to true — apps in sbx-manifests don't need to
# specify ingressClassName; they get this one automatically.

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
  }

  depends_on = [aws_eks_cluster.this]
}
