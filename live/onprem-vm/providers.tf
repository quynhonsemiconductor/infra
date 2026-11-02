# Proxmox API token, scoped to the VM's pool + VM.* on /vms/100. Values come
# from the environment (TF_VAR_*, owner-side), never from Git; a provider
# argument is configuration, never state, so the token does not land in the
# state file either.
#
# The `ssh` block below exists for one operation only: uploading ai-01's
# cloud-init snippet, which the API cannot do.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure

  # The Proxmox API cannot upload snippets (ai-01's cloud-init user data): the
  # provider writes them over SSH to the node. The owner's ssh-agent holds the key;
  # nothing secret is in this stack.
  ssh {
    agent    = true
    username = "root"
    node {
      name    = var.proxmox_node
      address = var.proxmox_ssh_address
    }
  }
}
