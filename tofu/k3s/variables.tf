variable "proxmox_endpoint" {
  description = "Proxmox API endpoint (any cluster node)."
  type        = string
  default     = "https://198.51.100.13:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token, form 'user@realm!tokenid=secret'. Set in secrets.auto.tfvars (gitignored) or TF_VAR_proxmox_api_token."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public key injected via cloud-init for the 'kube' user."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHYOURPUBLICKEY operator@example.com"
}

variable "vlan_id" {
  description = "k3s VLAN tag."
  type        = number
  default     = 100
}

variable "gateway" {
  description = "The cluster VLAN gateway (OPNsense opt2)."
  type        = string
  default     = "192.0.2.1"
}

# ---------------------------------------------------------------------------
# Node map — the single source of truth for the cluster's VMs.
#
# The cluster was first built (2026-07-04) with only the 4 VMs on pve-1/pve-2;
# node-3/node-6 on pve-3 joined on 2026-07-06 once the cluster VLAN was trunked to it.
#
# Worker RAM was REDUCED during v1/v2 coexistence. v1 was powered off
# 2026-07-17, so ADR 0010 grows node-4/node-5 to 20 GB / 6 vCPU (equalized,
# the freed-RAM "maximize usage" target; ADR 0008 ceiling is 8 vCPU). node-6
# stays small — `pve-3` shares the host with the Docker/tier VMs (ADR 0010 taints
# it `workload-tier=light`). Growing the Longhorn data_disk (120→350 GB) is
# still pending.
#
# Per-node storage differs: pve-1 uses the `pve1-data` dir pool, pve-2 `pve2-data`.
# Templates are per-node too: 900 on pve-1, 901 on pve-2 (both Ubuntu 24.04,
# ciuser=kube, template flag set).
# ---------------------------------------------------------------------------
variable "nodes" {
  description = "k3s VM definitions keyed by hostname."
  type = map(object({
    vmid        = number
    pve_node    = string
    template_id = number
    datastore   = string
    ip          = string # host part /24 address, no CIDR suffix
    cores       = number
    memory      = number # MB
    boot_disk   = number # GB
    data_disk   = number # GB, 0 = none (control planes); workers get a Longhorn disk
    role        = string # control | worker
    zone        = string # topology.kubernetes.io/zone label (physical host)

    # --- Fields added 2026-07-28 to make this file describe the cluster that
    # --- actually exists. Until now it did not, and the gap was not cosmetic:
    # --- `tofu plan` wanted to UNDO two deliberate operational fixes, so any
    # --- apply — including a routine one — would have silently reverted them.
    # --- That falsifies "any node is rebuildable from code" a second time, in a
    # --- different way from the CNI gap that ADR 0011 decision 1 already names.

    # Where the VM's disks live, when that differs from `datastore` (which also
    # carries the cloud-init drive). node-3 and node-6 were moved off pve-3's
    # BC711 boot NVMe onto the mx500 on 2026-07-20 — executed
    # in a recorded maintenance window with measured results — and the move never came back
    # to code. Reverting it would put an etcd member and a Longhorn node back on
    # a drive the migration exists to keep them off.
    disk_datastore = optional(string)
    # `qm disk move` onto a directory-backed store produces qcow2; LVM-thin is
    # raw. Guessing wrong here is a disk conversion on a live node.
    disk_format = optional(string, "raw")
    # discard=on + ssd=1 were applied in the same window so fstrim actually
    # reaches the SSD. Without them the guest trims into a void: the thin pool
    # ratchets up and never comes back down.
    # Default flipped ignore->on 2026-07-29: discard=on was applied LIVE to
    # every running VM's virtual disks lab-wide (TRIM staging),
    # so "ignore" here would make the next apply regress the fleet. ssd is
    # unchanged (still false where it was false) — flip it per-node with a
    # restart window, not via this default.
    disk_discard = optional(string, "on")
    disk_ssd     = optional(bool, false)

    # vzdump excludes the Longhorn data disk. Applied by hand during the backup
    # stall investigation and never codified. Re-enabling it would put the
    # lab's largest source of real damage straight back: the nightly dump of
    # these disks is what starves the storage engine and produced 73 guest I/O
    # errors in 2.5 minutes on 2026-07-28. The data is already covered by
    # Longhorn's own backups to MinIO — an image of it is the most redundant
    # copy in the lab and the most expensive to take (ADR 0011 decision 1).
    data_disk_backup = optional(bool, false)
  }))

  default = {
    node-1 = {
      vmid = 501, pve_node = "pve-1", template_id = 900, datastore = "pve1-data"
      ip   = "192.0.2.11", cores = 2, memory = 6144, boot_disk = 60, data_disk = 0
      role = "control", zone = "pve-1"
    }
    node-2 = {
      vmid = 502, pve_node = "pve-2", template_id = 901, datastore = "pve2-data"
      ip   = "192.0.2.12", cores = 2, memory = 6144, boot_disk = 60, data_disk = 0
      role = "control", zone = "pve-2"
    }
    # node-4 is 12 GB, not the ADR 0010 equalized 20 GB: a media VM moved onto
    # pve-1 and needs 8 GB (ADR 0012). node-4 was using ~6.6 GB of its 20 GB, so
    # the shrink costs nothing real. Do NOT raise this back to 20480 without
    # first moving that VM off pve-1 — 6 (node-1) + 20 + 4 (Forgejo VM) + 8
    # (media) exceeds the 32 GB host.
    node-4 = {
      vmid = 504, pve_node = "pve-1", template_id = 900, datastore = "pve1-data"
      ip   = "192.0.2.21", cores = 6, memory = 12288, boot_disk = 80, data_disk = 120
      role = "worker", zone = "pve-1"
    }
    node-5 = {
      vmid = 505, pve_node = "pve-2", template_id = 901, datastore = "pve2-data"
      ip   = "192.0.2.22", cores = 6, memory = 20480, boot_disk = 80, data_disk = 120
      role = "worker", zone = "pve-2"
    }

    # --- pve-3 nodes: the cluster VLAN trunked + vmbr0 VLAN-aware 2026-07-06; template
    #     902. Grow to full spec in Phase 8. ---
    node-3 = {
      vmid = 503, pve_node = "pve-3", template_id = 902, datastore = "local-lvm"
      ip   = "192.0.2.13", cores = 2, memory = 6144, boot_disk = 60, data_disk = 0
      # Disks moved to pve-3's mx500 2026-07-20; cloud-init drive
      # stays on local-lvm, which is why this is separate from `datastore`.
      disk_datastore = "mx500", disk_format = "qcow2", disk_discard = "on", disk_ssd = true
      role           = "control", zone = "pve-3"
    }
    node-6 = {
      vmid = 506, pve_node = "pve-3", template_id = 902, datastore = "local-lvm"
      ip   = "192.0.2.23", cores = 4, memory = 12288, boot_disk = 80, data_disk = 120
      # Disks moved to pve-3's mx500 2026-07-20; cloud-init drive
      # stays on local-lvm, which is why this is separate from `datastore`.
      disk_datastore = "mx500", disk_format = "qcow2", disk_discard = "on", disk_ssd = true
      role           = "worker", zone = "pve-3"
    }
  }
}
