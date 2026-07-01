variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-2"
}

variable "aws_profile" {
  type        = string
  description = "AWS CLI profile (IAM Identity Center / SSO). Omit in CI — uses the ambient credential chain (OIDC on GitHub Actions)."
  default     = null
  nullable    = true
}

variable "name_prefix" {
  type        = string
  description = "Resource name prefix"
  default     = "engress"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type (ARM recommended)"
  default     = "t4g.micro"
}

variable "ami_name_pattern" {
  type        = string
  description = "Ubuntu AMI name filter (Canonical). Noble arm64 uses hvm-ssd-gp3 path since 2025."
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
}

variable "root_volume_gb" {
  type        = number
  description = "Root EBS volume size in GB"
  default     = 16
}

variable "swap_size_gb" {
  type        = number
  description = "Swap file size in GB (go build on t4g.micro needs >=1, default 2)"
  default     = 2
}

variable "operator_cidr" {
  type        = string
  description = "CIDR allowed for SSH (your IP/32)"
  default     = "0.0.0.0/0"
}

variable "key_name" {
  type        = string
  description = "Optional EC2 key pair name for SSH"
  default     = ""
}

variable "admin_email" {
  type        = string
  description = "Dashboard admin email"
}

variable "github_repo" {
  type        = string
  description = "GitHub HTTPS clone URL for EC2, CodePipeline, and Amplify"
  default     = "https://github.com/engress-io/core.git"
}

variable "scripts_repo" {
  type        = string
  description = "GitHub HTTPS clone URL for the Engress operator scripts repo"
  default     = "https://github.com/engress-io/scripts.git"
}

variable "github_token_ssm_parameter" {
  type        = string
  description = "SSM SecureString PAT for private GitHub clone (EC2 IAM + Terraform reads for CI)"
  default     = "engress-github-read-token"
}

variable "github_branch" {
  type        = string
  description = "Default branch for EC2 clone, CodePipeline, and Amplify"
  default     = "main"
}

variable "scripts_branch" {
  type        = string
  description = "Default branch for EC2 scripts clone"
  default     = "main"
}

variable "endpoint_subdomain" {
  type    = string
  default = "test"
}

variable "acme_production" {
  type        = bool
  description = "Use production Let's Encrypt (false = staging). Required for Cursor and other external HTTPS clients."
  default     = false
}

variable "user_data_version" {
  type        = string
  description = "Bump to force a new EC2 instance (re-runs clone + bootstrap via user-data)"
  default     = "1"
}

variable "elastic_ip_address" {
  type        = string
  description = "Pre-existing Elastic IP (manually managed in AWS; Terraform associates but never creates or releases it)"
}

variable "base_domain" {
  type        = string
  description = "Dashboard hostname (control plane served at https://<base_domain>/dashboard)"
  default     = "engress.io"
}

variable "domain_suffix" {
  type        = string
  description = "Tunnel hostname suffix; endpoint studio -> studio<suffix> e.g. studio.edge.engress.io"
  default     = ".edge.engress.io"
}

variable "eip_protect" {
  type        = bool
  description = "Used by dev.sh only: when true, down refuses destroy if EIP is younger than 7 days (legacy guard)"
  default     = true
}

variable "tags" {
  type    = map(string)
  default = { project = "engress" }
}

variable "use_ecr_images" {
  type        = bool
  description = "Pull pre-built images from ECR on EC2 instead of compiling Go on the instance"
  default     = true
}

variable "container_image_tag" {
  type        = string
  description = "ECR image tag to deploy (build-push-ecr.sh uses git describe by default)"
  default     = ""
}

variable "enable_control_instance" {
  type        = bool
  description = "When true, provision a separate EC2 for engress-core + oasis; CloudFront /api/* targets control_origin_hostname. When false (default), core co-locates on the edge box."
  default     = false
}

variable "control_origin_hostname" {
  type        = string
  description = "Hostname for CloudFront /api/* when enable_control_instance is true (A record -> control public IP), e.g. control-origin.engress.io"
  default     = ""
}

variable "spa_bucket_name" {
  type        = string
  description = "Pin the production SPA S3 bucket (recommended). Empty defaults to flux-spa-{account_id}."
  default     = ""
}

variable "downloads_bucket_name" {
  type        = string
  description = "Optional fixed downloads S3 bucket name (skip rename during cutover). Empty uses name_prefix-downloads-account_id."
  default     = ""
}

variable "pipeline_artifacts_bucket_name" {
  type        = string
  description = "Optional fixed pipeline artifacts S3 bucket name (skip rename during cutover). Empty uses name_prefix-pipeline-artifacts-account_id."
  default     = ""
}

variable "control_instance_type" {
  type        = string
  description = "EC2 instance type for the control plane (when enable_control_instance)"
  default     = "t4g.micro"
}

variable "enable_aws_ci" {
  type        = bool
  description = "Provision CodeBuild, CodePipeline, and downloads bucket (AWS-native CI/CD)"
  default     = false
}

variable "enable_amplify" {
  type        = bool
  description = "Provision Amplify Hosting connected to GitHub (requires enable_aws_ci)"
  default     = false
}

variable "amplify_domain" {
  type        = string
  description = "Amplify app domain (e.g. dftigsyg375wb.amplifyapp.com) for CloudFront origin. Empty disables Amplify origin."
  default     = ""
}

variable "skip_frontend_aliases" {
  type        = bool
  description = "Recovery: create CloudFront without engress.io aliases first (avoids CNAMEAlreadyExists when DNS still points at a deleted distribution)"
  default     = false
}

variable "enable_eks" {
  type        = bool
  description = "Provision EKS cluster, VPC, and IRSA roles for engress-core/engress-edge pods"
  default     = false
}

variable "decommission_ec2" {
  type        = bool
  description = "Destroy edge/control EC2 after EKS cutover (run only after DNS/GA points at EKS load balancers)"
  default     = false
}

variable "deploy_target" {
  type        = string
  description = "CI deploy mode written to SSM engress-deploy-target: ec2, eks, or both (parallel validation)"
  default     = "ec2"

  validation {
    condition     = contains(["ec2", "eks", "both"], var.deploy_target)
    error_message = "deploy_target must be ec2, eks, or both"
  }
}

variable "eks_cluster_name" {
  type        = string
  description = "EKS cluster name (default engress-east)"
  default     = ""
}

variable "eks_cluster_version" {
  type        = string
  description = "Kubernetes version for EKS"
  default     = "1.31"
}

variable "eks_system_node_instance_type" {
  type        = string
  description = "Instance type for system node group"
  default     = "t4g.medium"
}

variable "eks_workload_node_instance_type" {
  type        = string
  description = "Instance type for workload node group"
  default     = "t4g.medium"
}

variable "eks_workload_max_nodes" {
  type        = number
  description = "Maximum workload nodes"
  default     = 8
}

variable "eks_vpc_cidr" {
  type        = string
  description = "VPC CIDR for EKS cluster"
  default     = "10.0.0.0/16"
}

variable "eks_private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for EKS nodes"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "eks_public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs for EKS load balancers"
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "enable_eks_west" {
  type        = bool
  description = "Provision EKS cluster engress-west in us-west-1"
  default     = false
}

variable "enable_global_accelerator" {
  type        = bool
  description = "Provision Global Accelerator for multi-region edge (requires LB ARNs in SSM)"
  default     = false
}

variable "eks_west_cluster_name" {
  type        = string
  description = "West EKS cluster name (default engress-west)"
  default     = ""
}

variable "eks_west_vpc_cidr" {
  type        = string
  description = "VPC CIDR for west EKS cluster"
  default     = "10.1.0.0/16"
}

variable "eks_west_private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for west EKS nodes"
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "eks_west_public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs for west EKS load balancers"
  default     = ["10.1.101.0/24", "10.1.102.0/24"]
}
