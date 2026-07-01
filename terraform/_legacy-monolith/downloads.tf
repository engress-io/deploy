# Agent / CLI release artifacts — private S3 + CloudFront (app rewrites /downloads/*).

locals {
  downloads_bucket_name = var.downloads_bucket_name != "" ? var.downloads_bucket_name : "${var.name_prefix}-downloads-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "downloads" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = local.downloads_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "downloads" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = aws_s3_bucket.downloads[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "downloads" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = aws_s3_bucket.downloads[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_cloudfront_origin_access_control" "downloads" {
  count = local.aws_ci_enabled ? 1 : 0

  name                              = "${var.name_prefix}-downloads-oac"
  description                       = "OAC for Engress downloads bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "downloads" {
  count = local.aws_ci_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Engress CLI downloads (private S3 origin)"
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.downloads[0].bucket_regional_domain_name
    origin_id                = "downloads-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.downloads[0].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "downloads-s3"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = var.tags
}

data "aws_iam_policy_document" "downloads_bucket" {
  count = local.aws_ci_enabled ? 1 : 0

  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.downloads[0].arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values = compact([
        aws_cloudfront_distribution.downloads[0].arn,
        var.enable_frontend ? aws_cloudfront_distribution.frontend[0].arn : "",
      ])
    }
  }
}

resource "aws_s3_bucket_policy" "downloads" {
  count = local.aws_ci_enabled ? 1 : 0

  bucket = aws_s3_bucket.downloads[0].id
  policy = data.aws_iam_policy_document.downloads_bucket[0].json
}

output "downloads_bucket" {
  value       = local.aws_ci_enabled ? aws_s3_bucket.downloads[0].bucket : null
  description = "S3 bucket for agent/CLI release artifacts (private; served via CloudFront / Amplify rewrite)"
}

output "downloads_cloudfront_domain" {
  value       = local.aws_ci_enabled ? aws_cloudfront_distribution.downloads[0].domain_name : null
  description = "CloudFront domain for /downloads/* Amplify rewrite target"
}
