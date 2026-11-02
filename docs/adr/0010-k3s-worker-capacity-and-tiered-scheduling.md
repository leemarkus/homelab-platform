# 0010 — k3s worker capacity growth + tiered scheduling (3 workers)

**Status:** Accepted — implemented 2026-07-24 (node-4/node-5 grown to
20 GB / 6 vCPU via rolling drain+apply, one at a time, Longhorn healthy after
each; tier labels + pve-3 taint applied; live-verified)
**Relates to:** [0008](0008-k3s-v2-enterprise-rebuild.md) (v2 rebuild; this
executes its "Phase 8 — grow workers toward spec" line, and answers "add more
workers?" with **no — grow the three we have**)

## Context

The v1 cluster that shared pve-1/pve-2/pve-3 was powered off 2026-07-17
(Phase 7 done, `qm stop` + `onboot 0`). The RAM it held is now free, so the
deliberately-reduced v2 worker sizing (ADR 0008) can grow. Current live state:

| Host (32 GB) | control | worker (now) | free-ish |
|---|---|---|---|
| pve-1 | node-1 6 GB | **node-4 6 GB** | ~18 GB |
| pve-2 | node-2 6 GB | **node-5 10 GB** | ~14 GB |
| pve-3 | node-3 6 GB | node-6 12 GB | shares the host with the old Docker VMs, a media VM and the LXCs — oversubscribed |

The question raised was whether to **add worker4/worker5** on pve-1/pve-2 and
split the freed RAM across two worker VMs per host, or keep three workers (one
per physical host) and grow them. And whether workloads should be **pinned** to
specific workers or scheduled automatically.

**Adding a second worker VM per physical host was rejected:**

- **No HA gain.** node-4 and a hypothetical worker4 share one Dell — they die
  together. HA comes from spreading across *physical* hosts, which the current
  one-worker-per-host layout already does. A second VM on the same box is HA
  theater.
- **Pure overhead.** Each node runs its own kubelet + Cilium agent + OS +
  containerd — ~0.5–1 GB RAM and CPU gone before any workload pod schedules.
  Two 10 GB workers give *less* usable RAM than one 20 GB worker.
- **Worse bin-packing.** A pod needing 14 GB fits one 20 GB worker but neither
  of two 10 GB workers. Splitting caps the largest schedulable pod.
- **Longhorn footgun.** Longhorn spreads replicas across *nodes* but by default
  treats two VMs on one Dell as two independent nodes — it can place both
  replicas of a volume on the same physical host and believe the data is safe.
  Two workers per host manufactures a data-loss hazard that then has to be
  undone with zone anti-affinity.

The one legitimate reason to run two workers on a host — draining/rebooting one
without touching the other — is already covered by having workers on the *other*
two hosts.

## Decision

**Keep three workers, one per physical host. Grow node-4 and node-5 into the
freed RAM, equalized. Keep node-6 (on pve-3) small and steer heavy work away
from it.**

### Capacity (tofu `var.nodes`, `tofu/k3s/variables.tf`)

Per host budget: 32 GB − ~2 GB Proxmox host − 6 GB control plane = ~24 GB for
the worker; target 20 GB (the ADR 0008 spec) to leave ~4 GB host headroom.

| Worker | Host | RAM now → target | vCPU now → target | data_disk |
|---|---|---|---|---|
| node-4 | pve-1 | 6 GB → **20 GB** | 4 → **6** | 120 GB (unchanged this ADR) |
| node-5 | pve-2 | 10 GB → **20 GB** | 4 → **6** | 120 GB (unchanged this ADR) |
| node-6 | pve-3 | 12 GB (**unchanged**) | 4 (unchanged) | 120 GB |

node-4 and node-5 land at the **same** 20 GB — the "equally split, maximize
usage" goal, since with one worker per host equalizing the two hosts *is* the
even split. Longhorn data-disk growth toward the 350 GB spec is a **separate
task** (needs a disk add/resize + rebalance) and is deliberately out of scope
here. CPU is overcommit-safe (2 control + 6 worker = 8 of 16 threads committed);
8 vCPU is the ADR 0008 ceiling if more is wanted later.

### Scheduling — automatic, steered by labels/taints, never hard-pinned

Pods are **not** pinned to named workers (`nodeSelector: node-4` would make a
pod un-reschedulable when that node is down — a self-healing cluster turned into
a SPOF). Instead:

1. **Tier labels** on nodes:
   - `node.homelab.tech/tier=heavy` on node-4, node-5
   - `node.homelab.tech/tier=light` on node-6
   (The existing `topology.kubernetes.io/zone` = `pve-1|pve-2|pve-3` stays the
   HA-spread key.)
2. **Soft taint on node-6** so general workloads drift off pve-3, honoring
   "leave pve-3 for lighter workloads":
   ```
   kubectl taint nodes node-6 workload-tier=light:PreferNoSchedule
   ```
   `PreferNoSchedule` (not `NoSchedule`) keeps it soft — if pve-1/pve-2 are full,
   pods can still land on pve-3 rather than going Pending. Only pods that tolerate
   it settle there by preference.
3. **Preferred (soft) nodeAffinity toward `tier=heavy`** on the memory-hungry
   apps (Longhorn-heavy, Prometheus, Loki, etc.):
   ```yaml
   affinity:
     nodeAffinity:
       preferredDuringSchedulingIgnoredDuringExecution:
       - weight: 100
         preference:
           matchExpressions:
           - key: node.homelab.tech/tier
             operator: In
             values: ["heavy"]
   ```
4. **topologySpreadConstraints across zones** for anything that wants HA, so
   replicas don't pile onto one Dell:
   ```yaml
   topologySpreadConstraints:
   - maxSkew: 1
     topologyKey: topology.kubernetes.io/zone
     whenUnsatisfiable: ScheduleAnyway
     labelSelector: { matchLabels: { app.kubernetes.io/name: <app> } }
   ```

Hard `nodeSelector` stays reserved for pods genuinely tied to a node (specific
local hardware) — none exist today.

Node labels/taints are applied imperatively for now (commands above);
per-app affinity/tolerations/spread land in the app manifests in the
gitops repository and roll out via ArgoCD.

## Consequences

- **Rolling, drained, one worker at a time** — memory/CPU resize needs a VM
  reboot. Procedure: `kubectl drain node-4 --ignore-daemonsets
  --delete-emptydir-data` → tofu apply (node-4 only) / reboot → `uncordon` →
  wait for Longhorn to report the node's replicas healthy → repeat for node-5.
  Never both at once (Longhorn needs a replica quorum).
- **node-4/node-5 double / nearly-double their schedulable RAM** (6→20,
  10→20) with no new nodes to patch, back up, or monitor.
- **Hosts run ~28/32 GB committed** (6 control + 20 worker + ~2 Proxmox),
  ~4 GB headroom — acceptable; not ballooned to the edge.
- **pve-3 stays light by policy, not by luck** — the soft taint keeps heavy
  workloads off the box that also runs the Docker/tier VMs, and reverses cleanly
  (`kubectl taint nodes node-6 workload-tier-`).
- **Longhorn data-disk growth still owed** — RAM is fixed here; the 120→350 GB
  disk task and any replica rebalance are tracked separately in Phase 8.
- **Applied 2026-07-24** via `tofu apply -target` per worker (in-place update,
  0 destroyed), each preceded by `kubectl drain` and followed by uncordon +
  a wait for Longhorn robustness=healthy. Live capacity confirmed:
  node-4/node-5 = 20480 MiB / 6 vCPU. A pre-existing drift on pve-3's VMs
  (node-3/node-6 provisioned on `mx500`/qcow2 vs the config's
  `local-lvm`/raw) was **left untouched** by targeting — a separate reconcile.
- Supersedes nothing; extends ADR 0008 Phase 8.
