# ── The role `chart-release.yaml` assumes to publish the chart ───────────────
#
# THIS DID NOT EXIST, and its absence is why six chart versions were published by
# hand from a laptop instead of by CI.
#
# `gitops/.github/workflows/chart-release.yaml` was already correct: it fires on a
# `chart-v*` tag, refuses to publish when the tag disagrees with Chart.yaml, refuses
# when `rendered/` is stale, then pushes. It reads its role from
# `secrets.CHART_PUBLISH_ROLE_ARN` — a secret that was never created, backed by a role
# that was never declared. So the workflow would have failed at the OIDC step, and the
# path of least resistance was `helm push` locally. A gate nobody can pass is a gate
# everybody routes around.
#
# ── WHY THE TRUST IS SCOPED TO TAGS, NOT THE REPOSITORY ─────────────────────
#
# The subject is `repo:<org>/gitops:ref:refs/tags/chart-v*`, so this role cannot be
# assumed by a workflow running on a branch or a pull request — only by one triggered
# by a release tag. A push to `main` cannot publish a chart, which keeps the version
# in Chart.yaml and the version in the registry describing the same contents.
#
# That matters more here than it looks: the repository is IMMUTABLE, so a version
# published once can never be corrected. An accidental publish is permanent.
#
# ── WHY THE PERMISSIONS ARE THIS NARROW ─────────────────────────────────────
#
# Push to ONE repository, `charts/qnsc-service`. Not the product image repositories,
# which belong to each product's own deploy role, and no delete of any kind — with an
# immutable registry, `BatchDeleteImage` is the only way to lose a published chart, and
# no automation needs it.
data "aws_iam_policy_document" "chart_publish_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.oidc_provider.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike, because the tag carries the version. `chart-v*` is the whole point:
    # it admits chart-v0.8.0 and refuses `refs/heads/main`.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:quynhonsemiconductor/gitops:ref:refs/tags/chart-v*"]
    }
  }
}

data "aws_iam_policy_document" "chart_publish" {
  # The token call is account-wide by API design — it authorises nothing on its own,
  # and every push needs it.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      # Read-backs helm performs while pushing an OCI artefact.
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/charts/qnsc-service"]
  }
}

resource "aws_iam_role" "chart_publish" {
  name               = "qnsc-chart-publish"
  description        = "Publishes charts/qnsc-service from gitops' chart-release workflow. Tag-scoped."
  assume_role_policy = data.aws_iam_policy_document.chart_publish_trust.json
  tags               = { Layer = "platform" }
}

resource "aws_iam_role_policy" "chart_publish" {
  name   = "push-qnsc-service-chart"
  role   = aws_iam_role.chart_publish.id
  policy = data.aws_iam_policy_document.chart_publish.json
}

# A ROLE ARN IS NOT A SECRET, and the estate says so itself — from
# rova/infra/live/develop/variables.tf: "These are NOT secrets… a Cloudflare account id
# identifies the account without authorising anything." An ARN names a role; assuming
# it still requires a matching OIDC subject.
#
# It is output rather than hardcoded in the workflow so the value has one source. The
# workflow currently reads `secrets.CHART_PUBLISH_ROLE_ARN`; a repository VARIABLE would
# match the estate's own rule better, and that change belongs with the workflow rather
# than here.
output "chart_publish_role_arn" {
  value       = aws_iam_role.chart_publish.arn
  description = "Set as gitops' CHART_PUBLISH_ROLE_ARN so chart-release.yaml can publish."
}

# bootstrap had neither of these — it hardcodes the region in the provider and never
# needed the account id. Declared here so the ARN above is derived rather than typed.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
