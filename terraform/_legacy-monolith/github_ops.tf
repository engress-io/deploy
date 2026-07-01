# Extra IAM for GitHub Actions ops workflow (terraform, EKS, cluster add-ons).
# Attached to engress-github-deploy-role alongside github_deploy policy.

data "aws_iam_policy_document" "github_ops" {
  statement {
    sid    = "TerraformStateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::engress-terraform-state-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::engress-terraform-state-${data.aws_caller_identity.current.account_id}/*",
    ]
  }

  statement {
    sid    = "SSMDeployConfigWrite"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-deploy-*",
    ]
  }

  statement {
    sid    = "SSMClerkKeysWrite"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/clerk-secret-key",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/next-clerk-publishable-key",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/clerk-webhook-secret",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "eks:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "TerraformInfraMultiRegion"
    effect = "Allow"
    actions = [
      "ec2:*",
      "iam:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "logs:*",
      "kms:*",
      "cloudformation:*",
      "acm:*",
      "route53:*",
      "globalaccelerator:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region, "us-east-1", "us-west-1"]
    }
  }
}

resource "aws_iam_role_policy" "github_ops" {
  name   = "engress-github-ops-policy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_ops.json
}
