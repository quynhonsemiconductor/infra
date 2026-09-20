# Outputs consumed by `data-dev`, `cluster-dev` and every product stack.
#
# THIS IS THE CONTRACT THAT REPLACES `runtime-dev`'s. The names are deliberately
# IDENTICAL to the ones runtime-dev exports, so repointing a consumer is a
# one-line change to its `terraform_remote_state` key and nothing else — which is
# also what makes the move reviewable, and reversible if it has to be.
#
# `ci/scripts/platform_conformance.py --only remote-state` compares what stacks
# read against what stacks export, so a rename here fails CI rather than a plan.

output "vpc_id" {
  value       = module.network.vpc_id
  description = "VPC ID — consumed by cluster-dev for its S3 gateway endpoint."
}

output "public_subnet_ids" {
  value       = module.network.public_subnet_ids
  description = "Public subnet IDs. Hold the NAT gateway and nothing else — §3 provisions no load balancer."
}

output "private_subnet_ids" {
  value       = module.network.private_subnet_ids
  description = <<-EOT
    Private subnet IDs — /24, and EMPTY by design.

    They exist because the module creates the per-AZ private ROUTE TABLES from
    them, and those route tables are what carry the NAT default route and the S3
    gateway endpoint that the /20 cluster subnets share. Nothing is placed here.

    Do NOT put cluster nodes in these. That is what `cluster_subnet_ids` is for,
    and the reason is IP space: Auto Mode reserves a /28 per node up front.
  EOT
}

output "cluster_subnet_ids" {
  value       = module.network.cluster_subnet_ids
  description = <<-EOT
    The /20 tier EKS nodes and pods live in. `cluster-dev` reads this.

    An empty list means `cluster_subnet_cidrs` was not set. `aws_eks_cluster`
    rejects an empty `subnet_ids`, so that fails at plan rather than creating
    something subtly wrong.
  EOT
}

output "data_subnet_ids" {
  value       = module.network.data_subnet_ids
  description = "Data subnet IDs — the shared Postgres and cache in data-dev."
}

output "sg_rds_id" {
  value       = module.network.sg_rds_id
  description = "RDS security group. Ingress from the app SG only; no public access."
}

output "sg_cache_id" {
  value       = module.network.sg_cache_id
  description = "Cache security group, for the one Valkey per environment (§5d)."
}

output "sg_app_id" {
  value       = module.network.sg_app_id
  description = <<-EOT
    The SG whose ingress rules open RDS and the cache.

    Named `app` because the module was written for ECS tasks. Here it is the
    NODE security group's counterpart: the NodeClass in
    `gitops/platform/compute/nodeclass.yaml` selects the EKS-managed cluster
    security group, and the rules that let a pod reach Postgres are the
    `rds_from_app` / `cache_from_app` pair the module creates from this one.

    ⚠ VERIFY THIS AT BRING-UP. EKS Auto Mode attaches its own cluster security
    group to nodes, NOT this one, so `rds_from_app` alone does not admit pod
    traffic. Either add an ingress rule on `sg_rds_id` from the EKS cluster SG, or
    select this SG in the NodeClass. Whichever is chosen, it is a one-rule change
    and it is the difference between a pod that connects and one that hangs on
    connect with no error anybody can see from the database side.
  EOT
}

output "vpc_cidr" {
  value       = "10.92.0.0/16"
  description = <<-EOT
    Stated as an output because the peering stack needs it as a ROUTE
    destination, and reading it off a comment in someone else's file is how a
    route ends up pointing at the wrong /16.
  EOT
}

output "nat_instance_id" {
  value       = module.network.nat_instance_id
  description = <<-EOT
    The `--target` for the SSM port-forward to the dev database.

    Exposed because hunting for it in the console is the small friction that
    stops people using the safe path — and the unsafe path is somebody reaching
    for `publicly_accessible` at 2am. Null unless nat_type = "instance".
  EOT
}
