# pve01 pushes its own metrics (node, VMs, storages incl. pbs-qnsc and local-zfs) with the Proxmox VE
# "OpenTelemetry" external metric server, OTLP/HTTP, to the Alloy receiver in the cluster (gitops
# platform/alloy, NodePort Service alloy-otlp-host). Alloy forwards them to Grafana Cloud with the
# credentials it already holds, so nothing secret lives on the host or in this state.
#
# Plain HTTP on purpose: the hop stays on the server VLAN between pve01 and the k3s node; the payload is
# metrics only. Empty pve_metrics_otlp_server disables the resource (no metric server).

variable "pve_metrics_otlp_server" {
  type        = string
  default     = ""
  description = "Address of a k3s node that serves the Alloy OTLP NodePort (site tfvars). Empty = no metric server."
}

variable "pve_metrics_otlp_port" {
  type        = number
  default     = 30418
  description = "NodePort of Service platform/alloy-otlp-host (gitops platform/alloy)."
}

resource "proxmox_metrics_server" "otlp" {
  count = var.pve_metrics_otlp_server == "" ? 0 : 1

  name                = "qnsc-alloy"
  type                = "opentelemetry"
  server              = var.pve_metrics_otlp_server
  port                = var.pve_metrics_otlp_port
  opentelemetry_proto = "http"
  opentelemetry_path  = "/v1/metrics"
}
