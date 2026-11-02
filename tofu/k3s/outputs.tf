output "nodes" {
  description = "Provisioned k3s VMs: name → ip/role/host."
  value = {
    for name, cfg in var.nodes : name => {
      ip       = cfg.ip
      role     = cfg.role
      pve_node = cfg.pve_node
      vmid     = cfg.vmid
    }
  }
}

output "control_plane_ips" {
  description = "Control-plane node IPs (first is the cluster-init bootstrap node)."
  value       = [for name, cfg in var.nodes : cfg.ip if cfg.role == "control"]
}

output "worker_ips" {
  description = "Worker node IPs."
  value       = [for name, cfg in var.nodes : cfg.ip if cfg.role == "worker"]
}

output "ansible_inventory_hint" {
  description = "Paste-ready host lines for ansible/inventory/hosts.yml (k3s_v2 group)."
  value = join("\n", [
    for name, cfg in var.nodes :
    "        ${name}: { ansible_host: ${cfg.ip} }"
  ])
}
