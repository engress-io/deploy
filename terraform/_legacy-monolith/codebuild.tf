# CodeBuild (DEPRECATED — disabled by default).
#
# Replaced by GitHub Actions (.github/workflows/ci.yml in the superproject).
# These IAM roles are gated by `enable_aws_ci` (default: false) and are never
# created unless explicitly enabled.

resource "aws_iam_role" "codebuild" {
  count = local.aws_ci_enabled ? 1 : 0

  name = "${var.name_prefix}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.aws_ci_enabled ? 1 : 0

  name = "${var.name_prefix}-codebuild-policy"
  role = aws_iam_role.codebuild[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name_prefix}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts[0].arn,
          "${aws_s3_bucket.pipeline_artifacts[0].arn}/*",
          aws_s3_bucket.downloads[0].arn,
          "${aws_s3_bucket.downloads[0].arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [
          aws_ecr_repository.edge.arn,
          aws_ecr_repository.api.arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/*"
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:CreateReportGroup",
          "codebuild:CreateReport",
          "codebuild:UpdateReport",
          "codebuild:BatchPutTestCases",
          "codebuild:BatchPutCodeCoverages",
        ]
        Resource = "arn:aws:codebuild:${var.aws_region}:${data.aws_caller_identity.current.account_id}:report-group/${var.name_prefix}-*"
      },
    ]
  })
}

locals {
  codebuild_env_common = {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  codebuild_env_vars = [
    { name = "AWS_REGION", value = var.aws_region },
    { name = "AWS_DEFAULT_REGION", value = var.aws_region },
    { name = "GOLANG_VERSION", value = "1.25" },
    { name = "ECR_EDGE_REPOSITORY", value = aws_ecr_repository.edge.repository_url },
    { name = "ECR_CORE_REPOSITORY", value = aws_ecr_repository.api.repository_url },
    { name = "ECR_API_REPOSITORY", value = aws_ecr_repository.api.repository_url },
    { name = "DOWNLOADS_BUCKET", value = local.downloads_bucket_name },
    { name = "GITHUB_REPOSITORY", value = "${local.github_owner}/${local.github_repo_name}" },
  ]
}

# CodeBuild projects removed — replaced by GitHub Actions (aws-ci.yml).
# The aws-ci.yml workflow now handles build + deploy end-to-end on push to main.
# Keeping the codebuild IAM role intact for other uses.
