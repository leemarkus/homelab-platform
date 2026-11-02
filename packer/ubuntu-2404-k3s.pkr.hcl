# Golden Ubuntu 24.04 template for k3s v2 nodes.
#
# WHAT THIS REPLACES. Templates 900 (pve-1), 901 (pve-2) and 902 (pve-3) were
# built by hand. Nobody can say precisely what is in them, they drift from each
# other, and a rebuilt node inherits whatever the last person did interactively —
# which is the reason "any node rebuildable from code" was the last rebuild goal
# still unmet. This file is the answer to "what is in the image?".
#
# WHAT IT DELIBERATELY DOES NOT DO. No k3s, no per-node config, no join token.
# The image is identical on every host and carries no cluster identity; k3s and
# /etc/rancher/k3s/config.yaml come from the `k3s_node` Ansible role at boot.
# Baking k3s into the image would mean rebuilding the image to change a k3s
# version, and would put a token in a template — see ansible/roles/k3s_node.
#
# CREDENTIALS NEVER LIVE IN THIS FILE. Two ways to supply them; the first is
# preferred because it matches tofu/k3s's `secrets.auto.tfvars` convention and
# there is nothing to forget:
#
#   cp secrets.auto.pkrvars.hcl.example secrets.auto.pkrvars.hcl   # gitignored
#   # ...fill in, then nothing else to pass — Packer auto-loads *.auto.pkrvars.hcl
#
# or, per-shell:
#   export PKR_VAR_proxmox_api_token='user@realm!tokenid=secret'
#   export PKR_VAR_ssh_password='<throwaway build-time password>'
#
# `ssh_password` is used only by the installer inside the ephemeral VM so Packer
# can SSH in. The cleanup provisioner runs `passwd -d kube` before the VM becomes
# a template, and the hardening role disables password auth — it does not survive
# into any node.
#
#   packer init   .
#   packer validate -syntax-only .                          # needs NO credentials
#   cp host.pkrvars.hcl.example host-pve-1.pkrvars.hcl     # one per host
#   packer validate -var-file=host-pve-1.pkrvars.hcl .      # needs them
#   packer build    -var-file=host-pve-1.pkrvars.hcl .
#
# One build per Proxmox host, because each host has its own datastore and its own
# template VMID — see host.pkrvars.hcl.example.

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
variable "proxmox_url" {
  type        = string
  default     = "https://198.51.100.13:8006/api2/json" # pve-3; any node answers
  description = "Proxmox API endpoint. Any cluster node answers."
}

variable "proxmox_node" {
  type        = string
  description = "Which Proxmox host builds and stores this template (pve-1 | pve-2 | pve-3)."
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Form 'user@realm!tokenid=secret'. Set PKR_VAR_proxmox_api_token; never commit."
}

variable "proxmox_insecure_tls" {
  type        = bool
  default     = true
  description = "Proxmox uses a self-signed cert on the LAN."
}

variable "template_vmid" {
  type        = number
  description = "VMID of the resulting template. 900 on pve-1, 901 on pve-2, 902 on pve-3."
}

variable "datastore" {
  type        = string
  description = "Storage for the template disk. pve1-data on pve-1, pve2-data on pve-2."
}

variable "iso_file" {
  type        = string
  default     = "local:iso/ubuntu-24.04.3-live-server-amd64.iso"
  description = "Ubuntu 24.04 server ISO already uploaded to Proxmox."
}

variable "ssh_password" {
  type        = string
  sensitive   = true
  description = "Build-time only, for Packer to reach the installer. Not present in the template."
}

variable "ssh_public_key" {
  type        = string
  description = "Key baked in for the 'kube' user; cloud-init re-applies it per node."
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHYOURPUBLICKEY operator@example.com"
}

variable "vlan_id" {
  type        = number
  default     = 100
  description = "k3s VLAN. The build VM needs it to reach apt mirrors through OPNsense."
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
source "proxmox-iso" "ubuntu-k3s" {
  proxmox_url              = var.proxmox_url
  node                     = var.proxmox_node
  token                    = var.proxmox_api_token
  username                 = "" # token carries the identity
  insecure_skip_tls_verify = var.proxmox_insecure_tls

  vm_id                = var.template_vmid
  vm_name              = "ubuntu-2404-k3s-template"
  template_description = "Ubuntu 24.04 + k3s node baseline. Built by packer/ubuntu-2404-k3s.pkr.hcl — do not edit by hand."

  boot_iso {
    type     = "scsi"
    iso_file = var.iso_file
    unmount  = true
  }

  # Sized for the *build*, not for the node. tofu/k3s/ resizes CPU, RAM and disk
  # per node at clone time, so this only has to be big enough to install.
  cores  = 2
  memory = 4096

  scsi_controller = "virtio-scsi-single"
  disks {
    type         = "scsi"
    disk_size    = "20G"
    storage_pool = var.datastore
    format       = "raw"
  }

  network_adapters {
    bridge   = "vmbr0"
    model    = "virtio"
    vlan_tag = var.vlan_id
  }

  # cloud-init drive: tofu injects the per-node IP, hostname and key through it.
  cloud_init              = true
  cloud_init_storage_pool = var.datastore

  qemu_agent = true
  # Matches the hand-built templates so the tofu `serial_device {}` still applies.
  serials = ["socket"]

  # --- Ubuntu autoinstall -------------------------------------------------
  # Packer serves http/ over its own HTTP server; the kernel picks up the
  # autoinstall answers from there. This is the part that was previously a person
  # clicking through subiquity.
  http_directory = "${path.root}/http"
  boot_wait      = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  ssh_username = "kube"
  ssh_password = var.ssh_password
  # Ubuntu 24.04's installer is slow on spinning-rust-backed dir storage; 30m is
  # generous rather than optimistic. A timeout here wastes a whole build.
  ssh_timeout = "30m"
}

build {
  name    = "ubuntu-2404-k3s"
  sources = ["source.proxmox-iso.ubuntu-k3s"]

  # Baseline packages only. Everything cluster-specific stays in Ansible so the
  # image never needs rebuilding for a k3s change.
  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -eux",
      "cloud-init status --wait || true",
      "apt-get update",
      # Same set as ansible/playbooks/k3s-v2-baseline.yml. Present here so a
      # fresh node is usable before Ansible runs; the playbook is still the
      # authority and is idempotent over the top.
      "DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent open-iscsi nfs-common util-linux",
      "systemctl enable iscsid qemu-guest-agent",
      # Longhorn and k3s both refuse to work correctly with swap on.
      "swapoff -a",
      "sed -i '/\\sswap\\s/d' /etc/fstab",
      "printf 'overlay\\nbr_netfilter\\n' > /etc/modules-load.d/k3s.conf",
    ]
  }

  # Strip identity so every clone gets a fresh one. Without this, clones share a
  # machine-id — which makes DHCP hand them the same lease and systemd-journald
  # merge their logs, and it is a genuinely confusing failure to debug.
  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -eux",
      "cloud-init clean --logs --seed",
      "rm -f /etc/machine-id /var/lib/dbus/machine-id",
      "touch /etc/machine-id",
      "rm -f /etc/ssh/ssh_host_*", # regenerated on first boot
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",
      # Build-time credential must not survive into the template.
      "passwd -d kube || true",
      "truncate -s 0 /home/kube/.bash_history || true",
    ]
  }
}
