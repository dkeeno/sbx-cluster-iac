# =============================================================================
# outputs.tf — values you'll reference after apply
# =============================================================================

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API endpoint URL."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL for the cluster — used by IRSA service accounts."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "vpc_id" {
  description = "VPC the cluster lives in."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (where EKS Auto Mode worker ENIs land)."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (where internet-facing LBs would land)."
  value       = aws_subnet.public[*].id
}

output "bastion_instance_id" {
  description = "Bastion EC2 instance ID — pass to `aws ssm start-session --target`."
  value       = aws_instance.bastion.id
}

output "ecr_registry" {
  description = "ECR registry URL — used by app repos in their docker push commands."
  value       = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_app_repo_urls" {
  description = "Per-app ECR repo URLs."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "image_updater_role_arn" {
  description = "IAM role assumed by the Image Updater pod via IRSA."
  value       = aws_iam_role.image_updater.arn
}

output "argocd_namespace" {
  description = "Namespace ArgoCD lives in."
  value       = kubernetes_namespace.argocd.metadata[0].name
}

# -----------------------------------------------------------------------------
# Connect-here cheat sheet
# -----------------------------------------------------------------------------
output "next_steps" {
  description = "Connect to the cluster after apply."
  value       = <<-EOT

    # 1. Configure local kubectl (from your laptop)
    aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.aws_region}
    kubectl get nodes
    kubectl get pods -A

    # 2. Connect to the bastion via SSM
    aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}

    # 3. ArgoCD UI from your laptop (port-forward via SSM through bastion)
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d ; echo
    kubectl -n argocd port-forward svc/argocd-server 8080:80
    # Then open http://localhost:8080 — login: admin / password from above

    # 4. Image Updater logs (verify it's pulling ECR + watching the gitops repo)
    kubectl logs -n argocd deploy/argocd-image-updater -f

    # 5. Trigger a hands-off deploy (Phase 3 onwards)
    # Push a code change to dkeeno/sbx-online-shop main → CI pushes image to ECR
    # → Image Updater detects within ~1 min → commits to dkeeno/sbx-manifests
    # → ArgoCD syncs within ~30 sec → pods roll
  EOT
}
