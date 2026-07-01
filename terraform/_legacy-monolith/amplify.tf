# Amplify Hosting — SPA + /api/* proxy + /downloads/* rewrite (optional).

locals {
  amplify_enabled = local.aws_ci_enabled && var.enable_amplify
}

resource "aws_amplify_app" "flux" {
  count = local.amplify_enabled ? 1 : 0

  name         = var.name_prefix
  repository   = local.github_clone_url
  access_token = data.aws_ssm_parameter.github_read_token.value

  platform = "WEB"

  # Repo-root amplify.yml builds the SPA. Docs are built from engress-io/docs.
  build_spec = file("${path.module}/../../amplify.yml")

  # /api/* → edge origin (same hostname CloudFront uses in frontend.tf).
  custom_rule {
    source = "/api/<*>"
    target = "https://${local.edge_origin_hostname}/api/<*>"
    status = "200"
  }

  # /downloads/* → private S3 via CloudFront (see downloads.tf).
  custom_rule {
    source = "/downloads/<*>"
    target = "https://${aws_cloudfront_distribution.downloads[0].domain_name}/<*>"
    status = "200"
  }

  # SPA deep-link fallback.
  custom_rule {
    source = "/<*>"
    target = "/index.html"
    status = "404-200"
  }

  tags = var.tags
}

resource "aws_amplify_branch" "main" {
  count = local.amplify_enabled ? 1 : 0

  app_id      = aws_amplify_app.flux[0].id
  branch_name = local.deploy_branch

  enable_auto_build = true
  framework         = "React"

  tags = var.tags
}

# Custom domain is served by frontend.tf CloudFront (stable CNAME — cloudfront_domain
# output). Do not use aws_amplify_domain_association: each create issues a new
# CloudFront target and forces repeated DNS churn in Squarespace.

output "amplify_app_id" {
  value       = local.amplify_enabled ? aws_amplify_app.flux[0].id : null
  description = "Amplify app ID (engress.io when enable_amplify)"
}

output "amplify_default_domain" {
  value       = local.amplify_enabled ? aws_amplify_app.flux[0].default_domain : null
  description = "Amplify default *.amplifyapp.com domain (before custom domain DNS)"
}

output "amplify_enabled" {
  value       = local.amplify_enabled
  description = "Whether Amplify hosting is provisioned"
}
