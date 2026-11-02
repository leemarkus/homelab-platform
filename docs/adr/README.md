# Architecture decisions

Each record captures one decision at the point it was made: context, the
decision, and the consequences accepted with it. Records are append-only; a
revisited decision gets a new record that supersedes the old one.

The lab has sixteen decision records (0001–0015 and 0018). This public copy
carries the four that shape the cluster code here. The others cover lab wiring
outside this repository's scope (the Docker VM layout, storage passthrough for
the NAS, the two backup servers, the function-tier VMs, the media VM, a landing
page, remote access, a self-hosted wiki) and stay in the private repository, so
their numbers are skipped. Records here still mention some of them by number
(for example ADR 0006, which moved the Docker workloads into three
function-tier VMs on pve-4); those are plain references, not links.

| ADR | Decision | Status |
|---|---|---|
| [0008](0008-k3s-v2-enterprise-rebuild.md) | Rebuild k3s from scratch as an HA cluster with one control plane and one worker per physical host | proposed (design record; the build it describes is in [AS-BUILT](../../k3s-v2/AS-BUILT.md)) |
| [0010](0010-k3s-worker-capacity-and-tiered-scheduling.md) | Grow the three workers rather than add more, and steer heavy work off the older host with a soft taint | accepted, implemented 2026-07-24 |
| [0011](0011-lab-operating-posture.md) | Lab operating posture: cattle nodes, an off-cluster delivery plane, backups that are proven by restore | accepted 2026-07-28 |
| [0014](0014-kubeconfig-access-sufficient.md) | Kubeconfig-based access is sufficient for a single-operator cluster | accepted 2026-09-30 |
