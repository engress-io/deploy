resource "aws_ecr_repository" "edge" {
  name                 = "${var.name_prefix}-edge"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_repository" "api" {
  name                 = "${var.name_prefix}-core"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_iam_role_policy" "ecr_pull" {
  name = "${var.name_prefix}-ecr-pull"
  role = aws_iam_role.edge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
      ]
      Resource = "*"
      }, {
      Effect = "Allow"
      Action = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      Resource = [
        aws_ecr_repository.edge.arn,
        aws_ecr_repository.api.arn,
      ]
    }]
  })
}
