# 0008 — Rebuild k3s from scratch as an HA cluster spanning pve-1, pve-2, and pve-3

**Status:** Proposed (2026-07-04) — design only; execution planned as a
separate build with its own phases. The as-built record is
[`k3s-v2/AS-BUILT.md`](../../k3s-v2/AS-BUILT.md).

## Context

The current k3s cluster grew organically and has structural flaws that
can't be fixed in place:

- **Broken failure domains.** Two of three control-plane VMs (server1,
  server2) sit on pve-1. Losing pve-1 kills etcd quorum *and* two of three
  workers — the "HA" cluster dies with one physical node.
- **No API VIP.** Kubeconfigs point at a single server IP;
  if that VM is down, tooling breaks even though the
  cluster is fine.
- **Redundant components.** Two ingress stacks (Nginx Ingress *and* Envoy
  Gateway), Rancher on top of ArgoCD + Headlamp, default flannel +
  kube-proxy + servicelb doing what one modern CNI can do.
- **No declared provisioning.** VM specs are "TBD" in the docs; nothing is
  reproducible from code.
- **Untested backups.** Longhorn has no backup target and there is no
  cluster-state backup at all.

Meanwhile ADR 0006 moved all Docker workloads off pve-3 to pve-4. Once the
soak ends and the retired Docker VMs (+ OMV per ADR 0007) are deleted, pve-3
has ~24GB RAM and 6C/12T free — enough to become the **third physical
failure domain** the cluster has always lacked.

Constraints: three hosts with 32GB RAM / ~1TB SSD each; pve-3 keeps the
secondary PBS VM (pbs2) and the Pi-hole LXC; pve-2 lives only on the cluster VLAN; pve-3
needs a cluster-VLAN trunk (switch port + VLAN-aware bridge) it doesn't have today.

## Decision

Build a **new cluster alongside the old one** (fresh VMs, fresh IPs in
192.0.2.0/24), migrate workloads via GitOps + Longhorn backup/restore,
then decommission the old VMs. Never rebuild in place — Forgejo (the
primary Git server) runs on the old cluster and must stay up during the
build.

### Topology — one control plane + one worker per physical node

| VM | VMID | IP | Host | Size |
|----|------|----|------|------|
| node-1 | 501 | 192.0.2.11 | pve-1 | 2 vCPU / 6GB / 60GB |
| node-2 | 502 | 192.0.2.12 | pve-2 | 2 vCPU / 6GB / 60GB |
| node-3 | 503 | 192.0.2.13 | pve-3 | 2 vCPU / 6GB / 60GB |
| node-4 | 504 | 192.0.2.21 | pve-1 | 8 vCPU / 20GB / 100GB + 350GB Longhorn disk |
| node-5 | 505 | 192.0.2.22 | pve-2 | 8 vCPU / 20GB / 100GB + 350GB Longhorn disk |
| node-6 | 506 | 192.0.2.23 | pve-3 | 6 vCPU / 14GB / 100GB + 250GB Longhorn disk |

API VIP **192.0.2.10** (kube-vip, ARP mode, control-plane only).
LoadBalancer pool **192.0.2.200–220**. The old cluster keeps its own
addresses until decommission — no conflicts.

*Why 3+3 and not 3 combined server/worker VMs:* dedicated (tainted)
control planes keep etcd latency insulated from workload spikes — the
single biggest cause of homelab k3s instability — and the overhead is only
~18GB RAM across the fleet. Any one physical node can die and the cluster
keeps quorum (2/3 etcd) and 2/3 of worker capacity.

*Why node-6 is smaller:* pve-3's i5-10505 is two generations older, and
the host also carries pbs2 + Pi-hole. It's labeled
(`node-role/tier=light`) so heavy workloads prefer node-4/node-5; its
Longhorn disk shares the 1TB SSD with the pbs2 datastore (revisit if ADR
0007's NVMe shuffle leaves a spare disk in pve-3 after all).

### Component choices

| Concern | Choice | Reasoning / rejected alternatives |
|---------|--------|-----------------------------------|
| Distribution | k3s (pinned stable, embedded etcd HA) | Known quantity here; full kubeadm adds ops burden with no homelab payoff |
| API HA | kube-vip static pod, VIP in `tls-san` | Fixes the documented "no HA VIP" gap; HAProxy VM would be another SPOF to run |
| CNI | **Cilium** — kube-proxy replacement, LB-IPAM + L2 announcements, Hubble, network policy | One component replaces flannel + kube-proxy + servicelb/MetalLB; eBPF gives real NetworkPolicy + flow observability. Cost: steeper debugging curve than flannel — accepted, this is the enterprise piece |
| Ingress | **ingress-nginx only** (default class) | Ends the dual ingress-nginx/Envoy split. Boring, universally documented. Gateway API can come later via Cilium without adding a component |
| Certs | cert-manager, DNS-01 wildcard via Cloudflare | Same pattern as the existing NPM wildcard cert; no port-forwards exist so HTTP-01 can't work |
| External access | unchanged — NPM on the edge VM (198.51.100.40) proxies to the LB pool; split-DNS wildcard already points at NPM | Cluster stays behind the existing edge tier; no new public surface |
| GitOps | ArgoCD app-of-apps from Forgejo; optional GitHub push-mirror **deferred** (owner will add later) | The chicken-and-egg (Forgejo lives on the old cluster during the build) is handled by sequencing — Forgejo migrates last, so it's always up when ArgoCD needs it. A GitHub mirror remains worthwhile as bootstrap/DR insurance but is not a build dependency |
| Secrets | sealed-secrets | No external dependency; ESO + a vault is overkill until an IdP/vault exists anyway |
| Storage | Longhorn, 3 replicas (one per worker), dedicated data disk per worker; NFS from TrueNAS for bulk data | Replica-per-worker means any node loss is non-disruptive. Bulk/media data doesn't belong on replicated SSD |
| Backups | Longhorn → TrueNAS backup target (closes the missing-backup-target gap); Velero for cluster objects; k3s etcd snapshots shipped off-node; PBS keeps imaging the VMs | Three independent layers: volume, API object, VM image |
| Observability | kube-prometheus-stack + Loki/Alloy in-cluster; Grafana on the observability VM gets the cluster Prometheus as a datasource | One pane of glass stays on the observability VM (ADR 0006 tiering); no second dashboard sprawl |
| Cluster UI | Headlamp; **Rancher is dropped** | Rancher duplicates ArgoCD/Headlamp at ~2GB RAM; upgrades move to system-upgrade-controller |
| Provisioning | OpenTofu (bpg/proxmox) + Ubuntu 24.04 cloud-init template + Ansible baseline; k3s via config-file-driven install | Ends "specs TBD" — a dead node is re-creatable from this repo. IaC lives here; k8s manifests stay in the separate gitops repo |
| Hardening | secrets-encryption at rest, PSS `baseline` default / `restricted` where possible, default-deny NetworkPolicy in app namespaces, API audit log | CIS-lite: the controls that matter without fighting every Helm chart |

## Consequences

- One physical node (any of the three) can fail with no control-plane or
  data loss; ingress LB IPs fail over via L2 announcements.
- pve-3 becomes cluster-critical again (it was being emptied) — accepted:
  it only carries the *third* replica of everything, plus pbs2, and the
  old-VM soak already frees the capacity.
- New skills tax: Cilium and OpenTofu are new to this lab. Mitigated by
  building next to the old cluster with no deadline pressure.
- Rancher users lose its UI; Headlamp + ArgoCD cover the need.
- Running two clusters during migration costs ~30GB RAM across pve-1/pve-2.
  Old-cluster VMs **may be stopped at any point to reclaim RAM** — the only
  hard constraint is that Forgejo (and at least one Longhorn replica of its
  volumes) stays reachable until its Phase 7 migration. Stopped ≠ deleted;
  old VMs are only destroyed in Phase 8.
- Supersedes nothing on paper (the old cluster was never ADR'd), but
  retires the old per-host topology on pve-1 and pve-2.
