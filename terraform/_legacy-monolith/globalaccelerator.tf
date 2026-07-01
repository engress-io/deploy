# Global Accelerator for multi-region edge traffic.
# LB ARNs must be written to SSM by scripts/deploy/scripts/collect-lb-arns.sh before apply.

data "aws_ssm_parameter" "east_nlb_arn" {
  count = var.enable_global_accelerator ? 1 : 0
  name  = "engress-deploy-east-nlb-arn"
}

data "aws_ssm_parameter" "west_nlb_arn" {
  count = var.enable_global_accelerator ? 1 : 0
  name  = "engress-deploy-west-nlb-arn"
}

data "aws_ssm_parameter" "east_edge_alb_arn" {
  count = var.enable_global_accelerator ? 1 : 0
  name  = "engress-deploy-east-edge-alb-arn"
}

data "aws_ssm_parameter" "west_edge_alb_arn" {
  count = var.enable_global_accelerator ? 1 : 0
  name  = "engress-deploy-west-edge-alb-arn"
}

resource "aws_globalaccelerator_accelerator" "edge" {
  count = var.enable_global_accelerator ? 1 : 0

  name            = "${var.name_prefix}-edge"
  ip_address_type = "IPV4"
  enabled         = true

  lifecycle {
    prevent_destroy = true
  }

  attributes {
    flow_logs_enabled = false
  }

  tags = var.tags
}

resource "aws_globalaccelerator_listener" "tunnel_tcp" {
  count = var.enable_global_accelerator ? 1 : 0

  accelerator_arn = aws_globalaccelerator_accelerator.edge[0].id
  protocol        = "TCP"

  port_range {
    from_port = 4433
    to_port   = 4433
  }
}

resource "aws_globalaccelerator_listener" "https_tcp" {
  count = var.enable_global_accelerator ? 1 : 0

  accelerator_arn = aws_globalaccelerator_accelerator.edge[0].id
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_listener" "http_tcp" {
  count = var.enable_global_accelerator ? 1 : 0

  accelerator_arn = aws_globalaccelerator_accelerator.edge[0].id
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }
}

resource "aws_globalaccelerator_endpoint_group" "tunnel_east" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn          = aws_globalaccelerator_listener.tunnel_tcp[0].id
  endpoint_group_region = var.aws_region

  health_check_interval_seconds = 10
  health_check_path             = "/"
  health_check_protocol         = "TCP"
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_ssm_parameter.east_nlb_arn[0].value
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "tunnel_west" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn          = aws_globalaccelerator_listener.tunnel_tcp[0].id
  endpoint_group_region = "us-west-1"

  health_check_interval_seconds = 10
  health_check_path             = "/"
  health_check_protocol         = "TCP"
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_ssm_parameter.west_nlb_arn[0].value
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "https_east" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn          = aws_globalaccelerator_listener.https_tcp[0].id
  endpoint_group_region = var.aws_region

  health_check_interval_seconds = 10
  health_check_path             = "/healthz"
  health_check_protocol         = "HTTP"
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_ssm_parameter.east_edge_alb_arn[0].value
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "https_west" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn          = aws_globalaccelerator_listener.https_tcp[0].id
  endpoint_group_region = "us-west-1"

  health_check_interval_seconds = 10
  health_check_path             = "/healthz"
  health_check_protocol         = "HTTP"
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_ssm_parameter.west_edge_alb_arn[0].value
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "http_east" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn          = aws_globalaccelerator_listener.http_tcp[0].id
  endpoint_group_region = var.aws_region

  health_check_interval_seconds = 10
  health_check_path             = "/healthz"
  health_check_protocol         = "HTTP"
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_ssm_parameter.east_edge_alb_arn[0].value
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

resource "aws_globalaccelerator_endpoint_group" "http_west" {
  count = var.enable_global_accelerator ? 1 : 0

  listener_arn          = aws_globalaccelerator_listener.http_tcp[0].id
  endpoint_group_region = "us-west-1"

  health_check_interval_seconds = 10
  health_check_path             = "/healthz"
  health_check_protocol         = "HTTP"
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_ssm_parameter.west_edge_alb_arn[0].value
    weight                         = 128
    client_ip_preservation_enabled = true
  }
}

output "global_accelerator_ips" {
  value = var.enable_global_accelerator ? aws_globalaccelerator_accelerator.edge[0].ip_sets[0].ip_addresses : []
  description = "Static anycast IPs for *.edge.engress.io A records"
}

output "global_accelerator_dns_name" {
  value       = var.enable_global_accelerator ? aws_globalaccelerator_accelerator.edge[0].dns_name : ""
  description = "GA DNS name (for debugging)"
}
