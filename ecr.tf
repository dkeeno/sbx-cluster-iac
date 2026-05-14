# =============================================================================
# ecr.tf — single ECR repository for ALL sandbox app images
# =============================================================================
#
# HARD RULE (feedback_single_ecr_repo.md): one ECR repo for the whole
# sandbox. Per-app discrimination is in the TAG, not in separate repos.
#
# Image URLs:
#   <account>.dkr.ecr.us-east-1.amazonaws.com/sbx-images:online-shop-<sha>
#   <account>.dkr.ecr.us-east-1.amazonaws.com/sbx-images:art-gallery-<sha>
#   <account>.dkr.ecr.us-east-1.amazonaws.com/sbx-images:online-shop-latest
#
# Lifecycle policy: keep last 30 tagged images, expire untagged after 7
# days. Single set of rules for the whole sandbox.
#
# Pull-through cache: lets the cluster pull `public.ecr.aws/<repo>:<tag>`
# images THROUGH a local cache, getting cached after first pull.

# -----------------------------------------------------------------------------
# Single app-image repository
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "images" {
  name                 = "sbx-images"
  image_tag_mutability = "MUTABLE" # `latest` per app gets overwritten on each push

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Sandbox: allow terraform destroy to nuke the repo even if it has images
  force_delete = true

  tags = {
    Name = "sbx-images"
  }
}

resource "aws_ecr_lifecycle_policy" "images" {
  repository = aws_ecr_repository.images.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 tagged images (across all apps)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Pull-through cache rules
# -----------------------------------------------------------------------------
resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each = var.ecr_pull_through_caches

  ecr_repository_prefix = each.key
  upstream_registry_url = each.value.upstream_registry_url
}
