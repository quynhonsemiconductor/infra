output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.this.arn
  description = "Passed to product-profile — every product's IRSA trust is scoped to this issuer (§8)."
}

output "oidc_issuer" {
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  description = "Without the scheme, because that is the form an IAM condition key takes."
}

output "kubernetes_version" {
  value       = aws_eks_cluster.this.version
  description = <<-EOT
    §2b — "Record the current version and the support end date somewhere a human
    reads. The `alerting_health` check is the natural home: a cluster within ninety
    days of end-of-support is a finding, not a surprise."
  EOT
}

output "platform_role_arns" {
  value       = { for k, r in aws_iam_role.platform : k => r.arn }
  description = <<-EOT
    The ARNs gitops/platform/{eso,keda}/values.yaml annotate. They are DERIVED on
    both sides from the cluster name (§7c), so this output is for humans and for
    the moment something does not assume and the question is which name exists.
  EOT
}

# ArgoCD's cluster registration needs this, and the absence of it is why
# `gitops/platform/argocd/clusters.yaml` could not be completed offline.
#
# §2/§5b make ArgoCD hub-and-spoke: one instance in PROD managing both clusters.
# The hub reaches this cluster through a Secret labelled
# `argocd.argoproj.io/secret-type: cluster`, carrying `cluster_endpoint` above,
# an awsAuthConfig naming `cluster_name` and prod's `argocd_role_arn`, and
# `tlsClientConfig.caData` — this value.
#
# IT IS NOT OPTIONAL HERE, unlike on a public cluster. `endpoint_public_access`
# is false, so the API server presents a certificate no public chain validates;
# without the CA the hub cannot verify the spoke and every Application targeting
# `dev` fails on TLS rather than on anything that names a missing output.
#
# Not sensitive: a CA certificate is public by construction. Marking it so would
# only make it harder to paste into the Secret it exists to fill.
output "cluster_certificate_authority_data" {
  value       = aws_eks_cluster.this.certificate_authority[0].data
  description = "Base64 CA for this cluster's API server — ArgoCD's caData."
}
