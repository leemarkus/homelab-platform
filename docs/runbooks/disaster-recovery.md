# Runbook: Disaster Recovery

> **Status (2026-09-25):** current — last reviewed 2026-07-28 for the ADR 0006
> cutover (pve-3 no longer hosts the Docker services), ADR 0011 decision 1 (k3s
> VMs are **not** in vzdump — a lost k3s node is a *rebuild*, not a restore),
> and the existence of `preprod-1` on pve-5. The k3s-specific procedures below
> are summaries; [`k3s-v2/08-backup-dr.md`](../../k3s-v2/08-backup-dr.md) and
> [`node-rebuild.md`](node-rebuild.md) are authoritative.

## Scenario: Single Proxmox Node Failure

> **v2 topology is symmetric:** each of pve-1 / pve-2 / pve-3 runs exactly **one
> control-plane (etcd) + one worker**. So **any single host failure keeps etcd
> quorum (2/3)** and the API stays up on the kube-vip VIP `192.0.2.10`. This is
> the ADR 0008 improvement over v1 (which stacked two servers on pve-1).

### If pve-3 (198.51.100.13) goes down

**Impact:** pve-3 runs **node-3 (192.0.2.13) + node-6 (192.0.2.23)**, the
secondary PBS VM `pbs2` (198.51.100.52), the OMV VM (kept, since
ADR 0007 was rejected 2026-07-29), the secondary Pi-hole LXC,
and the drained Docker VMs retired by ADR 0006. An outage costs:

- One of three etcd members and one of three workers — **quorum holds**
- The **second physical copy** of the PBS backups (the pbs2 pull-sync target)
- **OMV** file shares
- The **secondary Pi-hole**

**Not affected** by a pve-3 outage:

- `*.apps.example.com` — NPM runs on the **edge VM (198.51.100.40, on pve-4)**
  since the ADR 0006 cutover
- The **canonical Pi-hole** on the Raspberry Pi 5 (198.51.100.55) keeps DNS working
- The v2 k3s cluster **keeps quorum** — pve-3 hosts only node-3 + node-6
- TrueNAS and the primary PBS keep running

**Recovery:**

1. Check physical hardware — power, NVMe health, boot drive.
2. ⚠️ **node-3 / node-6 have no image backup** (ADR 0011 decision 1, applied
   2026-07-28). Do not look for them in PBS — rebuild them from code with
   [`node-rebuild.md`](node-rebuild.md) (`tofu` + `ansible`; the `cilium` role
   is adopted, so a rebuilt node comes up with working pod networking). Their
   state lives in etcd snapshots, Longhorn backups and Velero.
3. For the **pet** guests (pbs2, OMV), restore the VMs from the primary PBS
   (https://198.51.100.51:8007, the PBS VM on pve-4; the secondary is
   198.51.100.52:8007 on pve-3):
   ```bash
   # On any other Proxmox node, add PBS storage if not already added
   # Datacenter > Storage > Add > Proxmox Backup Server
   #   Server: 198.51.100.51   (primary; use 198.51.100.52 if pve-4 is also down)
   #   Datastore: pbs-datastore
   # Then restore each VM
   ```
4. If restoring to pve-5 temporarily, update bridge/VLAN bindings so the VMs
   land on the right subnet — the sandbox network is `vmbr0.200`, not an untagged
   `vmbr0`. The sandbox host also runs `preprod-1` and the VM template; leave
   preprod's isolation from the cluster VLAN intact.
5. Devices that use the secondary Pi-hole for DNS fail until they are pointed at
   the Pi 5.

### If pve-1 (198.51.100.11) goes down

**Impact:** k3s loses node-1 (192.0.2.11) + node-4 (192.0.2.21) — 1 of 3 control
planes, 1 of 3 workers. **Quorum holds** (node-2 on pve-2 + node-3 on pve-3 =
2/3 etcd); the API stays up on the VIP `192.0.2.10`. The dedicated Forgejo VM
(ADR 0011 decision 3) also runs on pve-1.

1. The cluster continues with reduced capacity; Longhorn re-replicates off the
   lost zone.
2. **Rebuild, don't restore.** The k3s VMs are excluded from vzdump (ADR 0011
   decision 1) — there is no PBS image to restore. Follow
   [`node-rebuild.md`](node-rebuild.md), which is proven on node-4 in
   production (2026-07-28): `tofu` re-creates the VM, `ansible` joins it.
3. Only if **both** other control planes are also lost do you restore from an
   etcd snapshot; otherwise a rebuilt server just rejoins:
   ```bash
   curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server \
     --server https://192.0.2.10:6443
   ```
   Use the **production** token, not preprod-1's — they are deliberately different.

### If pve-2 (192.0.2.5) goes down

**Impact:** loses node-2 (192.0.2.12) + node-5 (192.0.2.22). **Quorum holds**
(2/3 control planes on pve-1 + pve-3).

1. The cluster continues with reduced capacity.
2. Rebuild node-2 / node-5 from code when the hardware is fixed — same as pve-1
   above; there is no PBS image for k3s VMs.
3. Pods from the lost worker reschedule onto the remaining workers.

### If pve-4 (198.51.100.14) goes down — storage/backup SPOF

> The old bare-metal TrueNAS box and its PBS are retired (2026-07). The TrueNAS
> VM (198.51.100.50), the primary PBS VM (198.51.100.51) **and** the ADR 0006
> tier VMs (edge 198.51.100.40 / apps 198.51.100.41 / observability
> 198.51.100.42) all run on **pve-4**, so pve-4 is the single most consequential
> node to lose.

**Impact:** loss of `tank` (NFS for the Proxmox `truenas` storage and the PBS
datastore), the primary PBS backups, the MinIO object store, and all
reverse-proxy/app/monitoring services on the tier VMs. The k3s v2 cluster (on
pve-1/pve-2/pve-3) keeps running; the **secondary** PBS on pve-3
(198.51.100.52) holds the nightly sync copy, so VM backups are not lost.

1. Reverse proxy, dashboards and monitoring are down until pve-4 (or the tier
   VMs) are restored — restore the tier VMs from PBS (use 198.51.100.52 if the
   primary is unavailable).
2. Diagnose hardware. pve-4's storage rides a JMB585 HBA; check its 32-bit DMA
   gotcha before touching the disks.
3. If the drives are fine but the system is dead, install TrueNAS on new
   hardware and import the ZFS pool:
   ```bash
   zpool import tank
   ```
4. Bring the PBS VM back up once TrueNAS is online — its datastore is
   NFS-mounted from `/mnt/tank/pbs/pbs-datastore`.

## Scenario: K3s Cluster Recovery

### Full cluster rebuild

1. Provision the six VMs (VMIDs 501–503 / 504–506) across **pve-1 / pve-2 /
   pve-3** on the 192.0.2.0/24 VLAN with the IPs in the
   [ADR 0008 topology table](../adr/0008-k3s-v2-enterprise-rebuild.md#topology--one-control-plane--one-worker-per-physical-node)
   — via `tofu/k3s`, not by hand.
2. Build them with the Ansible playbooks (`k3s-v2-baseline.yml`, `k3s-node.yml`).
   The `cilium` role is adopted into code as of 2026-07-28, so pod networking
   comes up without a hand-run `helm install`. See
   [`cilium-adoption.md`](cilium-adoption.md) and [`node-rebuild.md`](node-rebuild.md).
3. Restore etcd from the newest snapshot (restore proven 2026-07-27 — 12,702 keys).
4. Point ArgoCD at the gitops repository (`clusters/homelab/` on Forgejo) — it
   redeploys all apps. Forgejo runs on its own VM outside the cluster since
   2026-07-29 (ADR 0011 decision 3), so the rebuild no longer depends on a Git
   server that lives on the cluster being rebuilt.
5. Restore Longhorn volumes from the backup target (restore path proven
   2026-07-27; note `weekly-backup` gives an RPO of up to seven days).
6. Rehearse chart/version changes on **preprod-1** (203.0.113.20) first.

## Management endpoints

| What | Where |
|------|-------|
| Proxmox | https://198.51.100.11:8006 (pve-1) / https://192.0.2.5:8006 (pve-2) / https://198.51.100.13:8006 (pve-3) / https://198.51.100.14:8006 (pve-4) / https://203.0.113.15:8006 (pve-5) |
| preprod-1 (pre-prod k3s) | `ssh kube@203.0.113.20`; its own kubeconfig, separate from production |
| OPNsense | https://198.51.100.1 |
| TrueNAS | https://198.51.100.50 (VM on pve-4) |
| PBS | https://198.51.100.51:8007 (primary, pve-4) / https://198.51.100.52:8007 (secondary, pve-3) |
| NPM | http://198.51.100.40:81 (edge VM on pve-4) |
| Cloudflare | Cloudflare dashboard |

Credentials are kept in the operator's password manager, outside the repository.
