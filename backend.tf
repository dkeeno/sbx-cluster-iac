# =============================================================================
# backend.tf — S3 state backend (created by the bootstrap stack)
# =============================================================================
#
# Bucket + lock table created by github-terraform-aws/bootstrap/. If you
# need to recreate them, run the bootstrap stack first then re-init here.
#
# Key: scoped per-stack so future stacks (e.g. monitoring, second cluster)
# don't collide.

terraform {
  backend "s3" {
    bucket         = "sbx-tfstate-784916389752-us-east-1"
    key            = "sbx-cluster-iac/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sbx-tfstate-locks"
    encrypt        = true
  }
}
