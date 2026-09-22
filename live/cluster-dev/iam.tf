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

# §10b — the human roles. DERIVED from `security-baseline`, not passed.
#
# This used to be `variable "sso_roles"`, whose comment said the ARNs "are created
# by the `organization` stack". They are not: `organization` exports PERMISSION SET
# arns, which are a different object from the `AWSReservedSSO_*` IAM roles an EKS
# access entry needs. The three that exist are `security-baseline`'s, and reading
# them from its state means nothing is typed twice (§7c).
#
# Nothing passed the variable either — no tfvars, no TF_VAR — so this stack could
# not plan at all. It was never planned, so nothing said so.
data "terraform_remote_state" "security_baseline" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/security-baseline/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  # THREE roles, not four. The design named a `read_only` tier; the estate has no
  # such role, and qnsc-developer already carries ReadOnlyAccess — which is why
  # the developer entry below is VIEW on production and EDIT on dev. A fourth
  # field pointing at the same ARN would be a duplicate access entry, since
  # `aws_eks_access_entry` is keyed on principal_arn.
  sso_roles = {
    platform_admin = data.terraform_remote_state.security_baseline.outputs.human_admin_role_arn
    developer      = data.terraform_remote_state.security_baseline.outputs.human_developer_role_arn
    break_glass    = data.terraform_remote_state.security_baseline.outputs.prod_breakglass_role_arn
  }
}

# NOBODY HAS STANDING ADMIN ON PRODUCTION. On dev, platform-admin is standing —
# dev is where you need to be able to fix things quickly, and a broken dev cluster
# is a Tuesday. Prod's entry is break-glass only; see cluster-prod.
resource "aws_eks_access_entry" "platform_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.sso_roles.platform_admin
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "platform_admin" {
  cluster_name = aws_eks_cluster.this.name
  # `principal_arn` reads the ENTRY rather than `local.sso_roles.*`, and that is a
  # dependency edge, not a style preference. Pointing both at the same local gave
  # OpenTofu no reason to order them, so it created the association in parallel with
  # the entry and AWS answered:
  #
  #   ResourceNotFoundException: The requested resource does not exist
  #
  # — a 404 on a role that plainly existed, because the ACCESS ENTRY did not yet.
  # Found 2026-09-20 on the first apply of this stack.
  principal_arn = aws_eks_access_entry.platform_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

# §10b — on DEV a developer gets exec and port-forward. That is the difference
# between the two clusters, and it is the whole point of having two: debugging a
# pod by shelling into it is fine where nothing is at stake.
#
# On PROD the same person gets AmazonEKSViewPolicy and no exec, because "an exec
# bypasses every audit trail this platform has: environment variables carry the
# secrets ESO injected, the filesystem is writable, and nothing about any of it
# appears in git."
resource "aws_eks_access_entry" "developer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.sso_roles.developer
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "developer" {
  cluster_name = aws_eks_cluster.this.name
  # `principal_arn` reads the ENTRY rather than `local.sso_roles.*`, and that is a
  # dependency edge, not a style preference. Pointing both at the same local gave
  # OpenTofu no reason to order them, so it created the association in parallel with
  # the entry and AWS answered:
  #
  #   ResourceNotFoundException: The requested resource does not exist
  #
  # — a 404 on a role that plainly existed, because the ACCESS ENTRY did not yet.
  # Found 2026-09-20 on the first apply of this stack.
  principal_arn = aws_eks_access_entry.developer.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  access_scope { type = "cluster" }
}

# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD — §5b, §13
#
# ArgoCD runs in the PROD cluster and manages this one remotely. That saves the
# dev system pool about $10-15/month, but the saving is not the reason: it is how
# a deployer works, and §2's isolation claim is footnoted accordingly.
#
# This entry is what lets it in. It is the ONE principal with cluster-admin here
# that is not a human, which makes ArgoCD's own RBAC and its repository access the
# thing to review carefully (§2, §10b).
# ─────────────────────────────────────────────────────────────────────────────

# §2 — ArgoCD is hub-and-spoke: ONE instance, in prod, managing both clusters. So
# the role is created there and this stack grants it entry, which makes cluster-prod
# a dependency of cluster-dev rather than the other way round. There is no cycle:
# cluster-prod reads runtime-prod and bootstrap only.
data "terraform_remote_state" "cluster_prod" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/cluster-prod/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  argocd_role_arn = data.terraform_remote_state.cluster_prod.outputs.argocd_role_arn
}

resource "aws_eks_access_entry" "argocd" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.argocd_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "argocd" {
  cluster_name = aws_eks_cluster.this.name
  # `principal_arn` reads the ENTRY rather than `local.sso_roles.*`, and that is a
  # dependency edge, not a style preference. Pointing both at the same local gave
  # OpenTofu no reason to order them, so it created the association in parallel with
  # the entry and AWS answered:
  #
  #   ResourceNotFoundException: The requested resource does not exist
  #
  # — a 404 on a role that plainly existed, because the ACCESS ENTRY did not yet.
  # Found 2026-09-20 on the first apply of this stack.
  principal_arn = aws_eks_access_entry.argocd.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
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
# ── READING THE PLATFORM NAMESPACE'S OWN SECRETS ─────────────────────────────
#
# THIS WAS MISSING, and it is the reason every ExternalSecret in `platform` reported
# `SecretSyncedError` / "could not get secret data from provider" while the
# SecretStore itself reported `Valid`. Validation only proves the provider is
# reachable; it does not attempt a read.
#
# The policy above is right for PRODUCTS: a product's SecretStore names the product's
# ServiceAccount, ESO assumes that role, and the blast radius stays one namespace.
# But the `platform` namespace has secrets of its own —
#
#     qnsc/<env>/platform/cloudflared-token    the cluster's ingress
#     qnsc/<env>/platform/grafana/*            the one Alloy credential (§8)
#
# — and no role anywhere could read them. `assume-product-stores` grants sts:AssumeRole
# and nothing else, so the platform store had no identity that could complete a GET.
#
# This does NOT weaken §8. The isolation §8 argues for is between PRODUCTS: "one
# compromised namespace would read every product's secrets." The scope here is
# `qnsc/<env>/platform/*` only — the platform namespace reading the platform namespace's
# own infrastructure credentials. Product paths remain unreachable with this role, and
# still require assuming the product's own.
resource "aws_iam_role_policy" "external_secrets_platform_reads" {
  name = "read-platform-secrets"
  role = aws_iam_role.platform["external-secrets"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        # Secrets Manager appends a random 6-character suffix to every ARN, so the
        # trailing `*` is required. Without it this matches nothing and the failure is
        # indistinguishable from having no policy at all.
        Resource = "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.this.account_id}:secret:qnsc/${local.env}/platform/*"
      },
      {
        # NOT OPTIONAL. These secrets are encrypted with the estate's CMK, and a
        # GetSecretValue on a CMK-encrypted secret fails with AccessDenied on
        # kms:Decrypt — an error that names KMS, not Secrets Manager, and sends you
        # looking at the wrong policy.
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

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
