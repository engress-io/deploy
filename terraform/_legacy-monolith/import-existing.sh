#!/bin/bash
# Import existing AWS resources into Terraform state.
# Run this once after state loss to recover management of live infrastructure.
set -euo pipefail

cd "$(dirname "$0")"

TF="${TF:-terraform}"
PROFILE="${AWS_PROFILE:-ghostweasel-flux}"
REGION="${AWS_REGION:-us-east-2}"

echo "=== Importing ECR repositories ==="
$TF import -var="aws_region=$REGION" aws_ecr_repository.edge arn:aws:ecr:$REGION:327796148992:repository/engress-edge 2>&1 || true
$TF import -var="aws_region=$REGION" aws_ecr_repository.api arn:aws:ecr:$REGION:327796148992:repository/engress-core 2>&1 || true

echo "=== Importing IAM roles ==="
$TF import aws_iam_role.edge engress-edge-role 2>&1 || true
$TF import aws_iam_role.codebuild engress-codebuild-role 2>&1 || true
$TF import aws_iam_role.codepipeline engress-codepipeline-role 2>&1 || true
$TF import aws_iam_role.github_deploy engress-github-deploy-role 2>&1 || true

echo "=== Importing IAM instance profile ==="
$TF import aws_iam_instance_profile.edge engress-edge-profile 2>&1 || true

echo "=== Importing security group ==="
$TF import aws_security_group.edge sg-00efdc9351d2aeeb4 2>&1 || true

echo "=== Importing EC2 instance ==="
$TF import aws_instance.edge i-0df9b4c6fc758210b 2>&1 || true

echo "=== Importing OIDC provider ==="
$TF import aws_iam_openid_connect_provider.github token.actions.githubusercontent.com 2>&1 || true

echo "=== Verifying state ==="
$TF state list

echo "=== Done. Run 'terraform plan' to verify no changes needed. ==="
