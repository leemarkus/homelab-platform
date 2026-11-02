# 0011 — Lab operating posture: cattle nodes, an off-cluster delivery plane, and backups that are proven

**Status:** **Accepted 2026-07-28** by the operator — decisions 1, 3, 5 and 6 ratified
explicitly; 2 was applied the same day; 4, 7 and 8 are standing posture rather
than work. Supersedes nothing; it makes explicit a posture that was previously
implicit and inconsistently applied.

Ratification does not change the sequencing constraints written into each
decision — in particular, decision 1 still may not land before its two
preconditions, and it must not land before decision 5. What acceptance changes
is that the work is now committed rather than proposed.

**What accepting this costs, stated plainly so it is not discovered later:**
roughly 20–30 hours that weeks 2–6 of the lab completion plan (2026-07-27)
have no capacity for at 8–10 h/wk, of which decision 3 (Forgejo relocation,
8–12 h plus a soak) is not in that plan at all. Either the plan's close date
moves or something in it is displaced. That is a scheduling consequence, not a
reason to revisit the decisions.

## Implementation status (2026-07-28, end of day)

| # | Decision | State |
|---|---|---|
| 1 | k3s nodes are cattle | ✅ **Complete.** Cilium adopted into code (a), node-4 destroyed and rebuilt from code (b), VMIDs 501–503/504–506 removed from both vzdump jobs (c). Retired v1 VMIDs 3011–3013/3021–3023 and a retired LXC removed in the same pass. |
| 2 | fleecing | ✅ **Verified 2026-07-29** on the 22:30 pbs job: finished successfully, zero ERROR/WARN lines, **zero guest I/O errors** against a baseline of 73 in 2.5 min, 24–46 MiB/s against ~10, fleece volumes created and removed per guest, `local-lvm` at 2.47 %. Caveat: decision 1(c) removed the k3s VMs from vzdump in the same 24 hours, so the *original* stall is no longer reproducible by this job — fleecing is proven to work, not proven to have been the sole cure. |
| 3 | **Forgejo off-cluster** | ✅ **Complete 2026-07-29.** Dedicated Forgejo VM on pve-1; in-cluster Deployment and Postgres retired at zero replicas in git, PVCs kept as rollback. SSO on ArgoCD and Grafana confirmed working. |
| 4 | Longhorn stays | ✅ Standing posture, no action. |
| 5 | second copy + escrow off-site | 🟡 **Half.** Second copy live on the Pi 5 and byte-verified — hardware diversity achieved. **Off-site and the escrow key are not done**, and are deliberately deferred rather than dropped (an off-site backup design exists in the gitops repository). |
| 6 | component gate | ✅ Audit done; Cilium taken from failing all three columns to passing all three. |
| 7 | churn on pre-prod first | ✅ Standing posture. |
| 8 | sweep for a lesson's shape | ✅ Standing posture. |

**Decision 1(c) was gated on decision 5 and that gate has moved, not vanished.**
The original condition was that removing k3s VMs from vzdump deletes the
lab's *only hardware-diverse* backup path. The Pi mirror supplies that
diversity, so the condition is met. It does **not** supply site diversity: one
fire still takes every copy. That is now the single largest accepted risk in the
lab, and it is accepted knowingly rather than by omission.

## Context

The lab is deliberately three things at once — a place to learn by churning and
breaking, a platform held to production standards so that the fixing *is* the
learning, and a portfolio artifact. That combination is coherent and is not up
for revision here. What this ADR addresses is that the platform's surface area
has outgrown the verification capacity of one part-time operator, and the
symptoms are now measurable rather than theoretical.

A single day (2026-07-28) surfaced defects that fall into four repeating classes:

- **Green when broken.** An Ansible run exited 0 with "no hosts matched" and did
  nothing; a dashboard app's hourly collector tick was dead for 9 hours while
  its 10-minute tick kept the app looking alive; Longhorn reported `robustness=healthy` on a
  node logging EXT4 I/O errors.
- **Written down but not applied.** `RollingUpdate` on a single RWO PVC
  deadlocks — recorded as gotcha 3 for Forgejo, never applied to Grafana, which
  has identical shape and duly deadlocked. `04-cluster-build.md` documents
  Cilium values (`ipam: kubernetes`) that the live cluster contradicts
  (`cluster-pool`).
- **Premise never checked.** The pre-prod config asserted "sandbox is on
  203.0.113.0/24 with no VLAN tag"; the host's own management address is on
  `vmbr0.200`. The VM booted perfectly and had no network.
- **Circular dependency.** Cilium's install job could not schedule because the
  node was NotReady for want of Cilium.

Underneath all four is one ratio: more moving parts than can be kept proven.
The response is not to stop building — that would defeat the point of the lab —
but to make each part cheaper to verify and to shrink the blast radius of
breaking it.

### The evidence that forced the backup decisions

The nightly `vzdump` is not a nuisance; it is the lab's largest source of
real damage:

- Backing up node-4's 80 GiB boot disk ran at **~10 MiB/s**, reaching 16 % in
  18 minutes — a projected **~2 hours** during which the guest is stalled.
- node-4 logged **73 I/O errors in 2.5 minutes** (03:55–03:58) across **six
  Longhorn volume devices**. Notably *not* on `sda` (the disk being dumped) or
  `sdb` (excluded from backup) — the damage lands on the Longhorn volumes,
  because the stalled guest starves the storage engine.
- Forgejo and its Postgres were in CrashLoopBackOff for ~2 hours; `git push`
  returned 503 throughout; Grafana later would not start on that node because a
  VolumeAttachment claimed a volume that had no mount.

This falsifies the verdict recorded on 2026-07-26 ("zero I/O errors … full
self-recovery"), which was drawn from a single observation. The `backup=0`
mitigation on `scsi1` stopped that disk being dumped; it never stopped the
stall, because `scsi0` is still dumped.

### The concentration nobody had stated

Five of six backup paths land in the **same bucket, on the same MinIO, on the
same ZFS pool, on the same machine** (`lab-backups` on TrueNAS, pool `tank`,
pve-4): etcd snapshots, Longhorn backups, Velero, the Forgejo data tarball and the
Postgres dump. Only `vzdump`/PBS has a second physical copy, via the nightly
pbs → pbs2 pull-sync onto `pve-3`.

Two consequences follow. Retargeting `vzdump` away from the k3s VMs is correct
for those VMs, but in aggregate it removes the lab's only hardware-diverse
backup path — so it must be paired with fixing the concentration. And the pool
is 4×8 TB **RAIDZ1**: it survives one disk, and at 8 TB the rebuild window is
long enough that a second failure during it is a credible way to lose
everything.

There is also a recovery-chain dependency worth stating once: reading any of
those backups requires the MinIO credentials → sealed in git → decryptable only
with the sealed-secrets master key → escrowed **only** to a directory kept
outside the repository on the operator's admin workstation. If the admin
workstation and the lab are lost together, the backups are unreadable even if the disks survive.

## Decisions

### 1. k3s node VMs are cattle. They get no image backups.

Their state lives elsewhere and is drilled: etcd snapshots (restore proven
2026-07-27 — 12,702 keys), Longhorn volume backups, Velero cluster objects, and
the Forgejo data + Postgres dumps (128/128 tables identical). A `vzdump` image
of a k3s node is the most redundant copy in the lab and the most expensive
one to take.

**Sequenced, not immediate.** Remove VMIDs 501–503 and 504–506 from both jobs
only after (a) the `cilium` role is adopted for production so prod nodes are
genuinely rebuildable from code, and (b) one full node rebuild has actually been
performed. Do not remove the safety net before demonstrating the replacement.

Guests that hold pet state — the tier VMs, OMV — keep their image backups.

### 2. Fleecing is enabled on both backup jobs. *(Applied 2026-07-28.)*

`mode snapshot` performs copy-before-write: each guest write to a
not-yet-backed-up block must first copy that block **to the backup target**.
Both targets resolve to spinning RAIDZ1 over NFS, so guest I/O was gated on the
slowest path in the lab. Fleecing diverts copy-before-write to a fast local
image (`local-lvm`, on each host's boot SSD — a different spindle from the
`pve1-data`/`pve2-data` pools holding the VM disks), decoupling guest writes from
target speed. PVE 9.1.5 supports it; both jobs previously read `fleecing 0`.

### 3. Forgejo moves off the cluster onto its own VM.

**This is the recommendation of this ADR and the most consequential decision in
it.** Forgejo now carries four roles — Git server, OCI registry, CI engine, and
(as of 2026-07-28) identity provider for ArgoCD and Grafana — as a **single
replica**, on a single RWO Longhorn volume, on one node, inside the cluster all
four roles serve.

The decisive argument is the bootstrap paradox: **rebuilding the cluster from
GitOps requires the Git repository that runs on that cluster.** The GitHub
push-mirror is a manual escape hatch, not a design.

This is the same principle as ADR 0002, which deliberately placed the DNS
resolvers outside the cluster they serve. That ADR reasoned "DNS is a harder
dependency than git", which was correct when Forgejo was only git. It is not
correct now.

Running two Forgejo replicas is explicitly **rejected** as the alternative:
Forgejo/Gitea HA requires RWX shared storage plus an external session and queue
store, is not a first-class upstream story, and would leave both replicas
sharing the cluster's fate anyway.

Relocation also removes, in one move, the Longhorn dependency for the lab's
most incident-prone stateful workload, the nightly `vzdump` interaction that
takes the Git server down, and the circular auth dependency introduced today.

**Constraints on placement:** Forgejo and its Postgres move together, or the
cluster dependency remains. The VM must be provisioned by `tofu` + `ansible`
like the k3s nodes so it is rebuildable from code and does not become a pet. It
must **not** share a physical host with the only copy of a backup it would need
to recover — which today rules out co-locating it with `pbs2` on `pve-3`.

**The migration is a restore drill.** Build the VM, restore from the existing
`forgejo-data` tarball and `pg_dump` — both already proven — then cut over NPM
and DNS, keep the in-cluster instance until verified, and decommission after.

### 4. Longhorn stays. Storage is not re-judged until the I/O starvation is gone.

Longhorn is the lab's most incident-prone component, but the majority of its
incidents trace to nightly I/O starvation rather than to Longhorn itself.
Replacing it now would be failure class 3 — treating a symptom's location as its
cause. Re-evaluate only after a month of clean backup windows.

If replacement is warranted then, the ranked alternatives are: `democratic-csi`
against the existing TrueNAS (moves replication to ZFS, deletes the in-cluster
storage plane, makes the NAS a hard dependency); Rook/Ceph (the self-hosted
industry standard and the highest learning value, but wants more RAM, CPU and
dedicated disks than three 20 GB workers have spare); then OpenEBS Mayastor or
Piraeus/LINSTOR.

Independently of that: Longhorn's `weekly-backup` gives volume data an RPO of up
to **seven days**, and `daily-snapshot` is not a second copy — snapshots live on
the same replicas. Move important volumes to daily backups.

### 5. Backups need a second copy, and the escrow key needs to leave the house.

The single-pool concentration above is accepted as **known risk, not accepted
design**. The existing top-priority item for true off-site backup stands and is now better
specified: it must cover the MinIO bucket, not only the Git repositories. The
sealed-secrets master key must have an off-site copy, because without it the
backups are unreadable.

### 6. No new standing component until the existing ones are proven.

Each existing component must have a restore proof, an absence alert, and a
documented upgrade path before another is added. This is a gate, not a freeze:
drilling a component *is* the learning exercise, so the gate is paid in the same
currency the lab exists to earn.

**Correction (2026-07-28):** an earlier draft of this ADR claimed no Longhorn
volume restore had been drilled on v2. That was wrong, and wrong in the way this
ADR is about — it reasoned from the age of the `dr-drill-*.sh` family instead of
reading the record. `scripts/dr-drill-longhorn-volume.sh` is v2-native
(`CTX=homelab-v2`) and **passed on 2026-07-27** (recorded in the gitops
repository's drill matrix): it restored
the newest Forgejo Postgres PVC backup into a scratch Longhorn volume, mounted it
read-only and asserted real PGDATA — `PG_VERSION=15`, `global/pg_control`
present, 4 databases, 76 MB — then tore the volume down. All five restore paths
are proven.

What *is* outstanding is narrower and still real: the drill proves the **path**,
on one volume, on demand. It is not scheduled, and the other volumes' backups
remain unread. Coupled with `weekly-backup` giving an RPO of up to seven days,
the honest statement is that volume data is recoverable to a proven procedure,
not that every volume's latest backup is known-good.

### 7. Churn happens on pre-prod first.

`preprod-1` (`203.0.113.20`, on the sandbox host pve-5) exists as of 2026-07-27 and
is isolated from the cluster VLAN by control, not assumption. Platform-component
upgrades, chart bumps and policy flips go there before production. This is what
makes decision 6 affordable and keeps the lab breakable without breaking the
tooling used to fix it.

### 8. When a lesson is recorded, sweep for its shape.

The lab diagnoses and documents well and does not generalise. Gotcha 3 was
written correctly for Forgejo and Grafana carried the identical bug untouched;
one `grep` for Deployments with RWO PVCs would have found it in seconds.
Incident closure gains one question — *where else does this shape exist?* —
answered with an actual search, with the result recorded.

## Consequences

- **Accepted cost:** relocating Forgejo means it is no longer GitOps-managed.
  This is consistent with how OPNsense, TrueNAS and the DNS resolvers are
  already treated — infrastructure, not workload — and is the price of removing
  the bootstrap paradox.
- **Accepted cost:** dropping k3s image backups means node recovery is a rebuild
  (minutes to tens of minutes from code) rather than a restore. This is only
  acceptable once decision 1's preconditions are met.
- **Accepted cost:** fleecing consumes transient space on `local-lvm` during
  each backup. Verified headroom: 151 GB free on pve-1, 365 GB on pve-3.
- **Deliberately not decided here:** whether to consolidate the three nightly
  backup windows (02:30, 04:00, 22:30 — the 04:00 job was moved from 23:00 by
  the owner to stop it interrupting late-night work). Note the 04:00 job now
  overlaps the tail of a slow 02:30 run. Revisit after measuring a fleeced run.
- **Deliberately not decided here:** RAIDZ1 → RAIDZ2 on `tank`, which cannot be
  done in place and needs its own ADR.

## Revisit triggers

- A fleeced backup still stalls a guest → escalate to `iothread=1`, which
  additionally requires switching `scsihw` to `virtio-scsi-single` and a rolling
  reboot (the previously recorded "next lever" of `iothread` alone was wrong —
  node-4 is `virtio-scsi-pci`, where the flag has no effect).
- Longhorn incidents continue after a month of clean backup windows → re-open
  decision 4.
- A second operator, or a second consumer of the cluster → re-open decision 3's
  rejection of HA Forgejo, and the single-IdP posture generally.
- Forgejo's outage window stops being tolerable before relocation lands → bring
  decision 3 forward rather than adding more roles to it.
