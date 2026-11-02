resource "proxmox_virtual_environment_vm" "k3s" {
  for_each = var.nodes

  name      = each.key
  vm_id     = each.value.vmid
  node_name = each.value.pve_node
  tags      = ["k3s-v2", each.value.role]

  # Clone the per-node Ubuntu 24.04 cloud-init template (full clone so the
  # resized disk is independent of the base image).
  clone {
    vm_id = each.value.template_id
    full  = true
  }

  agent {
    enabled = true # ansible baseline installs qemu-guest-agent; tofu waits for it
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot disk (resized from the template's small base image).
  #
  # `disk_datastore` falls back to `datastore`, which is still the cloud-init
  # drive's home. They differ on pve-3, where the guests' disks were migrated to
  # the mx500 but the cloud-init drive was not — so a single field could not
  # describe the node, and the file silently described a node that no longer
  # existed. See the notes in variables.tf.
  disk {
    datastore_id = coalesce(each.value.disk_datastore, each.value.datastore)
    interface    = "scsi0"
    size         = each.value.boot_disk
    file_format  = each.value.disk_format
    discard      = each.value.disk_discard
    ssd          = each.value.disk_ssd
  }

  # Optional second disk left raw & unformatted for Longhorn (workers only).
  # ansible mounts it at /var/lib/longhorn.
  dynamic "disk" {
    for_each = each.value.data_disk > 0 ? [1] : []
    content {
      datastore_id = coalesce(each.value.disk_datastore, each.value.datastore)
      interface    = "scsi1"
      size         = each.value.data_disk
      file_format  = each.value.disk_format
      discard      = each.value.disk_discard
      ssd          = each.value.disk_ssd
      # Excluded from vzdump by default — see variables.tf. This is the single
      # highest-impact line in this file for cluster stability.
      backup = each.value.data_disk_backup
    }
  }

  network_device {
    bridge  = "vmbr0" # vlan-aware on both pve-1 and pve-2
    vlan_id = var.vlan_id
  }

  initialization {
    datastore_id = each.value.datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      username = "kube"
      keys     = [trimspace(var.ssh_public_key)]
    }
  }

  serial_device {} # matches template's serial0 console

  operating_system {
    type = "l26"
  }

  lifecycle {
    # cloud-init user_account password/hash churn and template disk metadata
    # otherwise force spurious replacements.
    ignore_changes = [
      initialization[0].user_account,
      clone,
    ]
  }
}
