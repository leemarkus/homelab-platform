# 02 — Design Decisions

> **Status (2026-09-25):** design intent, written as the 2026-07 build plan. [AS-BUILT.md](AS-BUILT.md) is authoritative for what is running ([README](README.md)).

Every non-obvious choice, the alternatives it beat, and what the same
problem looks like in a real enterprise. The condensed decision record is
[ADR 0008](../docs/adr/0008-k3s-v2-enterprise-rebuild.md); this doc
is the long form.

Format per decision: **Chosen** → alternatives table → reasoning →
enterprise counterpart.

---

## D1 — Distribution: k3s (HA, embedded etcd)

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **k3s** | single binary, embedded etcd, low RAM, already known here, easy HA | less "vanilla" (bundled components must be disabled deliberately) | ✅ chosen |
| RKE2 | k3s's security-hardened sibling, CIS-ready, closest to enterprise Rancher shops | ~2× the RAM/CPU baseline; overkill for 6 small VMs | strong runner-up |
| kubeadm | the "real" way, maximum learning about control-plane internals | you own every component's lifecycle; upgrade toil is significant | rejected: toil > learning value here |
| Talos | immutable, API-driven OS, arguably the most modern pattern | replaces the whole OS layer; conflicts with the Ansible/Ubuntu skill track this lab practices | rejected for now; worth a future sandbox experiment |

k3s keeps the operational surface small while still exposing every
enterprise-relevant concept (etcd quorum, CNI choice, upgrade orchestration).
We deliberately disable its training-wheel bundles (flannel, traefik,
servicelb, local-path) and replace each with an explicit choice; that *is*
the curriculum.

**Enterprise counterpart:** EKS/AKS/GKE control planes, or RKE2/OpenShift
on-prem. The skill that transfers: knowing what the managed service is
doing for you.

## D2 — Topology: 3 dedicated control planes + 3 workers, one pair per host

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **3 CP + 3 workers (1+1 per host)** | true per-host failure domain; etcd isolated from workload noise | 6 VMs to manage; ~18GB RAM on control planes | ✅ chosen |
| 3 combined server+worker VMs | fewest VMs, most RAM for workloads | workload spikes starve etcd: the classic homelab k3s death spiral | rejected |
| v1 layout (2 CP on one host) | — | losing pve-1 kills quorum; this is the flaw v2 exists to fix | rejected (see v1 comparison) |

etcd is latency-sensitive; fsync stalls from a noisy neighbor cause leader
elections and API flapping. Dedicated, tainted control planes are the
single highest-value "enterprise" habit this design adopts.

**Enterprise counterpart:** managed control planes (EKS) or dedicated
master nodes (kubeadm/OpenShift). Nobody schedules workloads on masters
in production.

## D3 — CNI: Cilium (kube-proxy replacement, LB-IPAM, Hubble)

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Cilium** | eBPF dataplane; replaces kube-proxy *and* MetalLB; real NetworkPolicy; Hubble flow visibility | steepest learning curve; more moving parts to understand when broken | ✅ chosen |
| flannel (k3s default) | zero-config, boring | no NetworkPolicy, no LB, no observability: three extra components needed anyway | rejected |
| Calico | mature, great NetworkPolicy, huge enterprise install base | still needs MetalLB + kube-proxy; eBPF mode exists but Cilium's tooling (Hubble, `cilium` CLI) is stronger for learning | close second |

One component replacing three (kube-proxy, MetalLB, flannel) is a net
*reduction* in moving parts, and Hubble gives packet-level answers to
"why can't pod A reach pod B", the most common debugging need once
NetworkPolicies exist (Phase 8 enforces default-deny).

**Enterprise counterpart:** Cilium is the default CNI in GKE Dataplane V2
and increasingly common in on-prem banks and telcos; Calico is its main
rival. Either way, eBPF networking is current-decade production reality.

## D4 — API HA: kube-vip (ARP mode)

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **kube-vip** | runs *inside* the cluster, no extra VM, VIP + leader election in one DaemonSet | ARP failover takes a few seconds; gratuitous-ARP quirks possible | ✅ chosen |
| HAProxy + keepalived VM(s) | classic, battle-tested, LB-aware health checks | one (or two) more VMs to patch; a new SPOF unless doubled | rejected |
| DNS round-robin | trivial | no health awareness; and the split-DNS wildcard makes `*.apps.example.com` names unusable for this anyway | rejected |

v1's kubeconfig pointed at its first server's IP, a hidden SPOF that
survived until this redesign. The VIP (`192.0.2.10`) fixes it with zero
extra infrastructure.

**Enterprise counterpart:** the cloud load balancer in front of every
managed control plane; F5/keepalived VIPs on-prem.

## D5 — Service LoadBalancer: Cilium LB-IPAM + L2 announcements

Folded into D3: klipper-lb (k3s default) only hairpins node IPs; MetalLB
is fine but is another controller to run. Cilium already owns the
dataplane, so its LB-IPAM pool (`192.0.2.200–220`) plus an L2 announcement
policy does the same job with zero additional components. If Cilium's L2
mode ever disappoints, MetalLB is a drop-in swap (documented exit path).

**Enterprise counterpart:** cloud LBs / BGP-advertised VIPs. (BGP from
Cilium to OPNsense is a tempting future upgrade, not a day-1 item.)

## D6 — Ingress: ingress-nginx, single class

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **ingress-nginx** | ubiquitous, boring, every annotation documented on the internet | Ingress API is "done" (frozen upstream); Gateway API is the future | ✅ chosen |
| Envoy Gateway | Gateway API native, modern | younger; and v1 proved that running it *alongside* nginx just doubles the surface | rejected as primary |
| Traefik (k3s default) | integrated | weakest fit for learning transferable config; disabled with the other bundles | rejected |

v1 ran **both** Nginx Ingress and Envoy Gateway with no rule for which
owned what. v2's rule: one ingress class, period. When Gateway API
becomes compelling, Cilium can serve it without adding a new component.

**Enterprise counterpart:** ingress-nginx remains the most common
on-prem ingress; Gateway API adoption is where enterprises are heading,
the same migration this lab would practice later.

## D7 — TLS: cert-manager with Cloudflare DNS-01 wildcard

HTTP-01 is impossible here (no WAN port-forwards; external traffic only
arrives via the Cloudflare tunnel), so DNS-01 is not just preferred but
*required*. A wildcard for `*.apps.example.com` (and optionally
`*.k8s.lab.example.com`) mirrors the wildcard certificate NPM already
serves.

LAN traffic terminates TLS at NPM; NPM forwards HTTP to ingress-nginx
with the Host header intact. cert-manager's wildcard on the ingress
serves direct-to-LB access and any service that needs in-cluster TLS.
See [09-traffic-flows.md](09-traffic-flows.md) for both paths drawn out.

**Enterprise counterpart:** cert-manager + corporate ACME/Vault PKI is
the standard in-cluster pattern; the "TLS terminates at the edge proxy"
split mirrors enterprise LB → app-tier design.

## D8 — GitOps: ArgoCD app-of-apps from Forgejo

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **ArgoCD** | UI that teaches (visual diff/sync/health), app-of-apps pattern, already known from v1 | heavier than Flux | ✅ chosen |
| Flux | lighter, more "pure" GitOps, great OCI support | no UI, worse for a learning lab; would discard v1 ArgoCD experience | rejected |
| Helm-by-hand | simple | not GitOps; unrecoverable-cluster problem stays unsolved | rejected |

The chicken-and-egg (Forgejo lives on the cluster ArgoCD manages) was
handled by **sequencing**: Forgejo stayed on the old cluster until Phase 7
and migrated last (**done 2026-07-17**: Forgejo now self-hosts on v2 and
the old cluster is powered off). A GitHub push-mirror as permanent
bootstrap/DR insurance is an optional final step, deferred.

**Enterprise counterpart:** ArgoCD is the dominant enterprise GitOps
tool; app-of-apps / ApplicationSets are exactly how platform teams run
fleets.

## D9 — Secrets: sealed-secrets

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **sealed-secrets** | zero external dependencies; encrypted secrets live safely in Git; one controller | cluster-side private key becomes a crown jewel (escrow procedure mandatory) | ✅ chosen |
| SOPS + age | keys under your control, no controller | key distribution is manual; integrates less cleanly with ArgoCD | viable alternative |
| External Secrets Operator + Vault | the enterprise answer | requires running Vault, a whole HA product, before the first secret exists | deferred until an IdP/Vault project happens |

Escrow rule: the sealed-secrets controller key is copied outside the
repository and to the TrueNAS backup target **immediately after install**
([05 § sealed-secrets](05-platform-services.md#sealed-secrets)); losing it
means re-sealing every secret.

**Enterprise counterpart:** Vault/ESO. sealed-secrets teaches the core
discipline (no plaintext secrets in Git) with one component.

## D10 — Storage: Longhorn (3 replicas) + NFS bulk class

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Longhorn** | purpose-built for k3s-class clusters; replica placement by zone; snapshots + off-cluster backups; UI that teaches | replicated SSD space is expensive (3× write amplification) | ✅ chosen |
| Rook-Ceph | the enterprise on-prem king | wants 3 dedicated storage nodes + 10GbE; brutal on 32GB mini PCs | rejected: wrong hardware class |
| NFS only (TrueNAS) | simple, capacity-cheap | pve-4 becomes a storage SPOF for *every* workload; no per-volume snapshots/restores in k8s terms | rejected as primary, kept as `nfs-bulk` class |
| local-path (k3s default) | zero overhead | pod is welded to a node; node loss = data loss | rejected (disabled) |

Split: **replicated SSD for state that matters** (databases, Forgejo),
**NFS for bulk** (media, caches). Longhorn replicas use
`topology.kubernetes.io/zone` anti-affinity so one replica lands on each
physical host.

**Enterprise counterpart:** SAN/Ceph/EBS with storage classes per tier.
The "fast-replicated vs cheap-bulk" split is universal.

## D11 — Backups: four independent layers

Layer details and restore procedures: [08-backup-dr.md](08-backup-dr.md).

1. **Longhorn backups** → MinIO on TrueNAS (volume level)
2. **Velero** → same MinIO (Kubernetes object level)
3. **etcd snapshots** → local + shipped to MinIO (control-plane state)
4. **PBS VM images** → the PBS VM on pve-4, synced to the secondary PBS VM on pve-3 (whole-VM level)

Reasoning: each layer restores a *different failure*, and no layer shares
a failure mode with what it protects (backups live on pve-4/TrueNAS, outside
the cluster). v1 had layer 4 only.

**Enterprise counterpart:** app-level + infra-level backup separation;
Velero is the de-facto k8s DR tool.

## D12 — Observability: in-cluster collection, external single pane

Prometheus + Alertmanager + Loki run **in** the cluster (they must survive
node loss with it), but dashboards stay on the observability VM's Grafana
(198.51.100.42), which simply adds the cluster Prometheus/Loki as
datasources. No second Grafana; the lab keeps one pane of glass (ADR 0006
tiering). Uptime Kuma on the same VM watches the cluster *from outside*: an
external witness that pages even if the cluster's own monitoring dies.

**Enterprise counterpart:** central observability team owning Grafana,
per-cluster collection agents. Exactly this shape.

## D13 — Cluster UI & upgrades: Headlamp + system-upgrade-controller (Rancher dropped)

Rancher in v1 consumed ~2GB RAM to duplicate what ArgoCD (deploy), Headlamp
(inspect), and system-upgrade-controller (upgrade Plans) do with a fraction
of the footprint. Dropping it is the design's clearest "simplicity over
enterprise cosplay" call: Rancher earns its keep managing *fleets* of
clusters, not one.

## D14 — Provisioning: OpenTofu + cloud-init + Ansible

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **OpenTofu (bpg/proxmox) + Ansible** | declarative VM inventory; node replacement = `tofu apply` + playbook; open-source licence | two tools to learn | ✅ chosen |
| Manual `qm` commands | no new tools | v1's "specs: TBD" problem forever | rejected |
| Pulumi/other | — | no advantage over tofu here | rejected |

The split: **OpenTofu owns VM existence** (CPU/RAM/disks/cloud-init),
**Ansible owns OS state** (packages, mounts, sysctls), **k3s/ArgoCD own
everything above**. Clean layers, each replaceable.

**Enterprise counterpart:** Terraform + config management + GitOps is
*the* standard on-prem platform pipeline.

---

## v1 → v2 Comparison

| Aspect | v1 | v2 (this design) | Why it matters |
|---|---|---|---|
| Control planes | 3, but **2 on pve-1** | 3, one per physical host | v1 loses quorum if pve-1 dies: the defining flaw |
| Physical hosts | 2 (pve-1, pve-2) | 3 (+ pve-3) | third failure domain; real N+1 |
| API endpoint | first server's IP, no VIP | kube-vip VIP 192.0.2.10 | v1 tooling breaks when one VM is down |
| CNI | flannel (default) | Cilium | NetworkPolicy + LB + flow observability vs none |
| kube-proxy | yes | replaced by eBPF | fewer components, better visibility |
| Service LB | klipper (default) | Cilium LB-IPAM pool | real LB IPs with failover |
| Ingress | nginx **and** Envoy Gateway | ingress-nginx only | one code path, one debugging story |
| Rancher | yes | dropped | ~2GB RAM back; ArgoCD+Headlamp cover it |
| Upgrades | Rancher-managed | system-upgrade-controller Plans | declarative, Git-tracked |
| Provisioning | manual, "specs TBD" | OpenTofu + Ansible | node replacement becomes a 30-min workflow |
| Longhorn backups | **none** | MinIO target + recurring jobs + drills | v1 data loss = permanent |
| Cluster-state backup | none | Velero + etcd snapshots off-node | v1 cluster loss = rebuild from memory |
| Secrets | ad-hoc | sealed-secrets, key escrowed | secrets in Git, safely |
| NetworkPolicy | none | default-deny per namespace (Phase 8) | blast-radius containment |
| Node taints/labels | none | tainted CPs, zone labels | correct scheduling + replica spread |
| Docs | scattered | this folder + ADR + runbooks | operable from the docs alone |

## Enterprise Mapping

What each choice teaches, in production terms:

| This lab | Enterprise equivalent | Transferable skill |
|---|---|---|
| k3s HA embedded etcd | EKS/AKS/GKE control plane, RKE2/OpenShift | quorum math, etcd care & feeding |
| kube-vip VIP | cloud LB in front of API, F5/keepalived | control-plane HA patterns |
| Cilium + Hubble | GKE Dataplane V2, on-prem Cilium/Calico | eBPF networking, NetworkPolicy design, flow debugging |
| Cilium LB-IPAM (L2) | cloud LoadBalancer services, BGP VIPs | service exposure models |
| ingress-nginx + NPM edge | enterprise LB → ingress tier split | layered traffic architecture |
| cert-manager DNS-01 | corporate PKI / ACME automation | certificate lifecycle automation |
| ArgoCD app-of-apps | platform-team GitOps fleets | drift detection, sync waves, app-of-apps |
| sealed-secrets | Vault + External Secrets Operator | secrets-in-Git discipline |
| Longhorn zones | EBS/Ceph with topology awareness | storage classes, replica placement |
| Velero + etcd snapshots | enterprise DR runbooks | RPO/RTO thinking, restore drills |
| kube-prometheus-stack → central Grafana | central observability team model | federated monitoring |
| OpenTofu + Ansible + cloud-init | Terraform pipelines, golden images | immutable-ish infra, IaC layering |
| system-upgrade-controller | managed node pools / cluster API | declarative upgrade orchestration |

## Deliberately Not Doing (yet)

| Skipped | Why | Revisit trigger |
|---|---|---|
| Service mesh (Istio/Linkerd) | no multi-service traffic policies needed; Cilium covers L3/4 | if mTLS-between-apps becomes a learning goal |
| OIDC / SSO for kubeconfig & UIs | no IdP in the lab yet | when an Authentik/Keycloak project lands |
| BGP to OPNsense | L2 announcements suffice at this scale | if LB failover time ever matters |
| Gateway API | one ingress is enough; Cilium can add it later without new components | when a real use case (TCP routes, header matching) appears |
| GitHub mirror of gitops repo | deferred; optional final step | after Phase 8 |
| Multi-cluster / cluster API | one cluster, one site | never, probably: this is a homelab |
