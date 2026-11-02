# 07 — Testing Strategy

> **Status (2026-09-25):** design intent, written for the 2026-07 build — [AS-BUILT.md](AS-BUILT.md) is authoritative for what is running ([README](README.md)).

Three tiers: **phase gates** (prove each build phase before moving on),
**continuous validation** (catch rot), and **chaos drills** (prove the HA
claims on a schedule, not just once). A test that isn't logged didn't
happen — record everything in the [drill log](#drill-log).

Addresses below: API VIP `192.0.2.10`, ingress-nginx `192.0.2.200`.

## Phase Gates

Every build phase ends in "Done when" criteria. Summary matrix:

| Phase | Gate (abridged) | Proof artifact |
|---|---|---|
| 0 | The cluster VLAN reaches pve-3; old-VM stop list written; MinIO/NFS reachable from the cluster VLAN | checklist in [03](03-provisioning.md#prerequisites-checklist-phase-0) |
| 1 | destroy → apply → baseline rebuilds any VM in ~15 min | timed run, noted in drill log |
| 2 | 6 nodes Ready; `cilium connectivity test` passes; **pve-2 hard-off drill** passes | drill log entry |
| 3 | `https://whoami.apps.example.com` end-to-end with valid TLS | curl output |
| 4 | root app Synced; hand-deleted Deployment self-heals | argocd app get |
| 5 | **PVC backup → delete → restore → data diff clean** | drill log entry |
| 6 | metrics+logs on the external Grafana; NodeDown alert < 5 min | screenshot/alert history |
| 7 | old cluster serves nothing; 1-week soak green | NPM upstream audit |
| 8 | default-deny in place; old VMs destroyed; docs updated | updated docs in this folder |

## Continuous Validation

### cluster-health.sh

Lives in `scripts/cluster-health.sh` once the cluster exists (reference
copy below). Run manually before/after any change, and weekly via cron on
the admin workstation or Semaphore on the monitoring VM.

```bash
#!/usr/bin/env bash
# cluster-health.sh — k3s v2 validation suite. Exit 0 = all green.
set -uo pipefail
FAIL=0
ok()   { printf ' ✓ %s\n' "$1"; }
bad()  { printf ' ✗ %s\n' "$1"; FAIL=1; }

kubectl config use-context homelab-v2 >/dev/null

# 1. API via VIP
kubectl get --raw /readyz >/dev/null 2>&1 && ok "API /readyz via VIP" || bad "API unreachable via 192.0.2.10"

# 2. Nodes
NOTREADY=$(kubectl get nodes --no-headers | grep -cv ' Ready')
[ "$NOTREADY" -eq 0 ] && ok "all nodes Ready" || bad "$NOTREADY node(s) NotReady"
[ "$(kubectl get nodes --no-headers | wc -l)" -eq 6 ] && ok "6 nodes present" || bad "node count != 6"

# 3. Workloads
BADPODS=$(kubectl get pods -A --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded | wc -l)
[ "$BADPODS" -eq 0 ] && ok "no unhealthy pods" || bad "$BADPODS pod(s) not Running"

# 4. Cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief >/dev/null 2>&1 \
  && ok "cilium healthy" || bad "cilium status failed"

# 5. GitOps
OOS=$(argocd app list -o json 2>/dev/null | jq '[.[] | select(.status.sync.status!="Synced")] | length')
[ "${OOS:-99}" -eq 0 ] && ok "all argocd apps Synced" || bad "${OOS:-?} app(s) OutOfSync"

# 6. Storage
DEGRADED=$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq '[.items[] | select(.status.robustness=="degraded")] | length')
[ "${DEGRADED:-99}" -eq 0 ] && ok "no degraded Longhorn volumes" || bad "${DEGRADED:-?} degraded volume(s)"

# 7. Backups fresh (<26h)
velero backup get --output json 2>/dev/null | jq -e '[.items[] | select(.status.phase=="Completed")] | length > 0' >/dev/null \
  && ok "velero has completed backups" || bad "no completed velero backups"

# 8. Ingress path
curl -sfI --max-time 5 https://whoami.apps.example.com >/dev/null && ok "ingress path (NPM→LB→pod)" || bad "whoami unreachable"

# 9. Certificates
NOTREADYCERT=$(kubectl get certificates -A -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status!="True"))] | length')
[ "${NOTREADYCERT:-99}" -eq 0 ] && ok "all certificates Ready" || bad "cert(s) not Ready"

exit $FAIL
```

### Standing monitors (external witness)

Uptime Kuma on the monitoring VM (outside the cluster) checks VIP :6443, whoami, ArgoCD,
Longhorn UI, MinIO. Alertmanager covers the inside view
([05 § baseline alerts](05-platform-services.md#baseline-alerts-severity-critical--warning--info)).
The overlap is deliberate: each catches the other's blind spot.

## Chaos Drills

Run **quarterly** (and after any major upgrade). One drill at a time,
during a self-declared maintenance window, with `cluster-health.sh` green
before starting. Log every run.

### C1 — Physical node loss (the headline claim)

```bash
# Rotate which host each quarter: pve-2 → pve-1 → pve-3
ssh root@192.0.2.5 'qm stop 502 && qm stop 505'   # hard stop, no drain
```

Expect, in order: VIP still answers (≤10s blip if the stopped control held
it); NodeDown alerts ≤5 min; pods rescheduled ≤6 min; Longhorn volumes
degraded-but-serving; whoami never stops answering. Restore with
`qm start`, confirm replicas rebuild to healthy.
**Fail condition:** any app hard-down > 7 min, or replicas don't rebuild.

### C2 — etcd member loss (control VM only)

`qm stop 501`. API must keep serving (2/3). Start it again; member
rejoins. Then read [08 § R5](08-backup-dr.md#r5--etcd-quorum-loss) once,
so the day two members die you're rereading, not learning.

### C3 — Ingress failover

Find which worker answers ARP for the ingress IP
(`arp -a | grep 192.0.2.200` from the admin workstation, map MAC to VM), stop that
worker. The L2 announcement must move: whoami answers again ≤30s.

### C4 — Storage kill

Delete one replica of a test volume in Longhorn UI → auto-rebuild.
Then the full restore path: backup → delete volume → restore
([08 § R1](08-backup-dr.md#r1--restore-a-single-pvc)).

### C5 — Full restore game day (annual, or before any risky change)

Tear down **one** control VM and **one** worker VM (different hosts) via
tofu destroy, rebuild both from docs alone — no memory, just this folder.
Any step that requires improvisation is a documentation bug: log it and fix
the doc.

## Upgrade Testing

Before a k3s minor-version bump on the real cluster: spin a single-node
throwaway k3s VM on the **sandbox** node (203.0.113.15) at the target
version, confirm Cilium + Longhorn charts install clean at their pinned
versions. Cheap insurance, ~30 minutes.

## Drill Log

Append-only. Every gate, drill, and game day gets a row — including
failures (especially failures).

| Date | Test | Result | Time to recover | Notes / follow-up |
|---|---|---|---|---|
| _yyyy-mm-dd_ | _e.g. C1 (pve-2)_ | _pass/fail_ | _mm:ss_ | _what surprised us_ |
