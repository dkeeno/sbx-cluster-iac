# =============================================================================
# netshoot.tf — persistent debug pod in default namespace
# =============================================================================
#
# Always-on pod with the netshoot toolkit (curl, dig, nslookup, tcpdump,
# nmap, etc.). Use it for ad-hoc network diagnostics:
#
#   kubectl exec -it -n default deploy/netshoot -- /bin/bash
#   # then: curl, dig, etc.
#
# Same pattern as the GCP project's `netshoot.tf`. Beats spinning up
# `kubectl run` throwaway pods — the persistent one survives long enough
# to do iterative debugging.
#
# IMPORTANT: pin against Karpenter consolidation. Without the annotation,
# Auto Mode evicts under-utilized nodes ~every 10-30 min, killing any
# `kubectl exec -it` session you're in. Same lesson as
# autopilot_pin_long_lived_pods on GCP.

resource "kubernetes_deployment" "netshoot" {
  metadata {
    name      = "netshoot"
    namespace = "default"
    labels = {
      app          = "netshoot"
      "managed-by" = "terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "netshoot"
      }
    }

    template {
      metadata {
        labels = {
          app = "netshoot"
        }

        annotations = {
          # Pin against Karpenter consolidator. Without this, Auto Mode
          # drains the node ~every 10-20 min, killing the exec session.
          "karpenter.sh/do-not-disrupt" = "true"
        }
      }

      spec {
        # Distroless-style: low priority, low resources, but always running
        container {
          name  = "netshoot"
          image = "nicolaka/netshoot:v0.13"

          # Sleep forever so the pod stays Running and ready for `kubectl exec`
          command = ["sleep", "infinity"]

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }

        # No persistence; the pod is a clean slate every restart
        restart_policy = "Always"
      }
    }
  }

  depends_on = [aws_eks_cluster.this]
}
