# GitHub-primary source control for EC2 clone, CodePipeline, and Amplify.

locals {
  aws_ci_enabled         = var.enable_aws_ci
  github_repo_normalized = trimsuffix(replace(trimspace(var.github_repo), "https://github.com/", ""), ".git")
  github_owner           = split("/", local.github_repo_normalized)[0]
  github_repo_name       = split("/", local.github_repo_normalized)[1]
  github_clone_url       = "https://github.com/${local.github_owner}/${local.github_repo_name}.git"
  deploy_branch          = trimspace(var.github_branch) != "" ? trimspace(var.github_branch) : "main"
  github_ssm_arn         = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.github_token_ssm_parameter}"
  github_oidc_sub        = "repo:engress-io/*"
}

data "aws_ssm_parameter" "github_read_token" {
  name = var.github_token_ssm_parameter
}

output "github_clone_url" {
  value       = local.github_clone_url
  description = "HTTPS clone URL for the GitHub repository (use SSM PAT on EC2 via scripts/deploy/lib/clone-private.sh)"
}

output "github_repository" {
  value       = "${local.github_owner}/${local.github_repo_name}"
  description = "GitHub owner/repo slug"
}

output "github_branch" {
  value       = local.deploy_branch
  description = "Git branch deployed on EC2 and CI pipelines"
}

# GitHub OIDC provider for GitHub Actions → AWSAssumeRoleWithWebIdentity
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Deploy role for GitHub Actions (release pipelines, EC2 deploys)
resource "aws_iam_role" "github_deploy" {
  name = "engress-github-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.github_oidc_sub
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "engress-github-deploy-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetObject"
        ]
        Resource = [
          "arn:aws:s3:::flux-downloads-327796148992",
          "arn:aws:s3:::flux-downloads-327796148992/*",
          "arn:aws:s3:::flux-spa-327796148992",
          "arn:aws:s3:::flux-spa-327796148992/*",
          "arn:aws:s3:::flux-docs-327796148992",
          "arn:aws:s3:::flux-docs-327796148992/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetInvalidation",
          "cloudfront:ListInvalidations"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommands"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:us-east-2:327796148992:parameter/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
        ]
        Resource = [
          "arn:aws:ssm:us-east-2:327796148992:parameter/engress-deploy-*",
          "arn:aws:ssm:us-east-2:327796148992:parameter/clerk-secret-key",
          "arn:aws:ssm:us-east-2:327796148992:parameter/next-clerk-publishable-key",
          "arn:aws:ssm:us-east-2:327796148992:parameter/clerk-webhook-secret",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:DescribeClusterVersions",
          "eks:AccessKubernetesApi",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:GetPolicy",
          "iam:CreateRole",
          "iam:GetRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:AttachRolePolicy",
          "iam:PutRolePolicy",
          "iam:PassRole",
          "iam:TagRole",
          "iam:CreateServiceLinkedRole",
          "iam:GetOpenIDConnectProvider",
          "iam:CreateOpenIDConnectProvider",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "sts:GetCallerIdentity"
        Resource = "*"
      }
    ]
  })
}

output "github_deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "ARN of the GitHub Actions deploy role (also in SSM engress-deploy-github-role-arn; may be a GitHub repo variable, not a secret)"
}
