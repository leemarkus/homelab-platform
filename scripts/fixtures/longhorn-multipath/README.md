# storage fixtures

Synthetic, representative Ubuntu/Proxmox worker output, not live captures.
Commands: `lsblk -o NAME,TYPE,VENDOR,MODEL,SIZE,TRAN` and `multipath -ll`.
`worker-longhorn` represents the failure before the fix: two Longhorn iSCSI
volumes claimed by multipathd. WWIDs are invented. `worker-ordinary` represents
a worker with no attached volumes; its multipath output is deliberately empty.
In both cases `sda` (including the root partition `sda1`) is the OS disk;
`sdb` is the local Longhorn replica disk, not an iSCSI volume. Neither may match.
Virtual SCSI disks can have an empty TRAN column.

Run `python3 scripts/test-longhorn-multipath.py` from the repository root.
The test reads the deployed template's regexes and checks both identities
must match, OS/data-disk exclusion, rename independence and near misses.
It does not substitute for checking real device identities/effective config
on a worker; see `k3s-v2/docs/longhorn-multipath.md`.

These synthetic fixtures prove consistency, not real device identity. The
runbook’s live identity inspection is the real check.
