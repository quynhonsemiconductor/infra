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
