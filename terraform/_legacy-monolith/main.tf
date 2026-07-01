terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "aws" {
  alias   = "west"
  region  = "us-west-1"
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

# Manually managed Elastic IP — Terraform only associates; never creates or releases.
# Skipped after EC2 decommission (EIP may already be released).
data "aws_eip" "edge" {
  count = var.decommission_ec2 ? 0 : 1

  filter {
    name   = "public-ip"
    values = [var.elastic_ip_address]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  container_image_tag = var.container_image_tag != "" ? var.container_image_tag : "latest"
  ecr_edge_image      = "${aws_ecr_repository.edge.repository_url}:${local.container_image_tag}"
  ecr_api_image       = "${aws_ecr_repository.api.repository_url}:${local.container_image_tag}"
  scripts_root        = abspath("${path.module}/../../../scripts")
  enable_eks          = var.enable_eks
  edge_public_ip      = var.decommission_ec2 ? (var.elastic_ip_address != "" ? var.elastic_ip_address : "0.0.0.0") : data.aws_eip.edge[0].public_ip
}

resource "aws_security_group" "edge" {
  name        = "${var.name_prefix}-edge"
  description = "Engress edge ingress"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    description = "HTTP ACME + redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS public"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Agent tunnels"
    from_port   = 4433
    to_port     = 4433
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_iam_role" "edge" {
  name = "${var.name_prefix}-edge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.edge.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "github_ssm" {
  name = "${var.name_prefix}-github-ssm"
  role = aws_iam_role.edge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = local.github_ssm_arn
    }]
  })
}

# engress-core (optional compose profile) reads Neon + Clerk secrets from SSM on the edge box (combined mode only).
resource "aws_iam_role_policy" "platform_secrets_ssm" {
  count = var.enable_control_instance ? 0 : 1

  name = "${var.name_prefix}-platform-secrets-ssm"
  role = aws_iam_role.edge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/neon-db-connection-string",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/clerk-secret-key",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/next-clerk-publishable-key",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/clerk-webhook-secret",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-metrics-ingest-secret",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/flux-metrics-ingest-secret",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-tunnel-ca-cert-pem",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-tunnel-ca-key-pem",
      ]
    }]
  })
}

# oasis (engress-core) reads EC2 + SSM state, runs host jobs via SSM, and starts CodePipeline
# executions for deploy actions (combined mode only).
resource "aws_iam_role_policy" "oasis_inventory" {
  count = var.enable_control_instance ? 0 : 1

  name = "${var.name_prefix}-oasis-inventory"
  role = aws_iam_role.edge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ssm:DescribeInstanceInformation",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
        ]
        Resource = "*"
      }]
    )
  })
}

resource "aws_iam_instance_profile" "edge" {
  name = "${var.name_prefix}-edge-profile"
  role = aws_iam_role.edge.name
}

resource "random_pet" "admin" {
  length    = 3
  separator = "-"
}

resource "aws_instance" "edge" {
  count = var.decommission_ec2 ? 0 : 1

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  vpc_security_group_ids = [aws_security_group.edge.id]
  iam_instance_profile   = aws_iam_instance_profile.edge.name

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    admin_email          = var.admin_email
    admin_password       = random_pet.admin.id
    github_repo          = local.github_clone_url
    github_branch        = local.deploy_branch
    scripts_repo         = var.scripts_repo
    scripts_branch       = var.scripts_branch
    clone_private_script = file("${local.scripts_root}/deploy/lib/clone-private.sh")
    aws_region           = var.aws_region
    endpoint_subdomain   = var.endpoint_subdomain
    base_domain          = var.base_domain
    domain_suffix        = var.domain_suffix
    elastic_ip_address   = var.elastic_ip_address
    acme_production      = var.acme_production ? "1" : "0"
    user_data_version    = var.user_data_version
    root_volume_gb       = var.root_volume_gb
    swap_size_gb         = var.swap_size_gb
    host_setup_script    = file("${local.scripts_root}/deploy/lib/host-setup.sh")
    use_ecr_images       = var.use_ecr_images ? "1" : "0"
    ecr_edge_image       = local.ecr_edge_image
    ecr_api_image        = local.ecr_api_image
  })

  user_data_replace_on_change = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-edge"
  })
}

resource "aws_eip_association" "edge" {
  count = var.decommission_ec2 ? 0 : 1

  instance_id   = aws_instance.edge[0].id
  allocation_id = data.aws_eip.edge[0].id
}

output "elastic_ip" {
  value       = local.edge_public_ip
  description = "Elastic IP for flux edge (externally managed; not released on destroy)"
}

output "base_domain" {
  value       = var.base_domain
  description = "Dashboard hostname"
}

output "domain_suffix" {
  value       = var.domain_suffix
  description = "Tunnel hostname suffix"
}

output "root_volume_gb" {
  value       = var.root_volume_gb
  description = "Root EBS volume size (GB)"
}

output "swap_size_gb" {
  value       = var.swap_size_gb
  description = "Swap file configured in user-data (GB)"
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS region"
}

output "dashboard_url" {
  value       = "https://${var.base_domain}/dashboard"
  description = "Control plane dashboard URL"
}

output "edge_addr" {
  value       = "${local.edge_public_ip}:4433"
  description = "Agent edge_addr (IP:4433, not HTTPS URL)"
}

output "endpoint_subdomain" {
  value       = var.endpoint_subdomain
  description = "Default endpoint subdomain created at bootstrap"
}

output "tunnel_url_example" {
  value       = "https://${var.endpoint_subdomain}${var.domain_suffix}/v1"
  description = "Example tunnel URL for endpoint_subdomain"
}

output "admin_email" {
  value = var.admin_email
}

output "admin_password" {
  value     = random_pet.admin.id
  sensitive = true
}

output "ssh_hint" {
  value = var.key_name != "" ? "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${local.edge_public_ip}" : "Use SSM Session Manager (no SSH key configured)"
}

output "instance_id" {
  value       = var.decommission_ec2 ? null : aws_instance.edge[0].id
  description = "EC2 instance ID (SSM Session Manager, send-command)"
}

output "ssm_connect" {
  value       = var.decommission_ec2 ? null : "aws ssm start-session --target ${aws_instance.edge[0].id} --region ${var.aws_region}"
  description = "Open a shell on the edge via SSM (no SSH key required)"
}

output "bootstrap_hint" {
  value       = "Credentials on instance: /opt/engress/core/deploy/data/bootstrap-credentials.txt (after user-data completes, ~5-10 min)"
  description = "Where to find dashboard login and agent.yaml after first apply"
}

output "ecr_edge_repository_url" {
  value       = aws_ecr_repository.edge.repository_url
  description = "ECR repository for engress-edge (build-push-ecr.sh)"
}

output "ecr_api_repository_url" {
  value       = aws_ecr_repository.api.repository_url
  description = "Compatibility alias for ecr_core_repository_url"
}

output "ecr_core_repository_url" {
  value       = aws_ecr_repository.api.repository_url
  description = "ECR repository for engress-core"
}

output "ecr_edge_image" {
  value       = local.ecr_edge_image
  description = "Full engress-edge image URI (repo:tag) for the configured container_image_tag"
}

output "ecr_api_image" {
  value       = local.ecr_api_image
  description = "Compatibility alias for ecr_core_image"
}

output "ecr_core_image" {
  value       = local.ecr_api_image
  description = "Full engress-core image URI (repo:tag)"
}

output "use_ecr_images" {
  value       = var.use_ecr_images
  description = "When true, EC2 pulls from ECR instead of compiling Go on-instance"
}
