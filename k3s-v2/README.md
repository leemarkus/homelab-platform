# k3s v2: the HA cluster

A from-scratch, highly available k3s cluster spanning three Proxmox hosts
(pve-1, pve-2, pve-3), with one control-plane node and one worker on each, so
the failure domain is the physical host. It was built for two purposes at once:

1. **A learning platform.** Every layer (provisioning, networking, GitOps,
   storage, observability, DR) is built from code, documented with the *why*,
   and mapped to its production counterpart.
2. **A real homelab.** Any one host can die, backups are tested rather than
   assumed, and the cluster is reconstructable from Git plus backups.

> **Design vs. reality.** Docs 01–09 are the design intent written for the
> July 2026 build. [AS-BUILT.md](AS-BUILT.md) is a dated snapshot of what was
> built (July 2026); where it differs from the design, see
> [AS-BUILT § 7](AS-BUILT.md#7-divergences-from-adr-0008).
> The decision record is [ADR 0008](../docs/adr/0008-k3s-v2-enterprise-rebuild.md).

## Cluster at a glance

| Property | Value |
|---|---|
| Distribution | k3s with embedded etcd (HA); rebuilds install the version pinned in `ansible/roles/k3s_node/defaults/main.yml` |
| Topology | 3 control planes + 3 workers, one pair per physical host |
| API endpoint | `https://192.0.2.10:6443` (kube-vip VIP, ARP mode) |
| CNI | Cilium: kube-proxy replacement, LB-IPAM, L2 announcements, Hubble, NetworkPolicy |
| LoadBalancer pool | 192.0.2.200–220; ingress-nginx pinned at 192.0.2.200 |
| GitOps | Argo CD app-of-apps reconciling the separate gitops repository |
| Storage | Longhorn, 3 replicas with hard zone anti-affinity (one per host) |
| Backups | Longhorn and Velero to S3-compatible object storage on the NAS, etcd snapshots off-node |
| Secrets | Sealed Secrets (controller key escrowed outside the cluster) |
| Observability | kube-prometheus-stack, Loki and Alloy in-cluster |
| Node OS | Ubuntu 24.04 LTS from a Packer template, cloud-init, SSH user `kube` |
| Provisioning | OpenTofu (bpg/proxmox) + Ansible |

**VMs** (the cluster VLAN, 192.0.2.0/24), as declared in `tofu/k3s/variables.tf`:

| Node | VMID | IP | Host | vCPU | RAM | Disks |
|---|---|---|---|---|---|---|
| node-1 (control, etcd bootstrap) | 501 | 192.0.2.11 | pve-1 | 2 | 6 GB | 60 GB |
| node-2 (control) | 502 | 192.0.2.12 | pve-2 | 2 | 6 GB | 60 GB |
| node-3 (control) | 503 | 192.0.2.13 | pve-3 | 2 | 6 GB | 60 GB |
| node-4 (worker) | 504 | 192.0.2.21 | pve-1 | 6 | 12 GB | 80 GB + 120 GB Longhorn |
| node-5 (worker) | 505 | 192.0.2.22 | pve-2 | 6 | 20 GB | 80 GB + 120 GB Longhorn |
| node-6 (worker, light tier) | 506 | 192.0.2.23 | pve-3 | 4 | 12 GB | 80 GB + 120 GB Longhorn |

## Documentation map

| Doc | Contents | Read when |
|---|---|---|
| [01-architecture.md](01-architecture.md) | Physical and virtual topology, failure domains, IP plan, resource budgets | you want the big picture |
| [02-design-decisions.md](02-design-decisions.md) | Each choice against its alternatives, v1 vs v2, homelab-to-enterprise mapping | you want the *why* |
| [03-provisioning.md](03-provisioning.md) | Version pins, VLAN prep, templates, OpenTofu, Ansible baseline | you're building nodes |
| [04-cluster-build.md](04-cluster-build.md) | k3s configs, kube-vip, Cilium, node joins, smoke tests | you're standing up Kubernetes |
| [05-platform-services.md](05-platform-services.md) | Ingress, certificates, Argo CD bootstrap, Sealed Secrets, Longhorn, monitoring | you're installing platform layers |
| [06-operations.md](06-operations.md) | Day-2 workflows: deploy, upgrade, drain, recover, diagnose | you're running the cluster |
| [07-testing.md](07-testing.md) | Acceptance gates, validation, chaos drills | you're proving it works |
| [08-backup-dr.md](08-backup-dr.md) | Backup layers, RPO/RTO targets, restore procedure per failure scenario | something broke, or you're drilling |
| [09-traffic-flows.md](09-traffic-flows.md) | Sequence diagrams for request paths, GitOps, certificate issuance, backups | you're tracing a packet or a deploy |
| [AS-BUILT.md](AS-BUILT.md) | What ran at the July 2026 snapshot, the traps hit during the build, drill results | always, first |
| [docs/longhorn-multipath.md](docs/longhorn-multipath.md) | Keeping multipathd away from Longhorn's iSCSI devices | a Longhorn volume will not attach |
| [live/](live/README.md) | The configs and Helm values as applied (tokens redacted) | you need the exact values |

Suggested paths: **builder** 03 → 04 → 05 → 07 → 08; **operator** 06, then 08,
with 09 open while debugging traffic; **reader** 01 → 02 → 09.

## How this fits with the rest of the lab

- **This repository provisions** the layers below Kubernetes (Proxmox VMs,
  node OS, k3s, the CNI) and documents the cluster.
- **Kubernetes manifests live in the gitops repository**
  (`clusters/homelab/`), which Argo CD reconciles. Cilium, kube-vip, Sealed
  Secrets and Argo CD itself are bootstrap-tier and stay outside Argo CD.
- Tokens and credentials never live here; the docs say where a value is
  needed, never what it is.

Diagrams are [Mermaid](https://mermaid.js.org/), rendered by GitHub and
diffable as text. Command placeholders use `<angle-brackets>`.
