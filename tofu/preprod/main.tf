# Pre-prod k3s node — the pre-production option.
#
# WHAT THIS IS FOR. The promotion gate in the gitops repository proves a manifest is
# schema-valid, policy-clean, renders, and would be admitted. It cannot prove the
# resulting pods actually come up. On 2026-07-27 an internal app crashlooped 88 times over
# seven hours with a Synced/Healthy Application and a green pipeline — manifest
# correct, credential wrong. That class needs somewhere a chart can genuinely
# *run* before it reaches the only cluster there is.
#
# ─── WHY A SEPARATE STATE FILE, NOT A 7TH ENTRY IN tofu/k3s ──────────────────
# tofu/k3s/ holds the six production VMs. Adding pre-prod to that `nodes` map
# would mean every `tofu plan` for a disposable test node also plans against the
# live control plane, and a fat-fingered `-target` or a stale state could act on
# production. A pre-prod cluster's entire value is being cheap to destroy and
# recreate; sharing state with production makes it the opposite of disposable.
# Separate root module, separate state, zero overlap.
#
# ─── WHY `pve-5` AND NOT A k3s HOST ────────────────────────────────────────
# There is no room on the k3s hosts. From tofu/k3s/variables.tf, allowing 2 GB
# for PVE itself:
#     pve-1   32 GB total, 26 GB committed (node-1 6 + node-4 20) -> ~4 GB free
#     pve-2   32 GB total, 26 GB committed (node-2 6 + node-5 20) -> ~4 GB free
#     pve-3   32 GB total, 18 GB to k3s, PLUS the old Docker VMs, a NAS VM and
#             the secondary PBS VM — the most loaded host of the three
# `pve-5` (203.0.113.15, 32 GB, i5-10505) is the lab's testing hypervisor and is
# the node this is for. Verified reachable from the admin workstation 2026-07-28
# (8006 open, 3 ms RTT).
#
# Being on 203.0.113.0/24 rather than the cluster VLAN is a feature: a pre-prod cluster
# that cannot reach production by accident is the correct blast radius.
#
# ─── HONEST LIMITS ───────────────────────────────────────────────────────────
# Single node, so Longhorn runs with 1 replica instead of 3. That tests the chart,
# the CRDs, the conversion webhooks and the upgrade path — not the replica
# rebuild or node-failure behaviour, which need real peers. Say so in any writeup
# rather than implying pre-prod proves storage HA. It does not.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true
  ssh {
    agent    = true
    username = "root"
  }
}

resource "proxmox_virtual_environment_vm" "preprod" {
  name      = var.node_name
  vm_id     = var.vmid
  node_name = var.pve_node
  tags      = ["k3s-preprod", "disposable"]

  description = <<-EOT
    Pre-prod k3s single node (the pre-production option).
    DISPOSABLE — destroy and recreate freely; nothing here is a source of truth.
    Managed by tofu/preprod. Built by ansible playbooks/k3s-node.yml.
  EOT

  clone {
    vm_id = var.template_id
    full  = true
  }

  agent { enabled = true }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore
    interface    = "scsi0"
    size         = var.boot_disk
    file_format  = "raw"
  }

  # Longhorn's disk. Left raw and unformatted exactly like the production
  # workers; the ansible baseline mounts it at /var/lib/longhorn.
  disk {
    datastore_id = var.datastore
    interface    = "scsi1"
    size         = var.data_disk
    file_format  = "raw"
  }

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_id
  }

  initialization {
    datastore_id = var.datastore
    ip_config {
      ipv4 {
        address = "${var.ip}/24"
        gateway = var.gateway
      }
    }
    user_account {
      username = "kube"
      keys     = [trimspace(var.ssh_public_key)]
    }
  }

  serial_device {}

  lifecycle {
    # The whole point is that this is cheap to replace. No prevent_destroy here,
    # deliberately — unlike the production stack, destroying this is a normal
    # operation rather than an incident.
    ignore_changes = [
      # The cloud-init drive is rewritten on every boot; ignoring it stops tofu
      # proposing a replacement on each plan.
      initialization[0].user_account,
    ]
  }
}
