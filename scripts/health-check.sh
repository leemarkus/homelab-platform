#!/usr/bin/env bash
# Health check for all homelab nodes and critical services.
# Run from a workstation with SSH key access to the Proxmox nodes.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Proxmox nodes. pve-2 has no interface on 198.51.100.0/24 — only on the k3s VM subnet.
# Addresses are documentation placeholders; edit both lists for your lab.
NODES=(
  "pve-1:198.51.100.11"
  "pve-2:192.0.2.5"
  "pve-3:198.51.100.13"
  "pve-4:198.51.100.14"
  "pve-5:203.0.113.15"
)

# Critical service URLs (edge VM .40, observability VM .42, NAS, PBS, firewall).
SERVICES=(
  "Proxmox pve-1|https://198.51.100.11:8006"
  "Proxmox pve-2|https://192.0.2.5:8006"
  "Proxmox pve-3|https://198.51.100.13:8006"
  "Nginx Proxy Manager|http://198.51.100.40:81"
  "Pi-hole (Pi 5)|http://198.51.100.55/admin"
  "Grafana|http://198.51.100.42:3000"
  "Prometheus|http://198.51.100.42:9090"
  "TrueNAS|https://198.51.100.50"
  "PBS|https://198.51.100.51:8007"
  "OPNsense|https://198.51.100.1"
)

echo "========================================="
echo "  Homelab Health Check - $(date)"
echo "========================================="

echo
echo "--- Node Connectivity ---"
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  if ping -c 1 -W 2 "$ip" &>/dev/null; then
    echo -e "  ${GREEN}OK${NC}    $name ($ip)"
  else
    echo -e "  ${RED}DOWN${NC}  $name ($ip)"
  fi
done

echo
echo "--- Service Health ---"
for entry in "${SERVICES[@]}"; do
  name="${entry%%|*}"
  url="${entry##*|}"
  if curl -sk --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "$url" \
      | grep -qE '^[23]'; then
    echo -e "  ${GREEN}OK${NC}    $name"
  else
    echo -e "  ${RED}FAIL${NC}  $name ($url)"
  fi
done

echo
echo "--- Proxmox Node Resources ---"
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  if ping -c 1 -W 2 "$ip" &>/dev/null; then
    cpu=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$ip" \
      "grep 'cpu ' /proc/stat | awk '{usage=(\$2+\$4)*100/(\$2+\$4+\$5)} END {printf \"%.1f\", usage}'" 2>/dev/null || echo "N/A")
    mem=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$ip" \
      "free | awk '/Mem:/ {printf \"%.1f\", \$3/\$2*100}'" 2>/dev/null || echo "N/A")
    echo -e "  $name: CPU ${cpu}% | RAM ${mem}%"
  fi
done

echo
echo "========================================="
echo "  Check complete"
echo "========================================="
