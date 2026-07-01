# CodePipeline (DEPRECATED — disabled by default).
#
# Replaced by GitHub Actions (.github/workflows/ci.yml in the superproject).
# These resources are gated by `enable_aws_ci` (default: false) and are never
# created unless explicitly enabled. Kept for reference during transition.

locals {
  pipeline_artifacts_bucket_name = var.pipeline_artifacts_bucket_name != "" ? var.pipeline_artifacts_bucket_name : "${var.name_prefix}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = local.pipeline_artifacts_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = aws_s3_bucket.pipeline_artifacts[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = aws_s3_bucket.pipeline_artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = aws_s3_bucket.pipeline_artifacts[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  count = local.aws_ci_enabled ? 1 : 0

  name = "${var.name_prefix}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "codepipeline" {
  count = local.aws_ci_enabled ? 1 : 0

  name = "${var.name_prefix}-codepipeline-policy"
  role = aws_iam_role.codepipeline[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:PutObject",
          "s3:PutObjectAcl",
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts[0].arn,
          "${aws_s3_bucket.pipeline_artifacts[0].arn}/*",
        ]
      },
    ]
  })
}

# CodePipeline resources removed — replaced by GitHub Actions (aws-ci.yml).
# The aws-ci.yml workflow now handles build + deploy end-to-end on push to main.
# Keeping the pipeline_artifacts S3 bucket and IAM roles intact for other uses.
