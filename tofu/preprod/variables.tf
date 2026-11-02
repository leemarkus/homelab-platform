variable "proxmox_endpoint" {
  description = "Proxmox API endpoint for the sandbox hypervisor (pve-5)."
  type        = string
  default     = "https://203.0.113.15:8006/"
}

variable "proxmox_api_token" {
  description = "Form 'user@realm!tokenid=secret'. Set in secrets.auto.tfvars (gitignored) or TF_VAR_proxmox_api_token. NEVER commit."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public key injected via cloud-init for the 'kube' user."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHYOURPUBLICKEY operator@example.com"
}

variable "node_name" {
  type    = string
  default = "preprod-1"
}

# 400-series: outside the 5xx production block so a VMID collision cannot happen
# even by typo, and obviously not-production at a glance in the Proxmox UI.
variable "vmid" {
  type    = number
  default = 401
}

variable "pve_node" {
  description = "Proxmox host (the sandbox hypervisor) — see the capacity note in main.tf."
  type        = string
  default     = "pve-5"
}

variable "template_id" {
  description = "Ubuntu 24.04 template on pve-5. Build it with packer/ and host-pve-5.pkrvars.hcl; pve-5 has no hand-built template to inherit, which makes this the first node ever built entirely from code."
  type        = number
  default     = 903
}

variable "datastore" {
  description = "Storage pool on pve-5. CONFIRM before first apply."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "pve-5's VLAN-aware trunk bridge. Isolation from the cluster VLAN comes from the tag below, not from being untagged."
  type        = string
  default     = "vmbr0"
}

# Corrected 2026-07-27 after the first apply produced a VM that booted cleanly
# and had no network at all.
#
# The original config set no tag, on the stated assumption that "sandbox is on
# 203.0.113.0/24 with no VLAN tag". That assumption is false, and pve-5's own
# management address disproves it: `vmbr0` is VLAN-aware
# (`bridge-vlan-aware yes`, `bridge-vids 2-4094`) bridging enp0s31f6, and the
# host's 203.0.113.15/24 plus its default route live on **`vmbr0.200`**, a
# sub-interface for the sandbox VLAN. So 203.0.113.0/24 *is* the
# sandbox VLAN. An untagged NIC lands
# on the trunk's native VLAN instead, which has no route to 203.0.113.1.
#
# This does not weaken the isolation requirement, it implements it. The
# requirement is "must not reach the cluster VLAN" (production k3s,
# 192.0.2.0/24). The sandbox tag is a different VLAN, and the only tag that
# puts this node on the isolated network it was designed for. Untagged was not
# "more isolated"; it was merely disconnected.
variable "vlan_id" {
  description = "VLAN tag for the sandbox subnet (203.0.113.0/24). NEVER the cluster VLAN tag (100 in tofu/k3s) — that is production k3s."
  type        = number
  default     = 200

  validation {
    condition     = var.vlan_id != 100
    error_message = "VLAN 100 is the production k3s network. A pre-prod node that can reach it defeats the entire purpose of having one."
  }
}

variable "ip" {
  description = "Static address on the sandbox subnet."
  type        = string
  default     = "203.0.113.20"
}

variable "gateway" {
  type    = string
  default = "203.0.113.1"
}

# Sized for one k3s server plus Longhorn plus whatever chart is under test.
# 8 GB is the floor for kube-prometheus-stack + Longhorn to coexist; below that
# the OOM killer makes every test result a maybe.
variable "cores" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "boot_disk" {
  type    = number
  default = 60
}

variable "data_disk" {
  description = "Longhorn disk, mounted at /var/lib/longhorn by the ansible baseline."
  type        = number
  default     = 60
}
