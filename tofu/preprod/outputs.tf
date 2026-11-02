output "preprod_ip" {
  description = "Address to add to the ansible inventory as preprod-1."
  value       = var.ip
}

output "next_steps" {
  description = "What to run after apply — the node is bare until ansible builds it."
  value       = <<-EOT
    1. Add to ansible/inventory/hosts.yml under the k3s_preprod group:
         preprod-1: { ansible_host: ${var.ip} }
    2. ansible-playbook playbooks/k3s-v2-baseline.yml --limit preprod-1
    3. ansible-playbook playbooks/k3s-node.yml --limit preprod-1 \
         -e "k3s_token=$K3S_PREPROD_TOKEN"
       Use a token DIFFERENT from production's — this node must never be able to
       join the real cluster, and a shared token is the only thing that would let
       it.
  EOT
}
