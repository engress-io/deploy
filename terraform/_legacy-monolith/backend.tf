terraform {
  backend "s3" {
    bucket       = "engress-terraform-state-327796148992"
    key          = "engress/core/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
