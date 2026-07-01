# Optional control-plane EC2 (engress-core + oasis). Edge keeps :80/:443/:4433 only when enabled.

resource "aws_security_group" "control" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name        = "${var.name_prefix}-control"
  description = "Engress control plane (engress-core)"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    description = "engress-core (CloudFront custom origin)"
    from_port   = 8080
    to_port     = 8080
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

resource "aws_iam_role" "control" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name = "${var.name_prefix}-control-role"

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

resource "aws_iam_role_policy_attachment" "control_ssm" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  role       = aws_iam_role.control[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "control_github_ssm" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name = "${var.name_prefix}-control-github-ssm"
  role = aws_iam_role.control[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = local.github_ssm_arn
    }]
  })
}

resource "aws_iam_role_policy" "control_platform_secrets_ssm" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name = "${var.name_prefix}-control-platform-secrets-ssm"
  role = aws_iam_role.control[0].id

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
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/flux-metrics-ingest-secret",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-metrics-ingest-secret",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-tunnel-ca-cert-pem",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/engress-tunnel-ca-key-pem",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "control_oasis_inventory" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name = "${var.name_prefix}-control-oasis-inventory"
  role = aws_iam_role.control[0].id

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

resource "aws_iam_role_policy" "control_ecr_pull" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name = "${var.name_prefix}-control-ecr-pull"
  role = aws_iam_role.control[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
      }, {
      Effect = "Allow"
      Action = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      Resource = [aws_ecr_repository.api.arn]
    }]
  })
}

resource "aws_iam_instance_profile" "control" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  name = "${var.name_prefix}-control-profile"
  role = aws_iam_role.control[0].name
}

resource "aws_instance" "control" {
  count = var.enable_control_instance && !var.decommission_ec2 ? 1 : 0

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.control_instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  vpc_security_group_ids = [aws_security_group.control[0].id]
  iam_instance_profile   = aws_iam_instance_profile.control[0].name

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data-control.sh.tpl", {
    github_repo          = local.github_clone_url
    github_branch        = local.deploy_branch
    scripts_repo         = var.scripts_repo
    scripts_branch       = var.scripts_branch
    clone_private_script = file("${local.scripts_root}/deploy/lib/clone-private.sh")
    aws_region           = var.aws_region
    base_domain          = var.base_domain
    domain_suffix        = var.domain_suffix
    user_data_version    = var.user_data_version
    root_volume_gb       = var.root_volume_gb
    swap_size_gb         = var.swap_size_gb
    host_setup_script    = file("${local.scripts_root}/deploy/lib/host-setup.sh")
    ecr_api_image        = local.ecr_api_image
    edge_instance_id     = aws_instance.edge[0].id
  })

  user_data_replace_on_change = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-control"
  })
}

output "enable_control_instance" {
  value       = var.enable_control_instance
  description = "Whether a dedicated control EC2 runs engress-core (split topology)"
}

output "control_instance_id" {
  value       = var.enable_control_instance && !var.decommission_ec2 ? aws_instance.control[0].id : null
  description = "Control EC2 instance ID (SSM target for api-up when split)"
}

output "control_public_ip" {
  value       = var.enable_control_instance && !var.decommission_ec2 ? aws_instance.control[0].public_ip : null
  description = "Control instance public IP — A-record control_origin_hostname here when split"
}

output "control_ssm_connect" {
  value       = var.enable_control_instance && !var.decommission_ec2 ? "aws ssm start-session --target ${aws_instance.control[0].id} --region ${var.aws_region}" : null
  description = "SSM shell on control instance"
}
