# SPA hosting (S3 + CloudFront + ACM in us-east-1).
# DNS: point engress.io (Spaceship) to the cloudfront_domain output.
# API origin: edge_origin_hostname must always resolve to the edge EIP (separate A record).

variable "enable_frontend" {
  type        = bool
  description = "Create S3 + CloudFront for the React SPA"
  default     = false
}

variable "edge_origin_hostname" {
  type        = string
  description = "Hostname for CloudFront /api/* origin (A record -> edge EIP). Use a stable name that does not move to CloudFront, e.g. edge-origin.engress.io"
  default     = ""
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}

locals {
  frontend_enabled      = var.enable_frontend
  edge_origin_hostname  = var.edge_origin_hostname != "" ? var.edge_origin_hostname : "edge-origin-east.${var.base_domain}"
  control_origin_host   = var.control_origin_hostname != "" ? var.control_origin_hostname : "core-origin-east.${var.base_domain}"
  api_origin_hostname   = var.enable_control_instance ? local.control_origin_host : local.edge_origin_hostname
  frontend_bucket_name  = var.spa_bucket_name != "" ? var.spa_bucket_name : "flux-spa-${data.aws_caller_identity.current.account_id}"
  frontend_domain_names = [var.base_domain, "get.${var.base_domain}", "downloads.${var.base_domain}"]
  frontend_aliases      = var.skip_frontend_aliases ? [] : local.frontend_domain_names
  use_amplify           = var.amplify_domain != ""
  default_origin_id     = local.use_amplify ? "spa-amplify" : "spa-s3"
}

resource "aws_acm_certificate" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  provider                    = aws.us_east_1
  domain_name                 = var.base_domain
  subject_alternative_names   = ["get.${var.base_domain}", "downloads.${var.base_domain}"]
  validation_method           = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_s3_bucket" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  bucket = local.frontend_bucket_name
  tags   = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  bucket = aws_s3_bucket.frontend[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  bucket = aws_s3_bucket.frontend[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  name                              = "${var.name_prefix}-spa-oac"
  description                       = "OAC for Engress SPA bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "docs_uri_rewrite" {
  count = local.frontend_enabled ? 1 : 0

  name    = "${var.name_prefix}-docs-uri-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === "/docs" || uri === "/docs/") {
    request.uri = "/docs/index.html";
    return request;
  }
  if (uri.indexOf("/docs/") === 0 && uri.indexOf(".", 6) === -1) {
    request.uri = uri + ".html";
  }
  return request;
}
JS
}

locals {
  docs_function_association = local.frontend_enabled ? [{
    event_type   = "viewer-request"
    function_arn = aws_cloudfront_function.docs_uri_rewrite[0].arn
  }] : []
}

resource "aws_cloudfront_distribution" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Engress SPA"
  default_root_object = "index.html"
  aliases             = local.frontend_aliases

  origin {
    domain_name              = aws_s3_bucket.frontend[0].bucket_regional_domain_name
    origin_id                = "spa-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend[0].id
  }

  # Amplify origin (SPA on Amplify Hosting). Used when amplify_domain is set.
  dynamic "origin" {
    for_each = local.use_amplify ? [1] : []
    content {
      domain_name = var.amplify_domain
      origin_id   = "spa-amplify"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  dynamic "origin" {
    for_each = local.frontend_enabled && !var.enable_control_instance ? [1] : []
    content {
      domain_name = local.edge_origin_hostname
      origin_id   = "engress-core-edge"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  dynamic "origin" {
    for_each = local.frontend_enabled && var.enable_control_instance ? [1] : []
    content {
      domain_name = local.api_origin_hostname
      origin_id   = "engress-core-control"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = local.default_origin_id
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

    dynamic "function_association" {
      for_each = local.docs_function_association
      content {
        event_type   = function_association.value.event_type
        function_arn = function_association.value.function_arn
      }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/docs*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "spa-s3"
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

    dynamic "function_association" {
      for_each = local.docs_function_association
      content {
        event_type   = function_association.value.event_type
        function_arn = function_association.value.function_arn
      }
    }
  }

  dynamic "origin" {
    for_each = local.frontend_enabled && var.enable_aws_ci ? [1] : []
    content {
      domain_name              = aws_s3_bucket.downloads[0].bucket_regional_domain_name
      origin_id                = "downloads-s3"
      origin_access_control_id = aws_cloudfront_origin_access_control.downloads[0].id
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.frontend_enabled && var.enable_aws_ci ? [1] : []
    content {
      path_pattern           = "/downloads/*"
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
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = var.enable_control_instance ? "engress-core-control" : "engress-core-edge"
    viewer_protocol_policy = "https-only"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # SPA deep links — serve index.html on 403/404 from S3 origin.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.skip_frontend_aliases ? [1] : []
    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.skip_frontend_aliases ? [] : [1]
    content {
      acm_certificate_arn      = aws_acm_certificate.frontend[0].arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  tags = var.tags

  depends_on = [aws_acm_certificate.frontend]
}

data "aws_iam_policy_document" "frontend_bucket" {
  count = local.frontend_enabled ? 1 : 0

  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend[0].arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  count = local.frontend_enabled ? 1 : 0

  bucket = aws_s3_bucket.frontend[0].id
  policy = data.aws_iam_policy_document.frontend_bucket[0].json
}

output "frontend_enabled" {
  value       = local.frontend_enabled
  description = "Whether SPA CloudFront stack is provisioned"
}

output "frontend_bucket" {
  value       = local.frontend_enabled ? aws_s3_bucket.frontend[0].bucket : null
  description = "S3 bucket for vite build artifacts"
}

output "cloudfront_domain" {
  value       = local.frontend_enabled ? aws_cloudfront_distribution.frontend[0].domain_name : null
  description = "CloudFront domain — CNAME engress.io here after ACM validates"
}

output "frontend_acm_validation" {
  value       = local.frontend_enabled ? aws_acm_certificate.frontend[0].domain_validation_options : null
  description = "DNS records required to validate the CloudFront ACM cert (us-east-1)"
}

output "edge_origin_hostname" {
  value       = local.edge_origin_hostname
  description = "CloudFront /api/* origin when api co-locates on edge (combined mode)"
}

output "api_origin_hostname" {
  value       = local.api_origin_hostname
  description = "Active CloudFront /api/* origin hostname"
}

output "control_origin_hostname" {
  value       = local.control_origin_host
  description = "Split-mode control hostname (A → control_public_ip when enable_control_instance)"
}
