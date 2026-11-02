# Adopting production's Cilium into code — plan

**Status:** **DONE — phases 0–3 complete 2026-07-28. Production's Cilium is
owned by code.** Phase 4 (close the loop) is open; see the end of this file.

Production adoption was a **measured no-op**: helm release 1 → 2, DaemonSet
generation unchanged, all six agent pods untouched, and **207 real HTTP
requests through the Cilium load-balancer with zero non-200s**. Full results
below.

Before reusing any of this on another component, read
[Rollback](#rollback-rewritten-after-the-rehearsal-destroyed-cilium): the
originally-planned rollback destroys the release, which the rehearsal found by
doing it.

**Why:** [ADR 0011](../adr/0011-lab-operating-posture.md) decision 1
requires production nodes to be genuinely rebuildable from code, and they are
not: `roles/k3s_node` writes `flannel-backend: none` + `disable-kube-proxy:
true`, so a rebuilt node comes up NotReady with no pod networking. The CNI that
fixes that is a hand-run `helm install` from 2026-07-04, documented in
`k3s-v2/04-cluster-build.md` and owned by no code. The
component gate audit (2026-07-28) independently ranked Cilium the worst-covered component in the lab — the
only one failing **all three** columns (no restore proof, no absence alert, no
upgrade path) — and it is the CNI everything else runs on. One piece of work
pays both debts.

## What production actually runs (measured 2026-07-28, not read from docs)

| Fact | Value | How checked |
|---|---|---|
| Helm release | `cilium`, ns `kube-system`, **revision 1** | `helm list -n kube-system` |
| Chart / app | `cilium-1.17.5` / 1.17.5, installed 2026-07-04 21:25 EDT | same |
| DaemonSet | generation **1**, 6/6 ready | `kubectl get ds cilium` |
| Operator replicas | **1** | `helm get values` + live deploy |

Never upgraded — one release revision in 24 days, and one DaemonSet generation.
That is the reassuring part: there is no accumulated hand-drift to reconcile,
only the gap between the live values and the role's.

## Three discrepancies found before touching anything

Comparing `helm get values cilium` against what `roles/cilium` renders:

1. **`k8sClientRateLimit: {qps: 50, burst: 100}` — production has it, the role
   does not.** Confirmed live in `cilium-config` (`k8s-client-qps = 50`,
   `k8s-client-burst = 100`). Adopting with the role as written would drop
   these to chart defaults, throttling the CNI's API client on a 6-node
   cluster. **This is the single most dangerous line in the whole migration**:
   it would apply cleanly, report success, and degrade under load later.
2. **`ipam.operator.clusterPoolIPv4MaskSize: 24` — production has it, the role
   does not.** Live value is 24, which is also Cilium's default, so omitting it
   is *probably* a no-op. "Probably" is not the standard for the CNI; phase 0's
   render-and-diff settles it empirically instead of by argument.
3. **Two comments claim production runs 2 operator replicas. It runs 1.**
   In `roles/cilium/defaults/main.yml` and
   `inventory/group_vars/k3s_preprod.yml`. The *value* is right by coincidence;
   the stated reason for it is wrong. Same failure class ADR 0011 catalogues as
   *premise never checked* — and it is why phase 0 exists.

## Why the k3s HelmChart route and not an ArgoCD Application

Every other platform component in this lab is an ArgoCD Application. Cilium
deliberately will not be, and the reason is the same bootstrap paradox that
moves Forgejo off-cluster (ADR 0011 decision 3):

**ArgoCD cannot install the network it needs in order to run.** On a rebuilt
node — the exact scenario this work exists to enable — there is no pod
networking until the CNI is up, so nothing in the cluster can install it.
k3s's own HelmChart controller runs *before* that point, from
`/var/lib/rancher/k3s/server/manifests/`, with `bootstrap: true` granting the
install job host networking and tolerations for the not-ready taint.

So: one manager, and it is k3s. Cilium must **not** also be added to the
app-of-apps — that would be the two-writable-copies problem on the component
least able to survive it.

## The crux: preprod-1 currently proves the wrong thing

`preprod-1` already runs Cilium — but the *role* installed it there. Running the
role against it again therefore rehearses nothing about the risky step, which
is **taking over a release that a human's `helm install` created**.

To be a real rehearsal, preprod-1 must first be put back into production's
shape. That is phase 1, and it is the part most likely to be skipped as
busywork. It is not busywork; without it, phase 3 is the first time the
adoption path is ever exercised, on the only cluster there is.

### The hypothesis under test

k3s's helm-controller runs `helm upgrade --install cilium …`. Since release
names are scoped per namespace and the existing release is `cilium` in
`kube-system`, that command should **adopt** it as revision 2 rather than
conflict. And if the rendered values are equivalent, the resulting DaemonSet
spec should be unchanged, so **no rollout occurs and pod networking is never
interrupted**.

Both halves of that are plausible and neither is proven. A DaemonSet rollout
across 6 nodes is the difference between a no-op and a cluster-wide network
blip. **Phase 2 exists to turn that sentence from a belief into a measurement.**

## Phases

### Phase 0 — reconcile the values (desk work, no cluster changes)

1. Add to `roles/cilium/defaults/main.yml`, defaulting to production's live
   values: `cilium_client_rate_limit_qps: 50`, `cilium_client_rate_limit_burst: 100`,
   `cilium_cluster_pool_mask_size: 24`. Render them in the template.
2. Correct the two "production runs 2 replicas" comments to say 1, citing the
   live release rather than the doc.
3. Render the template with production's variable set (`cilium_k8s_service_host:
   192.0.2.10`) and **diff it against `helm get values cilium -n kube-system`**.

**Exit criterion:** the diff is empty on a semantic comparison (sorted keys,
normalised types). Not "looks the same" — diffed, with the output kept.

### Phase 1 — return preprod-1 to production's shape

1. Remove `/var/lib/rancher/k3s/server/manifests/cilium.yaml`. Expect the
   uninstall job to be unschedulable and to need the
   `wrangler.cattle.io/on-helm-chart-remove` finalizer patched off — this bit
   the first install on 2026-07-27 and will bite here too.
2. Verify the HelmChart CR and the release are gone and the node is NotReady.
   *A NotReady node is the correct intermediate state; do not "fix" it.*
3. `helm install cilium cilium/cilium --version 1.17.5 -n kube-system -f` a
   values file identical to production's except `k8sServiceHost: 203.0.113.20`.
4. Confirm: node Ready, release `sh.helm.release.v1.cilium.v1`, `owner=helm`,
   revision 1 — preprod-1 now has the same provenance production has.

**Exit criterion:** preprod-1 is indistinguishable in shape from production —
hand-installed release, no auto-deploy manifest.

### Phase 2 — rehearse the adoption on preprod-1

1. Add a `cilium_adopt` flag (default **false**) that converts the role's
   existing "refuse to adopt" failure into a deliberate, opt-in path. Keep the
   refusal as the default forever; adoption is a one-time act per cluster, and
   the guard is what stops a routine playbook run from becoming a CNI event.
2. Record before-state: DaemonSet `metadata.generation`, pod names and start
   times, release revision, `cilium-config` checksum.
3. Run the role with `cilium_manage: true`, `cilium_adopt: true`.
4. Record after-state and diff.

**Exit criteria — all four, or phase 3 does not start:**
- Release is at **revision 2**, still `owner=helm`, status deployed.
- DaemonSet `generation` is **unchanged** and no cilium pod restarted.
- `cilium-config` is byte-identical to before, in particular `k8s-client-qps`
  and `k8s-client-burst`.
- Node stayed Ready throughout and pod-to-pod networking never dropped —
  measured with a continuous ping between two pods across the whole run, not
  inferred from the node condition afterwards.

If the DaemonSet *does* roll: stop. That is a legitimate outcome and it changes
phase 3 from a no-op into a maintenance window with a drain plan. Finding that
out here is precisely what preprod-1 was built for.

### Phase 3 — production, in a window

Preconditions: phases 0–2 green, and an etcd snapshot taken and confirmed
uploaded (not merely scheduled).

1. Set `cilium_manage: true` and `cilium_k8s_service_host: 192.0.2.10` for
   the `k3s_v2` server group; `cilium_adopt: true` for this run only.
2. Place the manifest on **all three** control planes, not one. A manifest on a
   single node means a rebuild of that node silently ends the code ownership
   this whole exercise is establishing. The resulting CR is cluster-scoped and
   identical, so applying it three times is idempotent.
3. Watch the same four criteria as phase 2, plus: all 6 nodes Ready, Hubble
   relay and UI still up, ingress-nginx still serving.

**Rollback:** see the rewritten section below. The rollback originally planned
here — remove the manifests, then `helm rollback cilium 1` — **destroys
Cilium**. That was found by rehearsing it, which is the entire argument for
rehearsing it.

## Results — phases 0–2 (2026-07-28)

### Phase 0 — PASS

[`scripts/verify-cilium-values.sh`](../../scripts/verify-cilium-values.sh): **35 normalised lines identical** between the
role's render and `helm get values cilium`. Getting there required adding
`k8sClientRateLimit` (qps 50 / burst 100) and `ipam.operator.clusterPoolIPv4MaskSize`
to the role — see the discrepancy list above.

### Phase 1 — PASS, and it corrected a belief about k3s

preprod-1 was returned to production's shape: no auto-deploy manifest, no
HelmChart CR, no addon CR, release `cilium` revision 1 installed by the helm
CLI with production's values (differing only in `k8sServiceHost`).

**Removing the manifest file does nothing.** `rm` on
`/var/lib/rancher/k3s/server/manifests/cilium.yaml` left the `addon` CR, the
HelmChart CR, the release and the DaemonSet all in place. k3s's deploy
controller does not garbage-collect on file removal. Anyone assuming "delete
the file to undo it" is wrong, in both directions — it neither uninstalls nor
stops the chart being managed.

### Phase 2 — PASS on all four criteria

The adoption was a **genuine no-op on the running CNI**:

| Criterion | Before | After |
|---|---|---|
| Helm release | revision 1, `owner=helm` | **revision 2**, `owner=helm`, deployed — adopted, not duplicated |
| DaemonSet generation | 1 | **1** (unchanged) |
| Cilium pod | `cilium-hn8gl`, started 15:43:59, 0 restarts | **same pod, same start time, 0 restarts** |
| Operator generation | 1 | **1** (unchanged) |
| `cilium-config` sha256 | `9a05d6e1ef8a3637` | **`9a05d6e1ef8a3637`** — `k8s-client-qps=50`, `burst=100`, `mask=24` all preserved |
| Pod-to-pod traffic | — | **201 consecutive replies, seq 0–200, zero loss** across the adoption |

Both halves of the hypothesis hold: `helm upgrade --install` **adopts** the
existing release rather than colliding with it, and with equal values the
DaemonSet spec is untouched, so **nothing rolls and pod networking is never
interrupted**. Phase 3 on production is a no-op *provided phase 0 is green
against production at the time*.

### Phase 3 — PASS on production (2026-07-28 16:21 UTC)

Preconditions, all confirmed before the change: values gate green against
production; live values captured to `cilium-recovery-values-prod.yaml` (the
recovery artefact — after a CR deletion the release history no longer holds
it); etcd snapshot `pre-cilium-adoption-node-1-1785255228` (44 MB) confirmed
**in S3**, not merely taken.

| Criterion | Before | After |
|---|---|---|
| Helm release | revision 1 (2026-07-04) | **revision 2**, deployed |
| DaemonSet generation | 1 | **1** |
| All six agent pods | `cilium-{6ltvc,bswml,clvln,k9686,rtq5t,vbchv}`, started Jul 5–6 | **identical — same names, same start times, same restart counts** |
| Operator generation | 1 | **1** |
| `cilium-config` sha256 | `9a05d6e1ef8a3637` | **`9a05d6e1ef8a3637`**, `qps=50 burst=100 mask=24` |
| Nodes | 6 Ready | **6 Ready** |
| Real user traffic | — | **207 requests via the Cilium LB VIP, 0 non-200** |
| Hubble relay / UI | up | up |
| ArgoCD applications | 12 Synced+Healthy, 3 benign OutOfSync, 1 dormant | **unchanged** |

Manifest confirmed present on **all three** control planes. A re-run without
`cilium_adopt` reports `changed=0` on all three — steady state is genuinely
idempotent, so the component is code-owned rather than merely code-described.

**On measuring it honestly.** The first probe rig was two pods in `default`
exchanging HTTP, and it failed before any change was made — not a fault, the
namespace carries a `default-deny-allowlist` CiliumNetworkPolicy and the probe
was correctly denied. Rather than weaken a production network policy to
accommodate a test, the signal was moved to a **real** path already allowed and
already load-bearing: workstation → Cilium LB VIP `192.0.2.200` → ingress-nginx →
backend pod. That exercises L2 announcement, LB-IPAM and the kube-proxy
replacement datapath — the parts an adoption could plausibly break — and it is
the path a person would notice. **A synthetic probe that has to be let through
the firewall is measuring the wrong thing.**

## Rollback, rewritten after the rehearsal destroyed Cilium

**Do not delete the HelmChart CR as a rollback step. It uninstalls Cilium
entirely.**

Rehearsed on preprod-1 and proven from the k3s log:

```
handler on-helm-chart-remove: waiting for delete of helm chart for
kube-system/cilium by helm-delete-cilium, requeuing
```

Deleting the CR spawns a `helm-delete-cilium` job which runs `helm uninstall`.
The result was total: DaemonSet, operator, every ConfigMap and ServiceAccount,
the release **and its entire history** — `helm history cilium` returned
`release: not found`, so `helm rollback` had nothing to roll back to.

**Patching the finalizer off does not reliably prevent this.** The exact same
four-command sequence left the release intact in phase 1 and destroyed it in
phase 2. The mechanism for the difference is undetermined and this runbook does
not guess at it; what is established is that the outcome is not dependable, and
a rollback path that works one time in two is not a rollback path.

**The property that makes this genuinely dangerous:** existing pods kept full
connectivity through the destruction — the ping ran to 324 replies with zero
loss while Cilium did not exist. The datapath survives in the kernel; only
*newly scheduled* pods fail. On production this would look completely healthy
for as long as nothing reschedules, and then break in a way that appears
unrelated to a change made hours earlier.

### The rollback that is actually available

1. **Fix forward.** The manifest is the desired state — correct the values in
   it and helm-controller runs another `helm upgrade`. This covers every
   realistic failure of the adoption itself, because the adoption's only lever
   is the values.
2. **If Cilium must genuinely be removed**, accept it as a rebuild, not an
   undo: the cluster will be without a CNI until a fresh
   `helm install cilium cilium/cilium --version <ver> -f <captured values>`
   completes. Keep the captured values file and chart version to hand *before*
   opening the window — that file is the recovery artefact, and after a CR
   deletion the release history no longer contains it.
3. **Never** reach for `helm rollback` after touching the CR. Check
   `helm history cilium -n kube-system` first; if it says `release: not found`,
   you are in case 2.

Recovery from case 2 was exercised: re-running the role restored Cilium 1.17.5
with `qps=50 burst=100 mask=24` intact, node Ready, and new-pod networking
verified (`3 packets transmitted, 3 received, 0% loss`) — which also confirms
the phase-0 values fix on a *fresh* install, not only on an adoption.

### Phase 4 — close the loop — DONE 2026-07-28

**Cilium now passes all three component-gate columns.** It failed all three
when the audit ran the same morning.

- ✅ **`k3s-v2/04-cluster-build.md` corrected.** Its values block was wrong in
  three ways — `operator.replicas: 2`, `ipam.mode:
  kubernetes`, and no `k8sClientRateLimit` at all — and it read as the record of
  a working cluster for three weeks. Marked superseded rather than deleted, with
  a table of what it claimed against what ran, because the *shape* of that
  mistake is the reusable lesson. Its "canonical lives in gitops once ArgoCD
  adopts it" plan is explicitly rejected in place.
- ✅ **Upgrade path (column 3).** Renovate now covers this repository as well
  as the gitops repository. It still *runs* from the gitops repository, because
  this one has no CI and standing up a runner here to bump one line would be a
  moving part bought for nothing. [`renovate.json`](../../renovate.json) is
  scoped to the single `cilium_version` pin via a custom manager — the full
  infrastructure repository holds ~40 compose files with pinned tags, and an unscoped Renovate would bury the one
  PR that matters. The PR body says what the reviewer is deciding, including
  that **merging changes nothing on its own**: the upgrade happens when the role
  next runs and helm-controller performs the `helm upgrade`.
- ✅ **Absence alerts (column 2)** — `CiliumAgentGone` (critical),
  `CiliumAgentMissingOnNode` and `CiliumOperatorDown`, in the gitops
  repository's `config/platform-availability-alerts.yaml`.

**Why the absence alert matters more for this component than any other**, and
the reason it is worth three rules rather than one: when Cilium was accidentally
destroyed on preprod-1 during phase 2, a continuous pod-to-pod probe kept
succeeding — 324 replies, zero loss, with no CNI installed at all. The datapath
lives in the kernel and outlives the agent. Only *newly scheduled* pods fail. So
traffic, node Ready and pod health are all blind to a missing CNI, and the first
symptom is a rescheduled workload failing hours later for no apparent reason.
`absent()` is the load-bearing half of two of the three rules: a deleted
daemonset exports no metric, so a `== 0` comparison alone matches nothing and
stays quiet forever.

All three expressions were run against live Prometheus **with positive
controls** — an `absent()` against a deliberately wrong name to prove the rule
can fire, and a relaxed comparison to prove the two daemonset metrics actually
join. Empty results alone prove nothing; that is exactly how a permanently
silent alert looks, and this lab shipped two of those before finding them on
2026-07-28.

### The upgrade procedure, for the record

1. Bump `cilium_version` in `ansible/roles/cilium/defaults/main.yml`
   (or merge Renovate's PR).
2. `./scripts/verify-cilium-values.sh` — still green means the bump changes only
   the version.
3. Pre-prod first: `ansible-playbook playbooks/k3s-node.yml --limit preprod-1
   --tags cilium`. Measure with phase 2's method.
4. Production: same command with `--limit k3s_v2_control`. **Expect a real
   rollout this time** — a version change does alter the DaemonSet, unlike the
   adoption. Take the window accordingly.
5. Rollback is fix-forward: put the old version back and re-run. Do not delete
   the HelmChart CR.

## Risks, ranked

Re-ranked after the rehearsal. The risk that mattered was not the one at the
top of the original list.

1. **Deleting the HelmChart CR uninstalls Cilium, and it looks fine afterwards.**
   Now the dominant risk, because it is the step an operator reaches for when
   something *else* goes wrong. Existing pods keep networking, so there is no
   immediate symptom. Mitigation: the rollback section above; do not delete the
   CR, and keep the captured values file before the window opens.
2. ~~**Values drift silently on adoption**~~ — the `k8sClientRateLimit` case.
   **Closed** by phase 0's fix and `scripts/verify-cilium-values.sh`, which
   phase 3 re-runs against production immediately before the window.
3. ~~**The adoption rolls the DaemonSet**~~ — **measured, and it does not**:
   generation unchanged, same pod, zero packet loss. Re-check on production
   rather than assume, since the guarantee comes from the values matching.
4. ~~**helm-controller refuses to adopt**~~ — **it adopts cleanly**, release
   revision 1 → 2, no duplicate release.
5. **The install job cannot reach `helm.cilium.io`** — unchanged. Nodes resolve
   via public DNS (gotcha 14), so this is a WAN dependency during the window.
6. **"Remove the file to undo it" is a false belief** — phase 1 proved the file
   removal alone changes nothing. Anyone reverting by that route will think
   they have rolled back and will not have.

## What this does not do

It does not make the cluster rebuildable on its own. It closes the CNI step;
the remaining prerequisite for ADR 0011 decision 1 is one **proven** node
rebuild end-to-end. The off-site backup precondition is removed by the operator's
2026-09-28 escrow ruling; that work is deferred separately and blocks nothing.
Any vzdump removal still needs its own restore-custody review and exact approval.
