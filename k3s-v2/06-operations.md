# 06 — Operations (Day-2 Workflows)

> **Status (2026-09-25):** current for day-2 procedures; written for the 2026-07 build — [AS-BUILT.md](AS-BUILT.md) records what was running at its July 2026 snapshot ([README](README.md)).

Standalone procedures for running the cluster day to day. Each workflow is complete: prerequisites, steps, verification, rollback.
Diagnostics cheatsheet and gotchas at the bottom.

Context assumed: `kubectl config use-context homelab-v2`, ArgoCD CLI
logged in (`argocd login argocd.apps.example.com`). Addresses are the as-built
ones: API VIP `192.0.2.10`, ingress-nginx LoadBalancer `192.0.2.200`.

---

## W1 — Deploy a New App

1. Create the app dir in the gitops repository:

   ```
   clusters/homelab/apps/<app>/
   ├── application.yaml     # ArgoCD Application (or Helm values reference)
   ├── deployment.yaml      # namespace, PSS labels, resources, probes
   ├── service.yaml
   ├── ingress.yaml         # host: <app>.lab.example.com, class nginx
   └── pvc.yaml             # storageClassName: longhorn (only if stateful)
   ```

   Checklist per manifest (repo conventions): namespace set, image tag
   pinned, resources requests+limits set, liveness/readiness probes,
   labels `app.kubernetes.io/name` + `app.kubernetes.io/part-of: homelab`.
2. Secrets, if any: workflow **W2** first; reference the unsealed name.
3. Commit + push → ArgoCD picks it up (or `argocd app sync <app>` to skip
   the poll). Watch: `argocd app get <app>` until Synced/Healthy.
4. NPM proxy host: `<app>.lab.example.com` → `http://192.0.2.200:80`,
   websockets on, wildcard cert id 2.
5. Verify: `curl -I https://<app>.lab.example.com` → 200/302 from the LAN.
6. Bookkeeping: add the app to the service inventory and the Homepage
   `services.yaml`; add an Uptime Kuma monitor if the app matters.

**Rollback:** `git revert` the commit; ArgoCD converges back. Never fix
forward with `kubectl edit` — it will be overwritten by self-heal.

## W2 — Add or Rotate a Secret

```bash
kubectl create secret generic <name> -n <ns> \
  --from-literal=key=<value> --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --format yaml \
  > <app>/sealedsecret-<name>.yaml
git add … && git commit && git push
```

- The plaintext never touches disk or git; the SealedSecret is safe to commit.
- Rotate = rerun with the new value, commit; restart consumers
  (`kubectl rollout restart deploy/<app> -n <ns>`).
- **If the controller key is lost** (cluster rebuilt without restoring the
  escrowed key): every SealedSecret is unreadable — restore the key from
  escrow first ([08 § R4](08-backup-dr.md#r4--full-cluster-rebuild-from-git)).

## W3 — Upgrade Kubernetes (k3s)

Via system-upgrade-controller Plans (in git under `infra/system-upgrade/`):

1. Read the k3s release notes for the target version; check Longhorn/Cilium
   compatibility matrices.
2. Edit the Plan's `version:` field (e.g. `v1.34.5+k3s1`) in git; commit.
3. Controller drains + upgrades **servers one at a time** (server Plan,
   concurrency 1), then workers (agent Plan). Watch:

   ```bash
   kubectl get plans -n system-upgrade
   kubectl get nodes -w        # versions roll one by one
   ```

4. After: `kubectl get nodes` all Ready on the new version;
   `cilium status`; spot-check one app.
5. Update the pin in [03 § version pins](03-provisioning.md#version-pins).

**Rollback:** k3s doesn't downgrade in place. Recovery = etcd snapshot
restore ([08 § R5](08-backup-dr.md#r5--etcd-quorum-loss)) — which is why
servers upgrade one at a time and you stop at the first sign of trouble.

## W4 — Upgrade a Platform Component (Helm chart)

1. Diff upstream: `helm repo update && helm search repo <chart> --versions | head`;
   read the chart changelog for breaking values changes.
2. Bump `targetRevision` in the component's ArgoCD Application in git.
3. `argocd app diff <app>` — review rendered changes **before** sync.
4. Sync; watch health. Longhorn and Cilium deserve a maintenance window
   and a pre-upgrade Velero backup (`velero backup create pre-<x>-upgrade`).
5. Update the version-pin table.

## W5 — Drain a Node / Host Maintenance

For one VM:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=5m

# ── MANDATORY GATE: the drain is NOT finished when the command returns. ──
# The node must hold zero Longhorn devices and zero CSI global mounts.
ssh kube@<node-ip> 'ls /dev/longhorn/ 2>/dev/null; mount | grep -c driver.longhorn.io'
# Expected: nothing listed, and "0".
# Anything else = volumes are still staged on this node. Do NOT reboot or
# uncordon yet — clear them first (see W5b), or you leave behind an ext4 mount
# on a device that is about to disappear, and every pod that later lands here
# gets input/output error on that volume forever.

# … do the maintenance (reboot, resize, config change) …
kubectl uncordon <node>
kubectl get pods -A -o wide | grep <node>    # workloads returning
kubectl -n longhorn-system get volumes.longhorn.io   # all attached + healthy
```

For a whole physical host (e.g. Proxmox updates on pve-1): drain node-4,
then node-1 (no drain needed — tainted, but check it isn't the etcd
leader mid-upgrade: fine either way, quorum holds), `qm shutdown` both,
patch/reboot host, start VMs, uncordon. One host at a time, always.

Longhorn note: a drained worker's replicas go degraded; they rebuild on
return. Don't drain a second worker until Longhorn shows all volumes
healthy (`https://longhorn.apps.example.com` → Volumes).

## W5b — Recover an Orphaned CSI Mount (pod stuck on `input/output error`)

**Symptom:** a pod crashlooping with a huge restart count and
`input/output error` on every path under its PVC mount. Container restarts never
help — the broken mount is at node/pod scope, so the kubelet keeps restarting the
container into the same dead filesystem.

**Diagnose — on the node the pod is scheduled on:**

```bash
ssh kube@<node-ip> 'ls -l /dev/longhorn/; mount | grep <pv-name>'
```

The fault is confirmed when the `mount` output shows `/dev/longhorn/<pv>` mounted
but `ls /dev/longhorn/` does **not** list that device.

> ⚠️ **`ls <mountpoint>` is not a liveness test** — a cached directory listing
> succeeds on a dead filesystem, and did so for Grafana on 2026-07-26 while Grafana
> was failing with `input/output error`. Compare the device list against `mount`,
> or open a file; don't trust a successful `ls`.

Cross-check the two views that are disagreeing:

```bash
kubectl -n longhorn-system get volumes.longhorn.io   # says: detached, robustness unknown
kubectl get volumeattachment | grep <pv-name>        # says: attached=true  ← the deadlock
```

Longhorn will not attach (nothing asked it to); the CSI attacher will not ask
(it believes it already succeeded). Nothing self-heals. **Fix it in this order:**

```bash
# 1. Stop the workload so kubelet releases the pod-level mount
kubectl -n <ns> scale deploy/<name> --replicas=0        # or sts/, or delete the pod
#    (first: turn OFF ArgoCD automated sync on the owning app, or selfHeal
#     scales it straight back up)

# 2. CHECK BEFORE FORCING. Once the last pod reference is gone, kubelet usually
#    unmounts on its own and the stale VolumeAttachment deletes itself — that is
#    what happened on 2026-07-26, and steps 2–3 were unnecessary.
ssh kube@<node-ip> 'mount | grep <pv-name>'   # empty? skip to step 4
kubectl get volumeattachment | grep <pv-name> # gone? skip to step 4

# 2b. FALLBACK, only if they did not release — clear the mounts on the node
#     (pod mount first, then globalmount)
ssh kube@<node-ip> 'mount | grep <pv-name>'             # re-derive the exact paths
ssh kube@<node-ip> 'sudo umount -f /var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount'
ssh kube@<node-ip> 'sudo umount -f /var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/<hash>/globalmount'
# `umount -l` if -f reports "target is busy"
ssh kube@<node-ip> 'mount | grep -c driver.longhorn.io' # confirm it is gone

# 3. Delete the stale VolumeAttachment so the attacher re-drives the attach.
#    ONLY after step 2 — deleting it with a mount still present wedges kubelet.
kubectl delete volumeattachment <csi-…>

# 4. Restart the workload and verify
kubectl -n <ns> scale deploy/<name> --replicas=1
ssh kube@<node-ip> 'ls -l /dev/longhorn/'               # device node is back
kubectl -n longhorn-system get volumes.longhorn.io      # attached / healthy
kubectl -n longhorn-system get replicas.longhorn.io | grep <pv>   # rebuilding to 3/3
```

A node **reboot** also clears every orphaned mount and is the blunt alternative
when several volumes on one node are affected — but it only helps the node that
actually holds the orphan. Check `mount | grep driver.longhorn.io` on **all three**
workers before deciding which node to touch; the broken pod and the broken node
are not always the same.

Prevention is the W5 gate plus Longhorn's `nodeDrainPolicy:
block-for-eviction-if-contains-last-replica` (set in `values/longhorn-values.yaml`
in the gitops repository, which also holds the full 2026-07-25 incident write-up).

## W6 — Replace a Dead Node

> ⚠️ **For a WORKER, use
> [`docs/runbooks/node-rebuild.md`](../docs/runbooks/node-rebuild.md) instead
> (added 2026-07-29).** That runbook is the procedure as actually executed
> against production node-4 on 2026-07-28, including the four defects that sat
> between "the code exists" and "a rebuilt node works" — and the acceptance step
> this section is missing, which is that a Longhorn volume must *attach* on the
> rebuilt node, not merely hold replicas. A node can pass every check below and
> be unable to run any stateful workload.
>
> The sketch below is design-era and predates the Ansible chain: `k3s-node.yml`
> now writes the k3s config and provisions the Longhorn disk, so step 3's
> "put the right config.yaml on it by hand" is superseded. Kept for the
> control-plane case, which has **not** been rebuilt from code and which the
> worker runbook explicitly does not cover.

**Scope: control-plane nodes.** Total time target: ~30 min. This section used
to claim it "works for any of the six"; it does not, and that sentence is the
reason the worker case went unwritten for so long — a sketch that claims full
coverage is never revised. Workers go to
[`node-rebuild.md`](../docs/runbooks/node-rebuild.md) per the box above.

```bash
# 1. Remove the corpse from the cluster
kubectl delete node <name>
# (if a control node: also check etcd member list is 2/3 healthy —
#  k3s removes the member automatically with the node delete)

# 2. Recreate the VM (from repo root)
cd tofu/k3s
tofu destroy -target='proxmox_virtual_environment_vm.k3s["<name>"]'
tofu apply   -target='proxmox_virtual_environment_vm.k3s["<name>"]'

# 3. Baseline + rejoin
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k3s-v2-baseline.yml --limit <name>
# put the right config.yaml on it (04-cluster-build.md §4 or §5), then the
# pinned install command. It joins via the VIP.

# 4. Verify
kubectl get nodes            # back, Ready, right labels/taints
# worker: Longhorn UI → node visible, replicas rebuilding
# control: ssh to another control → sudo k3s etcd-snapshot ls (3 members healthy)
```

## W7 — Storage Operations

- **Expand a PVC:** edit `spec.resources.requests.storage` in git
  (Longhorn classes have `allowVolumeExpansion`), sync, watch
  `kubectl get pvc -n <ns> -w`.
- **Degraded volume:** Longhorn UI → volume → check which replica died.
  Node back soon → wait for rebuild. Node gone → W6, rebuild is automatic.
- **Restore a volume/file:** [08 § R1/R2](08-backup-dr.md).
- **Move a workload off `nfs-bulk`:** new PVC on `longhorn`, scale app
  down, `rsync` via a utility pod, repoint claim in git.

## W8 — Certificate Troubleshooting

```bash
kubectl get certificates -A                      # READY=False → describe it
kubectl describe certificaterequest -n <ns>      # ACME order status
kubectl logs -n cert-manager deploy/cert-manager | tail -50
```

Usual suspects: Cloudflare token expired/rotated (reseal via W2), DNS-01
propagation timeout (retry is automatic), rate limits (staging issuer
exists for experiments). Renewals are automatic at 2/3 lifetime; the
`CertExpiringSoon` alert firing means renewal has been failing for weeks —
read the logs, don't just re-issue.

## W9 — When the Cluster Feels Broken (triage order)

1. **API up?** `kubectl get --raw /readyz` — if it hangs: is `192.0.2.10`
   pingable? If not, kube-vip: check any control VM is running at all;
   ssh in, `kubectl` locally via `sudo k3s kubectl`.
2. **Nodes?** `kubectl get nodes` — NotReady nodes → `describe` for the
   condition (Memory/Disk/PID pressure, network).
3. **etcd?** more than one control down = quorum lost = read-only API →
   [08 § R5](08-backup-dr.md#r5--etcd-quorum-loss).
4. **Network?** `cilium status` in any cilium pod; pod-to-pod:
   `cilium connectivity test --test pod-to-pod`. Flow-level:
   `hubble observe --namespace <ns> --last 100` (drops show the verdict
   and the policy that caused them).
5. **Storage?** Longhorn UI first; a stuck pod with a volume error usually
   traces to iscsid on the node (`systemctl status iscsid`).
6. **GitOps drift?** `argocd app list | grep -v Synced` — something
   OutOfSync + self-heal off explains "my change vanished."

## Diagnostics Cheatsheet

```bash
# Cluster vitals
kubectl get nodes -o wide && kubectl top nodes
kubectl get pods -A --field-selector=status.phase!=Running | grep -v Completed
kubectl get events -A --sort-by=.lastTimestamp | tail -20

# etcd (on any control node)
sudo k3s etcd-snapshot ls
sudo journalctl -u k3s --since -15m | grep -iE 'etcd|leader|election'

# Cilium / network
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
hubble observe --verdict DROPPED --last 50
kubectl get ciliuml2announcementpolicies,ciliumloadbalancerippools

# Longhorn
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io

# ArgoCD
argocd app list
argocd app diff <app>

# Ingress path (LAN → app)
curl -sI https://<app>.lab.example.com                        # via NPM
curl -sI -H "Host: <app>.lab.example.com" http://192.0.2.200   # direct to LB
```

## Gotchas

- **Never point kubeconfig at `k3s.lab.example.com`** (or any
  `*.apps.example.com` name): split DNS wildcard-redirects the whole zone to
  NPM (198.51.100.40), and OPNsense Unbound **cannot** carve out per-host
  overrides under a redirect zone (it fails to start, causing a LAN-wide DNS
  outage). The API is the VIP IP: `192.0.2.10`.
- **pve-2 has no interface on the main LAN** — its Proxmox UI is at
  `https://192.0.2.5:8006`.
- **Old-cluster VMs may be stopped, never deleted** before Phase 8; Forgejo's
  survivor set had to keep running until it migrated on 2026-07-17.
- **Don't `kubectl apply` fixes to ArgoCD-owned resources** — self-heal
  reverts them; you'll chase a ghost. Fix in git.
- **Control planes are tainted** — a pod stuck Pending with "untolerated
  taint control-plane" is scheduled correctly, not broken.
- **Two workers down = degraded Longhorn everywhere** (3 replicas, 3
  workers). Plan maintenance one host at a time.
- **A pod at hundreds of restarts with `input/output error` is not flapping —
  its mount is dead.** Restarting the container, the deployment, or the pod
  cannot fix it; the mount is established at pod admission and never
  re-evaluated. Go to the node and compare `ls /dev/longhorn/` against
  `mount | grep driver.longhorn.io` → W5b. Note that "Longhorn says healthy"
  *and* "Longhorn says detached" are both compatible with a pod getting EIO
  (2026-07-22 and 2026-07-25 respectively) — the node is the authority.
- **node-6 is the light node** — if something heavy must not land there,
  give it a nodeAffinity away from `node-role/tier=light` rather than
  taints (keep taints for control planes only).
