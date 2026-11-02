# 03 — Provisioning (Phases 0–1)

> **Status (2026-09-25):** design intent, written as the 2026-07 build plan. [AS-BUILT.md](AS-BUILT.md) is authoritative for what is running ([README](README.md)).

Everything needed to go from three Proxmox hosts to six booted, baselined
Ubuntu VMs. The code blocks here are **reference copies**; the live files
are in `tofu/k3s/` and `ansible/` at the repo root, and where the two
differ, the live files win.

## Version Pins

Single source of truth for versions across all k3s-v2 docs. These are
**example pins recorded at design time (2026-07-04)** — before executing a
phase, check each project's releases and bump the row.

| Component | Pin | Notes |
|---|---|---|
| Ubuntu cloud image | 24.04 (noble), current serial | `noble-server-cloudimg-amd64.img` |
| k3s | `v1.34.4+k3s1` | the July 2026 build; rebuilds install the version pinned in the `k3s_node` role |
| kube-vip | `v0.9.2` | ARP mode |
| Cilium (helm) | `1.17.5` | kube-proxy replacement on |
| ingress-nginx (chart) | `4.13.0` | |
| cert-manager | `v1.18.2` | `installCRDs: true` |
| ArgoCD (chart) | `8.1.2` | |
| sealed-secrets (chart) | `2.17.3` | |
| Longhorn | `1.9.0` | |
| kube-prometheus-stack (chart) | `75.6.0` | grafana disabled |
| Loki (chart) | `6.30.1` | single-binary mode |
| Alloy (chart) | `1.1.1` | log shipping DaemonSet |
| Velero (chart) | `10.0.1` | aws plugin for MinIO |
| system-upgrade-controller | `v0.16.0` | |
| nfs-subdir-external-provisioner (chart) | `4.0.18` | `nfs-bulk` class |
| OpenTofu | `1.9.x` | provider `bpg/proxmox ~> 0.78` |

## Prerequisites Checklist (Phase 0)

Work through in order; all boxes must be checked before Phase 1.

- [ ] **ADR 0006 soak closed**: the retired Docker VMs on pve-3 deleted (final
      PBS backup first) and the OMV VM question (ADR 0007) resolved either way.
      This frees pve-3's RAM budget.
- [ ] **The cluster VLAN trunked to pve-3**: see below.
- [ ] **OPNsense rules**: workstation/LAN → the cluster VLAN :6443/:80/:443 (mostly exists);
      the cluster VLAN → 198.51.100.50 :2049 (NFS) and :9000 (MinIO);
      198.51.100.40 (NPM) → 192.0.2.200 :80/:443.
- [ ] **IPs reserved** in the network plan ([01-architecture.md](01-architecture.md)):
      VIP 192.0.2.10, nodes .11–.13 and .21–.23, LB pool .200–.220. Confirm none
      of them overlaps the cluster VLAN's DHCP scope.
- [ ] **Backup target ready**: TrueNAS dataset `tank/lab-backups`; MinIO
      serving it at `https://s3.example.com`, bucket `lab-backups`, with the
      access/secret key kept outside the repository.
- [ ] **k3s join token generated** (`openssl rand -hex 16`) and kept in the
      operator's password manager.

During the build the v1 cluster still ran on pve-1/pve-2. Its VMs could be
stopped (never destroyed) to free RAM, as long as Forgejo kept serving until
its Phase 7 migration, since ArgoCD and every git operation depended on it.

A GitHub push-mirror of the gitops repo is optional and deferred; nothing in
Phases 0–8 depends on it.

## Trunking the cluster VLAN to pve-3

1. **Switch** (TP-Link, http://198.51.100.2): on pve-3's port, keep PVID 1
   untagged and add the cluster VLAN **tagged** (mirror pve-1's port config).
2. **pve-3**: make the bridge VLAN-aware (`/etc/network/interfaces`):

   ```
   auto vmbr0
   iface vmbr0 inet static
           address 198.51.100.13/24
           gateway 198.51.100.1
           bridge-ports enp1s0
           bridge-stp off
           bridge-fd 0
           bridge-vlan-aware yes
           bridge-vids 2-4094
   ```

   Apply with `ifreload -a` (from the console, not over SSH if you can
   avoid it: a mistake here cuts you off).
3. **Test**: create a throwaway VM with `net0: virtio,bridge=vmbr0,tag=100`,
   a spare static IP (e.g. 192.0.2.99/24), gateway 192.0.2.1. It must ping 192.0.2.5
   (pve-2) and 198.51.100.1. Delete it afterwards.

## Cloud-Init Template (per host)

Run on **each** of pve-1, pve-2, pve-3 (local template, no shared-storage
dependency). Template VMID 900 everywhere.

```bash
#!/usr/bin/env bash
# create-k3s-template.sh — run on each Proxmox host
set -euo pipefail

VMID=900
STORAGE=local-lvm            # adjust per host if the VM store is named differently
IMG=noble-server-cloudimg-amd64.img

cd /tmp
wget -N https://cloud-images.ubuntu.com/noble/current/${IMG}

qm destroy ${VMID} --purge 2>/dev/null || true
qm create ${VMID} --name k3s-v2-template --machine q35 --bios ovmf \
  --efidisk0 ${STORAGE}:1,efitype=4m,pre-enrolled-keys=1 \
  --cpu host --sockets 1 --cores 2 --memory 2048 \
  --net0 virtio,bridge=vmbr0,tag=100 \
  --scsihw virtio-scsi-single --agent enabled=1 \
  --serial0 socket --vga serial0
qm set ${VMID} --scsi0 ${STORAGE}:0,import-from=/tmp/${IMG},discard=on,ssd=1
qm set ${VMID} --ide2 ${STORAGE}:cloudinit --boot order=scsi0
qm template ${VMID}
echo "template ${VMID} ready on $(hostname)"
```

## OpenTofu — `tofu/k3s/`

Layout: `providers.tf`, `variables.tf`, `nodes.tf`, plus a gitignored
`secrets.auto.tfvars` holding the API token (template:
`secrets.auto.tfvars.example`). Read the real files rather than a copy here:

- [`providers.tf`](../tofu/k3s/providers.tf): the bpg/proxmox provider; the
  endpoint and API token come from tfvars.
- [`variables.tf`](../tofu/k3s/variables.tf): the `nodes` map (VMID, host,
  template, datastore, IP, cores, memory and disks for each of the six VMs),
  plus the VLAN tag and gateway.
- [`nodes.tf`](../tofu/k3s/nodes.tf): one `proxmox_virtual_environment_vm` per
  map entry, cloned from the host's local template, with a Longhorn data disk
  on workers only and a static cloud-init address.

Apply:

```bash
cd tofu/k3s
tofu init
tofu plan          # review: 6 to add, 0 to change, 0 to destroy
tofu apply
```

## Ansible Baseline — `ansible/`

Inventory additions (`ansible/inventory/hosts.yml`; the public repo ships
`hosts.example.yml`):

```yaml
k3s_v2:
  children:
    k3s_v2_control:
      hosts:
        node-1: { ansible_host: 192.0.2.11 }
        node-2: { ansible_host: 192.0.2.12 }
        node-3: { ansible_host: 192.0.2.13 }
    k3s_v2_worker:
      hosts:
        node-4: { ansible_host: 192.0.2.21 }
        node-5: { ansible_host: 192.0.2.22 }
        node-6: { ansible_host: 192.0.2.23, k3s_tier: light }
  vars:
    ansible_user: kube
```

Playbook (`ansible/playbooks/k3s-v2-baseline.yml`):

```yaml
---
- name: k3s v2 node baseline
  hosts: k3s_v2
  become: true
  tasks:
    - name: Install prerequisites
      ansible.builtin.apt:
        name: [qemu-guest-agent, nfs-common, open-iscsi, curl, jq]
        state: present
        update_cache: true

    - name: Enable iscsid and guest agent
      ansible.builtin.systemd:
        name: "{{ item }}"
        enabled: true
        state: started
      loop: [iscsid, qemu-guest-agent]

    - name: Disable swap now and permanently
      ansible.builtin.shell: swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab
      changed_when: false

    - name: Kernel modules for Kubernetes
      community.general.modprobe: { name: "{{ item }}", state: present, persistent: present }
      loop: [br_netfilter, overlay]

    - name: Sysctls
      ansible.posix.sysctl: { name: "{{ item.k }}", value: "{{ item.v }}", state: present }
      loop:
        - { k: net.ipv4.ip_forward, v: "1" }
        - { k: fs.inotify.max_user_instances, v: "512" }
        - { k: fs.inotify.max_user_watches, v: "1048576" }

    - name: Security-only unattended upgrades
      ansible.builtin.apt: { name: unattended-upgrades, state: present }

- name: Worker data disk for Longhorn
  hosts: k3s_v2_worker
  become: true
  tasks:
    - name: Filesystem on /dev/sdb
      community.general.filesystem: { fstype: ext4, dev: /dev/sdb }
    - name: Mount /var/lib/longhorn
      ansible.posix.mount:
        path: /var/lib/longhorn
        src: /dev/sdb
        fstype: ext4
        opts: defaults,noatime
        state: mounted
```

Run: `ansible-playbook -i inventory/hosts.yml playbooks/k3s-v2-baseline.yml`

## Verification (Phase 1 gate)

```bash
for ip in 31 32 33 41 42 43; do ssh kube@192.0.2.$ip 'hostname && free -h | head -2'; done
ssh kube@192.0.2.21 'df -h /var/lib/longhorn && systemctl is-active iscsid'
```

- [ ] All 6 respond, hostnames match `node-1..node-6`
- [ ] Workers show `/var/lib/longhorn` mounted at the right size
- [ ] `tofu plan` is clean (no drift)
- [ ] Destroy/recreate test: `tofu destroy -target='proxmox_virtual_environment_vm.k3s["node-4"]'`,
      re-apply, re-run playbook — total under ~15 minutes. This *is* the
      node-replacement DR path: prove it now, before anything depends on it.
