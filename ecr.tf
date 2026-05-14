# =============================================================================
# ecr.tf — ECR repos for app images + pull-through cache rules
# =============================================================================
#
# One ECR repo per image. The `sbx-images/online-shop` namespace pattern
# matches the GitLab AR convention (`sbx-images/<app>`) and the
# IMAGE_REPO format hardcoded in the build-and-push reusable workflow.
#
# Lifecycle policy: keep the 30 most recent tagged images, expire untagged
# after 7 days. Sandbox-friendly; bigger projects would set lower numbers
# to control storage cost (~$0.10/GB/mo).
#
# Pull-through cache: lets the cluster pull `public.ecr.aws/<repo>:<tag>`
# images THROUGH the local registry, getting cached after first pull.
# Bandwidth + reliability win, no Docker Hub pull rate limits.

# -----------------------------------------------------------------------------
# App image repos
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  for_each = toset(var.ecr_repos)

  name                 = each.key
  image_tag_mutability = "MUTABLE" # `latest` tag gets overwritten on every push

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Sandbox: allow terraform destroy to nuke the repo even if it has images
  force_delete = true

  tags = {
    Name = each.key
  }
}

# -----------------------------------------------------------------------------
# Lifecycle policy — same for every app repo
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 tagged images"
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
# Cache rule maps a local namespace (the key) to an upstream registry URL.
# After this exists, you can `docker pull <account>.dkr.ecr.<region>.amazonaws.com/<key>/<image>:<tag>`
# and ECR will fetch from upstream + cache automatically.
resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each = var.ecr_pull_through_caches

  ecr_repository_prefix = each.key
  upstream_registry_url = each.value.upstream_registry_url
}
