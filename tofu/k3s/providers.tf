terraform {
  required_version = ">= 1.9.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
  }
}

# Proxmox is one quorate cluster (pve-3, pve-1, pve-2, pve-5, pve-4) sharing
# /etc/pve, so a single API token reaches every node. We talk to one
# node's API endpoint; node placement is per-resource via `node_name`.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # self-signed PVE cert

  # Some bpg operations (disk import, cloud-init snippet upload) fall back to
  # SSH. Root key auth works to every node from the admin workstation.
  ssh {
    agent    = true
    username = "root"
  }
}
