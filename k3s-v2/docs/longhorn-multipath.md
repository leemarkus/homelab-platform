# Longhorn multipath: keep multipathd off Longhorn volumes

## Decision and scope

Use a device blacklist with **vendor `^IET$` AND product `^VIRTUAL-DISK$`**.
The vendor/product pair identifies the intended Longhorn iSCSI devices in
these workers; it is not a globally unique Longhorn identifier. The inventory
(`ansible/inventory/hosts.yml`, created from `hosts.example.yml`),
`group_vars/k3s_v2_worker.yml`, and all three
worker host vars declare no SAN, multipath storage or iSCSI boot.
`tofu/k3s/nodes.tf` provisions VM boot/data disks on `scsi0`/`scsi1`.
The representative fixtures have QEMU OS disk `sda` and replica disk `sdb`:
blanket `sd*` blacklisting would also exclude both. Matching identity keeps
them out of this blacklist even if Linux renames the disks. Reassess this
rule before introducing other IET targets, especially any IET boot disk.
This rule is valid only for Longhorn’s v1 (tgt/iSCSI) engine. If the v2 data
engine is enabled, volumes arrive as NVMe-oF and this rule must be reassessed.

This implements the blacklist approach from Longhorn's knowledge-base article
on the known multipath conflict; masking the entire service is unnecessary
when the affected device class can be selected. The KB's broad
`devnode "^sd[a-z0-9]+"` example is deliberately not used.

The `k3s_node` role renders `templates/multipath.conf.j2` into a marked block
in `/etc/multipath.conf` using `blockinfile`, preserving other settings and
saving a timestamped backup on changes. Its handler reloads only a running
`multipathd.service`, only after a change. An absent/stopped service is left
alone; the persistent file protects a later start. No package is installed.
A handler flush applies the policy before k3s can attach volumes on rebuild.
Both `k3s-node.yml` and the worker play in `k3s-v2-baseline.yml` invoke the same
tasks. `k3s_longhorn_multipath_manage` defaults to `false` and is enabled in
`k3s_v2_worker` (node-4–6) and `k3s_preprod` (preprod-1, one replica) group vars.
Production control planes remain excluded: they are tainted and run no Longhorn.

## Apply — the operator runs these, one node at a time

From the repo root, start with preprod-1. After verification, repeat in order
for node-5 (the incident node), node-4, then node-6.

1. Inspect actual storage identity and existing policy on the selected node:

   ```sh
   ssh kube@203.0.113.20
   lsblk -o NAME,TYPE,VENDOR,MODEL,SIZE,TRAN
   findmnt -no SOURCE /
   sudo multipath -ll
   sudo multipath -t
   exit
   ```

   Confirm the OS/local replica disks are not `IET,VIRTUAL-DISK`, and that
   only Longhorn volumes have that pair. Resolve unexpected SAN/boot devices
   before proceeding. Inspect effective `blacklist_exceptions` (including
   `/etc/multipath/conf.d` policy): an explicit vendor/product exception can
   override this blacklist. If multipath tools are absent, there is no daemon
   to claim devices; the config will still be installed for future starts.

2. Check mode first, limited to one node, then apply the identical scope:

   ```sh
   cd ansible
   ansible-playbook -i inventory/hosts.yml playbooks/k3s-node.yml \
     --tags longhorn-multipath --check --diff --limit preprod-1
   ansible-playbook -i inventory/hosts.yml playbooks/k3s-node.yml \
     --tags longhorn-multipath --diff --limit preprod-1
   ```

   General form: `--check --diff --limit <one node>`. Review the marked
   block in the diff. The tag skips k3s configuration/install and token checks;
   it needs no cluster secrets. Both commands also work with
   `playbooks/k3s-v2-baseline.yml`. Use the tag for this repair: an unrestricted
   provisioning run can make unrelated changes, including version changes.

3. Verify the effective policy and maps on that node:

   ```sh
   ssh kube@203.0.113.20
   sudo cat /etc/multipath.conf
   sudo multipath -t
   sudo multipath -ll
   sudo systemctl is-active multipathd.service
   exit
   ```

   Expect the exact vendor/product blacklist in effective config and **no
   `IET,VIRTUAL-DISK` maps** in `multipath -ll` (entirely empty if there is no
   legitimate multipath storage). A stopped/absent daemon is acceptable.
   A reload does not guarantee an existing busy map disappears. If one remains,
   identify its WWID/path and confirm it is a Longhorn volume, then detach that
   volume using the normal workload maintenance procedure. Before flushing,
   substitute the verified current alias in both checks:

   ```sh
   sudo dmsetup info <alias> | grep 'Open count'
   lsblk /dev/mapper/<alias>
   ```

   The open count must show **0**, and `lsblk` must show **no mountpoint**
   (including on children). Stop if either check fails. Only then run
   `sudo multipath -f <alias>`. Never flush all maps or assume the incident’s
   alias is still current. Optionally run `sudo multipath -W` to remove stale
   WWIDs after reviewing the remaining maps: remembered WWIDs could reclaim
   devices on rollback. Reattach the volume
   and repeat `sudo multipath -ll`; confirm its workload mounts successfully.

4. From `ansible/`, rerun the tagged apply; the recap must show `changed=0`:

   ```sh
   ansible-playbook -i inventory/hosts.yml playbooks/k3s-node.yml \
     --tags longhorn-multipath --diff --limit preprod-1
   ```

   Repeat steps 1–4 in order for node-5 (`192.0.2.22`), node-4
   (`192.0.2.21`), and node-6 (`192.0.2.23`),
   substituting each host/IP. A worker with no attached Longhorn volumes still
   receives the persistent blacklist. Check again after its next attachment.

## Rollback

From `ansible/`, remove only the managed block and reload an active daemon:

```sh
ansible-playbook -i inventory/hosts.yml playbooks/k3s-node.yml \
  --tags longhorn-multipath --check --diff --limit preprod-1 \
  -e k3s_longhorn_multipath_state=absent
ansible-playbook -i inventory/hosts.yml playbooks/k3s-node.yml \
  --tags longhorn-multipath --diff --limit preprod-1 \
  -e k3s_longhorn_multipath_state=absent
ssh kube@203.0.113.20 'sudo cat /etc/multipath.conf; sudo multipath -t; sudo multipath -ll'
```

Repeat for each node where applied. Existing policy remains; a file created
by this fix can remain empty. Rollback permits multipathd to claim Longhorn
again. To keep the rollback across future provisioning, set
`k3s_longhorn_multipath_state: absent` in
`ansible/inventory/group_vars/k3s_v2_worker.yml` and
`ansible/inventory/group_vars/k3s_preprod.yml` before those runs. Remove that
override (or set `present`) and repeat apply to reinstate the fix.

## Offline check

```sh
python3 scripts/test-longhorn-multipath.py
```

Fixtures are synthetic `lsblk`/`multipath -ll` outputs, including `sd*` OS
and local data disks, and an ordinary-disk-only worker with empty map output.
The test reads the actual template regexes and verifies Longhorn matches,
OS/data-disk exclusion, exact matching and independence from device names.
It proves selection, not live daemon behavior; the operator checks above
remain required.
