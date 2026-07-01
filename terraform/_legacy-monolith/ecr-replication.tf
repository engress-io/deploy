# Replicate engress-edge and engress-core images from us-east-2 to us-west-1.

resource "aws_ecr_replication_configuration" "engress" {
  count = var.enable_eks_west ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = "us-west-1"
        registry_id = data.aws_caller_identity.current.account_id
      }
      repository_filter {
        filter      = "${var.name_prefix}-edge"
        filter_type = "PREFIX_MATCH"
      }
    }
    rule {
      destination {
        region      = "us-west-1"
        registry_id = data.aws_caller_identity.current.account_id
      }
      repository_filter {
        filter      = "${var.name_prefix}-core"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}
