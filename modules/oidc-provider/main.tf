# ── GitHub OIDC Provider ──────────────────────────────────────────────────────
# One provider per AWS account. This is a singleton — all products in this
# account share it. Product infras reference the ARN via remote_state.
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}
