# ─────────────────────────────────────────────────────────────────────────────
# Cluster and node roles
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ])
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ─────────────────────────────────────────────────────────────────────────────
# Human access — §10b
#
# Entra → AWS IAM Identity Center → IAM role → EKS access entry → Kubernetes group.
# No IAM users, no long-lived access keys. That is already the posture
# `security-baseline` enforces for the root account, extended to everyone else.
# ─────────────────────────────────────────────────────────────────────────────

variable "sso_roles" {
  type = object({
    platform_admin = string
    developer      = string
    read_only      = string
    break_glass    = string
  })
  description = <<-EOT
    IAM Identity Center permission-set role ARNs. These are created by the
    `organization` stack; naming them here rather than deriving them is deliberate
    — Identity Center mangles role names with a random suffix, so this is one of
    the few things §7c cannot compute.
  EOT
}

# ── NOBODY HAS STANDING ADMIN ON PRODUCTION (§10b) ──────────────────────────
#
# `platform_admin` has NO access entry here. Production admin is the break-glass
# role below, and the alert is the control rather than the permission: "a
# break-glass role nobody can assume is a role people route around during an
# incident; one that announces itself is a role that gets used honestly."
resource "aws_eks_access_entry" "break_glass" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.sso_roles.break_glass
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "break_glass" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.sso_roles.break_glass
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

# The alert that makes it honest. §10b: MFA is required on the role itself; this
# is what tells everyone it happened.
resource "aws_cloudwatch_event_rule" "break_glass" {
  name        = "${local.name}-break-glass"
  description = "Someone assumed the production break-glass role (§10b)."

  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName         = ["AssumeRole"]
      requestParameters = { roleArn = [var.sso_roles.break_glass] }
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "break_glass" {
  rule = aws_cloudwatch_event_rule.break_glass.name
  arn  = var.alert_topic_arn
}

variable "alert_topic_arn" {
  type        = string
  description = <<-EOT
    Where the break-glass alert goes. §8 records that EVERY SNS alarm topic in this
    account once had zero subscriptions, so alarms fired into nothing — check this
    one has a subscriber before relying on it.
  EOT
}

# §10b — a developer gets VIEW on production, and specifically NOT exec.
#
# "An exec bypasses every audit trail this platform has: environment variables
# carry the secrets ESO injected, the filesystem is writable, and nothing about any
# of it appears in git. A platform whose entire promise is 'the cluster is
# reproducible from git' (§13) has that promise broken by one shell."
#
# Debugging production is logs, traces and profiles — which is what §9 spent six
# signals building, and the point of having built them.
resource "aws_eks_access_entry" "developer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.sso_roles.developer
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "developer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.sso_roles.developer
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  access_scope { type = "cluster" }
}

resource "aws_eks_access_entry" "read_only" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.sso_roles.read_only
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "read_only" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.sso_roles.read_only
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  access_scope { type = "cluster" }
}

# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD — §5b, §13
#
# It RUNS here, so it needs no access entry into this cluster — it uses its
# in-cluster ServiceAccount. What it needs is an IRSA role that cluster-dev grants
# an access entry to, which is how it reaches the other cluster.
#
# §13 lists "ArgoCD's own bootstrap — the chicken-and-egg: who installs the
# installer" as an unresolved unknown. The answer: this stack creates the role,
# installs ArgoCD at the version pinned in gitops/versions.yaml, and applies
# gitops/apps/root.yaml. Everything after that is ArgoCD managing itself.
#
# Which gives §13's rebuild rehearsal a defined path — recreate the cluster, run
# this, apply root.yaml, time it. Until that has been done the RTO figures there
# are estimates, and §13 says so.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "argocd_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-application-controller"]
    }
  }
}

resource "aws_iam_role" "argocd" {
  name               = "${local.name}-argocd"
  assume_role_policy = data.aws_iam_policy_document.argocd_trust.json
  tags               = local.tags
}

# Pulling the chart from ECR (§11c). Nothing else — ArgoCD reaches the dev cluster
# through the access entry cluster-dev grants this role, not through an IAM policy.
resource "aws_iam_role_policy" "argocd_ecr" {
  name = "chart-pull"
  role = aws_iam_role.argocd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The only ECR action that CANNOT be scoped: it mints a registry-wide
        # token and AWS rejects any Resource but "*". On its own it grants
        # nothing — every read below is scoped.
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # The chart, and nothing else. `Resource = "*"` here would have let
        # ArgoCD pull every product image in the account, which is not what
        # "pulling the chart from ECR" means (§11c).
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:${local.region}:${data.aws_caller_identity.this.account_id}:repository/charts/*"
      },
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Platform IRSA roles
#
# FOUND PRE-DEPLOY, 2026-09-16. `gitops/platform/{eso,keda}/values.yaml`
# annotate their ServiceAccounts with these role ARNs and nothing created them.
# The pods would have started, failed every AWS call, and ESO failing means no
# secret reaches any workload — so every product would have looked broken for a
# reason three layers away.
#
# They live with the CLUSTER rather than with a product, because they are
# cluster-scoped platform identities: one ESO per cluster, one KEDA per cluster.
# §7 — they outlive a deploy, so OpenTofu owns them.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  oidc_sub = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
}

data "aws_iam_policy_document" "platform_trust" {
  for_each = {
    external-secrets = "system:serviceaccount:platform:external-secrets"
    keda             = "system:serviceaccount:platform:keda-operator"
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    # Scoped to ONE ServiceAccount. A wildcard here would let any pod in the
    # cluster read every product's secrets, which is the blast radius §8 refuses
    # a ClusterSecretStore for.
    condition {
      test     = "StringEquals"
      variable = local.oidc_sub
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "platform" {
  for_each = data.aws_iam_policy_document.platform_trust

  # §7c — the exact string gitops/platform/*/values.yaml annotates.
  name               = "${local.name}-${each.key}"
  assume_role_policy = each.value.json
  tags               = local.tags
}

# ESO does NOT read secrets with this role. Each SecretStore names a PRODUCT
# ServiceAccount and ESO assumes THAT role via auth.jwt.serviceAccountRef (§8),
# which is what keeps the blast radius equal to one namespace. This role only
# needs to assume the per-namespace ones.
resource "aws_iam_role_policy" "external_secrets" {
  name = "assume-product-stores"
  role = aws_iam_role.platform["external-secrets"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/qnsc-${local.env}-*"
    }]
  })
}

# KEDA reads queue DEPTH and nothing else. It never consumes — the product's own
# IRSA role does that (§4b Axis 7).
resource "aws_iam_role_policy" "keda" {
  name = "read-queue-depth"
  role = aws_iam_role.platform["keda"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
      Resource = "arn:aws:sqs:${local.region}:${data.aws_caller_identity.this.account_id}:qnsc-${local.env}-*"
    }]
  })
}

data "aws_caller_identity" "this" {}
