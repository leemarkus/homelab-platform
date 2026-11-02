# Rebuilding a k3s worker from code

**Status:** Proven on **node-4, production, 2026-07-28.** Destroyed and rebuilt
end to end; cluster stayed in service throughout; all 8 Longhorn volumes
returned to 3/3 replicas. This is ADR 0011 decision 1's second precondition.

**It did not work first time.** Four defects sat between "the code exists" and
"a rebuilt node actually works", and none of them were visible by reading. They
are written up below because the *shapes* recur, and because a rebuild proof
that only recorded the happy path would have been worth very little.

## Before you start

- The cluster runs at **2 of 3 replicas for every volume** for the duration.
  Safe, but do not start this with another node degraded, and do not leave it
  overnight.
- Not during a backup window (02:30 / 04:00).
- `tofu plan` **must be clean first**. See finding 1 — this is not a formality.

## Procedure

```bash
# 0. Verify the code matches reality. A non-empty plan here is a stop.
cd tofu/k3s && tofu plan            # expect "without changing any real infrastructure"

# 1. Evacuate.
kubectl cordon node-4
kubectl drain node-4 --ignore-daemonsets --delete-emptydir-data --force --timeout=600s

# 2. Remove it from the cluster AND from Longhorn.
#    The second half is easy to forget and costs ~40 minutes — see finding 3.
kubectl delete node node-4
kubectl -n longhorn-system delete nodes.longhorn.io node-4

# 3. Replace the VM. (Destructive; run it deliberately.)
tofu apply -replace='proxmox_virtual_environment_vm.k3s["node-4"]'

# 4. Wait for cloud-init, then rebuild. The join token goes in a 0600 file and
#    is read by lookup() — never on the command line, where `ps` can see it.
ssh-keygen -R 192.0.2.21                     # the VM has a new host key
ssh kube@192.0.2.21 'cloud-init status --wait'
cd ../../ansible
ansible-playbook playbooks/k3s-node.yml --limit node-4 \
  -e "k3s_token={{ lookup('file', '/path/to/token') }}"
```

## Acceptance — all of it, not the first two

1. `kubectl get nodes` → node-4 Ready, correct `topology.kubernetes.io/zone`.
2. Cilium agent pod on node-4, `ready=true`. **Arrives on its own** — the
   DaemonSet schedules it; nothing node-side installs the CNI on a worker.
3. `findmnt /var/lib/longhorn` → `/dev/sdb`, ext4.
4. `ls /var/lib/longhorn/engine-binaries/` → non-empty **on the mounted disk**.
5. Longhorn disk `Ready=True Schedulable=True` with a real `storageMaximum`.
6. All volumes back to `robustness=healthy`, replicas 8/8/8 across the workers.
7. A **new** pod scheduled onto node-4 runs and resolves DNS.
8. 🔴 **A Longhorn volume ATTACHES on the rebuilt node and data reads back
   through it.** Create a 1 Gi PVC, pin a pod to the node, write a file, read it.
   This step was missing from the first rebuild and cost a 35-minute Forgejo
   outage the same night (an aborted Forgejo cutover on 2026-07-29).

   **Why steps 5–6 do not cover it.** Longhorn runs two different things per
   node: *replica* processes, which store data, and an *engine* process, which
   attaches a volume and serves it to a workload. Replicas rebuilding onto the
   node proves the first and says nothing about the second. The engine needs an
   external binary at `/var/lib/longhorn/engine-binaries/…`; replicas do not.
   So a node whose instance-manager cannot see that binary will pass every check
   above, hold replicas perfectly, and be unable to run any stateful workload —
   silently, until the scheduler happens to place one there.

   **Root cause when it happens:** the `instance-manager` pod was started before
   `/var/lib/longhorn` was mounted, so its bind mount still points at the
   pre-mount directory on the root filesystem. Restarting `engine-image` alone
   does not fix it — that writes the binary to the *mounted* disk, which the
   stale instance-manager cannot see. **Delete the instance-manager pod on that
   node** (it must be uncordoned, or nothing recreates it) and it comes back with
   the correct view. The ordering fix in the role prevents this for future
   rebuilds; this is the recovery for a node already in the state.

Steps 1 and 2 passed within minutes on the real run while 3–6 were all broken.
A node can be Ready, running the CNI and scheduling pods, and still be useless
for storage — with nothing reporting a problem.

## What went wrong, and why each was invisible

### 1. `tofu plan` wanted to undo two deliberate fixes

Before any destruction, the plan showed 4 VMs changing:

- **node-3 + node-6:** disks `mx500 → local-lvm`, `qcow2 → raw`, `discard on
  → ignore`, `ssd true → false` — reverting the 2026-07-20 migration off pve-3's
  BC711 boot NVMe, as a live disk conversion on an etcd member.
- **all three workers:** data disk `backup false → true` — re-enabling the
  vzdump of the Longhorn disks, the thing that produced 73 guest I/O errors in
  2.5 minutes that same morning.

Both had been applied by hand and never written back. **Any** apply would have
tripped them, for any reason, at any time. Fixed by adding `disk_datastore`,
`disk_format`, `disk_discard`, `disk_ssd` and `data_disk_backup` to the node
map. `disk_datastore` has to be separate from `datastore` because on pve-3 they
genuinely differ — the guests' disks moved to the mx500 and the cloud-init
drive did not, so one field could not describe the node.

### 2. Nothing ever provisioned the Longhorn disk

`nodes.tf` said "ansible mounts it at /var/lib/longhorn". Ansible did not. The
original workers were formatted by hand in the 2026-07-04 build; the role had
no disk tasks at all.

The rebuilt node came up **Ready, running Cilium, scheduling pods**, with a raw
unformatted 120 GB disk and no storage. Longhorn simply never placed a replica
there. The cluster would have run at 2/3 replicas indefinitely, degraded but
serving, with no event and no alert — and you would find out during the next
node failure.

Now in the role, guarded: `mkfs` runs **only** on a genuinely blank device,
because an unguarded re-run against the fleet would destroy every replica on
all three workers in a single play, and 3-replica redundancy does not save you
when the play hits all three. Dry-run against node-5 and node-6 confirms it
skips.

### 3. The engine binary was shadowed by the mount

The symptom was 8 volumes stuck degraded and every replica erroring with:

```
exec: "/host/var/lib/longhorn/engine-binaries/…/longhorn": no such file or directory
```

The file was there the whole time — **underneath the mount point.** Longhorn's
`engine-image` DaemonSet copies the engine binary to
`/var/lib/longhorn/engine-binaries/` on the host. The node joined the cluster
before the disk was mounted, so the copy landed on the root filesystem, and
mounting `/dev/sdb` over the top hid it. One `umount` proved it.

Two fixes, both needed:

- **In the role:** disk provisioning now runs **before** the k3s config and
  install, so the mount exists before the node ever joins and before any
  Longhorn DaemonSet lands. Ordering, not tidiness.
- **For recovery on a node already in this state:** delete the `engine-image-*`
  pod on that node so it re-copies onto the mounted filesystem, then delete the
  failed replicas.

### 4. Longhorn kept the destroyed disk in the node CR

`nodes.longhorn.io/node-4` survived the node deletion carrying the old disk,
which then read `Ready=False, reason=DiskFilesystemChanged`. Removing it is not
a simple patch — Longhorn refuses while replicas reference it, so it goes:
disable scheduling on the stale disk → delete its replicas → then remove the
entry. Registering a fresh `default-disk` for the same path works immediately
and can be done first.

**Prevention, now in the procedure above:** delete `nodes.longhorn.io/<node>`
at the same time as `kubectl delete node`. That skips this entire class.

Also worth knowing: Longhorn stops retrying a replica rebuild after
`rebuildRetryCount: 5`. Replicas that burned their retries while the disk was
broken stay dead **after** the disk is fixed, and must be deleted before
anything rebuilds. Watching the volume list and concluding "it's just slow" is
wrong; check the retry count.

### 5. (Pre-existing) the playbook could never be dry-run

`k3s --version` is a `command`, which check mode skips, leaving
`stdout_lines` empty — so the next task died on `stdout_lines[0]`. Any
`--check` run against a node with k3s installed failed. Found while dry-running
the new mkfs guard against the two workers holding live replicas, which is
exactly when a dry run matters most. Both that task and the new `lsblk` read
now carry `check_mode: false`.

## Not yet proven

- A **control-plane** rebuild. It is a different risk: etcd member removal and
  rejoin, `server` rather than `agent`, **and a different CNI story.** Since the
  2026-07-28 adoption, `cilium_manage: true` is set on `k3s_v2_control` (and on
  `k3s_preprod`), so on a control plane `roles/cilium` writes the HelmChart
  manifest into `/var/lib/rancher/k3s/server/manifests/` rather than the agent
  simply picking up a DaemonSet that is already there. That is deliberate — the
  manifest goes on **all three** control planes precisely so rebuilding one does
  not silently end code ownership of the CNI (see
  [`ansible/inventory/group_vars/k3s_v2_control.yml`](../../ansible/inventory/group_vars/k3s_v2_control.yml))
  — but it means acceptance step 2 above is *not* the check to run on a
  control node. Do not assume this
  procedure covers it.
- A rebuild with the fixed role **from scratch** — node-4's disk was mounted
  after the fact during the incident, so the corrected ordering has not itself
  been exercised end to end. The next rebuild is the real test of finding 3.
