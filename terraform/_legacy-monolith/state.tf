# Remote state bucket already exists for this account (see backend.tf).
# S3 native locking (use_lockfile) — no DynamoDB table required.
# Set manage_terraform_state_backend=true only for greenfield bootstrap:
#   terraform apply -var="manage_terraform_state_backend=true" -target='aws_s3_bucket.terraform_state[0]' ...

variable "manage_terraform_state_backend" {
  type        = bool
  description = "Create S3 state bucket (one-time; leave false when bucket already exists)"
  default     = false
}

locals {
  terraform_state_bucket_name = "engress-terraform-state-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "terraform_state" {
  count  = var.manage_terraform_state_backend ? 1 : 0
  bucket = local.terraform_state_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name    = "engress-terraform-state"
    Purpose = "terraform-remote-state"
  })
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  count  = var.manage_terraform_state_backend ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  count  = var.manage_terraform_state_backend ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  count  = var.manage_terraform_state_backend ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_s3_bucket" "terraform_state" {
  count  = var.manage_terraform_state_backend ? 0 : 1
  bucket = local.terraform_state_bucket_name
}

output "terraform_state_bucket" {
  value       = var.manage_terraform_state_backend ? aws_s3_bucket.terraform_state[0].id : data.aws_s3_bucket.terraform_state[0].id
  description = "S3 bucket for Terraform remote state (backend.tf)"
}
