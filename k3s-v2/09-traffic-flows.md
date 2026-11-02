# 09 — Traffic & Workflow Flows

> **Status (2026-09-25):** design intent, written for the 2026-07 build — [AS-BUILT.md](AS-BUILT.md) is authoritative for what is running ([README](README.md)).

Sequence diagrams for every interesting path: request traffic, control
traffic, GitOps, certificates, backups. Companion to the static topology
in [01-architecture.md](01-architecture.md). Addresses: API VIP
`192.0.2.10`, ingress-nginx `192.0.2.200`.

## F1 — External User (Internet → app)

No WAN port-forwards exist; the **only** way in is the Cloudflare tunnel.

```mermaid
sequenceDiagram
    autonumber
    participant U as External user
    participant CF as Cloudflare edge
    participant CD as cloudflared<br/>(edge VM, 198.51.100.40)
    participant NPM as NPM<br/>(edge VM, 198.51.100.40)
    participant LB as ingress-nginx<br/>(192.0.2.200 via Cilium L2)
    participant P as App pod

    U->>CF: https://app.apps.example.com (public DNS → Cloudflare)
    CF->>CD: via tunnel (outbound-established, TLS)
    CD->>NPM: http://localhost (same VM)
    NPM->>LB: HTTP :80, Host: app.apps.example.com
    Note over NPM,LB: crosses LAN → cluster VLAN<br/>(OPNsense rule: 198.51.100.40 → 192.0.2.200)
    LB->>P: route by Host/path → Service → pod (eBPF, no kube-proxy)
    P-->>U: response back along the same path
```

TLS terminates twice by design: Cloudflare edge (public cert) and
NPM (wildcard cert id 2). Inside the lab, NPM→ingress is HTTP with the
Host header preserved — one place (NPM) owns the lab's TLS posture.

## F2 — Internal User (LAN → app, split DNS)

```mermaid
sequenceDiagram
    autonumber
    participant M as LAN client
    participant DNS as Unbound / Pi-hole
    participant NPM as NPM (198.51.100.40)
    participant LB as ingress-nginx (192.0.2.200)
    participant P as App pod

    M->>DNS: resolve app.apps.example.com
    DNS-->>M: 198.51.100.40 (wildcard redirect zone → NPM)
    M->>NPM: HTTPS (wildcard LE cert, valid — no warnings)
    NPM->>LB: HTTP :80, Host preserved
    LB->>P: Service → pod
    P-->>M: response
```

Consequence of the wildcard redirect: **every** `*.apps.example.com` name goes
to NPM — including `k3s.lab.example.com`. That's why kubeconfigs use the VIP
IP, and why new apps need an NPM proxy host but **zero DNS changes**.

## F3 — Kubernetes API HA (kube-vip failover)

```mermaid
sequenceDiagram
    autonumber
    participant K as kubectl (workstation)
    participant VIP as VIP 192.0.2.10
    participant C1 as node-1 (VIP holder)
    participant C2 as node-2
    participant C3 as node-3

    K->>VIP: https://192.0.2.10:6443
    VIP->>C1: (C1 answers ARP for the VIP)
    Note over C1: node-1 dies ⚡
    C2->>C2: kube-vip leader election wins
    C2-->>K: gratuitous ARP — VIP now maps to C2's MAC
    K->>VIP: retry succeeds (~seconds)
    Note over C2,C3: etcd still has 2/3 members — writes continue
```

## F4 — GitOps Deploy (commit → running pod)

```mermaid
sequenceDiagram
    autonumber
    actor L as the operator
    participant F as Forgejo (gitops repo)
    participant A as ArgoCD
    participant K as kube-apiserver (VIP)
    participant P as New pods

    L->>F: git push (app manifests / bumped image tag)
    A->>F: poll (~3 min) or webhook
    A->>A: render + diff desired vs live
    A->>K: apply the diff (sync)
    K->>P: scheduler places pods (taints, zones, tier labels)
    A->>K: health checks until Healthy
    A-->>L: UI/CLI shows Synced + Healthy
    Note over A,K: manual kubectl edits later?<br/>self-heal reverts them → git is the only door
```

## F5 — Certificate Issuance (DNS-01, no inbound traffic)

```mermaid
sequenceDiagram
    autonumber
    participant CM as cert-manager
    participant LE as Let's Encrypt
    participant CF as Cloudflare DNS API
    participant S as Secret (wildcard TLS)

    CM->>LE: order *.apps.example.com
    LE-->>CM: DNS-01 challenge token
    CM->>CF: create TXT _acme-challenge.apps.example.com (API token, sealed secret)
    LE->>CF: query TXT record — matches
    LE-->>CM: certificate issued
    CM->>S: store cert+key; renew automatically at 2/3 lifetime
    CM->>CF: clean up TXT record
```

Works with zero inbound connectivity — the whole reason DNS-01 is the
only viable ACME method behind double NAT.

## F6 — Backup Flows (nightly)

```mermaid
sequenceDiagram
    autonumber
    participant LH as Longhorn (workers)
    participant V as Velero
    participant E as etcd (controls)
    participant M as MinIO on TrueNAS (198.51.100.50:9000)
    participant PBS as PBS VM (pve-4)
    participant PBS2 as secondary PBS VM (pve-3)

    Note over LH,M: daily snapshot (local) · weekly backup (off-cluster)
    LH->>M: incremental volume backups → s3://lab-backups/longhorn
    V->>M: 02:00 — cluster objects → s3://lab-backups/velero
    E->>E: 03:00 — local etcd snapshot
    E->>M: same snapshot → s3://lab-backups/etcd
    Note over PBS: 22:30 — vzdump of all 6 VMs (whole-VM layer)
    PBS->>PBS2: nightly pull-sync (second copy, different host)
```

All four layers land on hardware **outside the cluster** (pve-4), and the VM
layer gets a second copy on a second host (pve-3). Restore paths:
[08-backup-dr.md](08-backup-dr.md).

## F7 — Pod-to-Pod with NetworkPolicy (Phase 8 posture)

```mermaid
sequenceDiagram
    autonumber
    participant A as pod A (ns: frontend)
    participant CIL as Cilium eBPF (node)
    participant B as pod B (ns: backend)
    participant H as Hubble

    A->>CIL: connect to backend-svc:5432
    CIL->>CIL: policy lookup (default-deny + explicit allows)
    alt allowed by CiliumNetworkPolicy
        CIL->>B: forward (direct eBPF path, no iptables)
        CIL-)H: flow record: FORWARDED
    else no matching allow
        CIL--xA: drop
        CIL-)H: flow record: DROPPED + policy verdict
    end
    Note over H: hubble observe --verdict DROPPED<br/>= the debugging entry point
```

Every namespace ships a default-deny plus explicit allows for: its own
traffic, DNS (kube-dns), ingress-nginx (if exposed), and Prometheus
scraping. The Hubble verdict log is what makes this posture *operable*
rather than a foot-gun.
