# Live cluster configs (as applied)

> **Status (as of 2026-09-25):** these are the configs as applied to the cluster at that date, with secrets redacted. Their install lines record the July 2026 build (`v1.34.4+k3s1`); rebuilds install the version pinned in the `k3s_node` role.

The exact config files applied to the running k3s v2 cluster, kept in Git for
reproducibility. The cluster join token is **redacted** here as `__TOKEN__`;
the real value is kept outside the repository (in the operator's password
manager) and on the nodes in `/etc/rancher/k3s/config.yaml`. Other secrets,
such as the Cloudflare API token that `cluster-issuer.yaml` references, are
created out of band and are not in these files.

| File | Applied to | Purpose |
|------|-----------|---------|
| `server-init.yaml` | node-1 `/etc/rancher/k3s/config.yaml` | cluster-init bootstrap server |
| `server-join.yaml` | node-2, node-3 | additional control-plane servers |
| `agent.yaml` | node-4, node-5, node-6 | worker agents |
| `kube-vip-ds.yaml` | node-1 manifests dir | API VIP 192.0.2.10 (ARP) |
| `cilium-values.yaml` | Helm | CNI, kube-proxy replacement, LB-IPAM |
| `cilium-lb-pool.yaml` | kubectl | LoadBalancer IP pool (192.0.2.200-220) + L2 announcement |
| `ingress-nginx-values.yaml` | Helm, then Argo CD | ingress controller, LB Service pinned to 192.0.2.200 |
| `cert-manager-values.yaml` | Helm, then Argo CD | cert-manager + public DNS-01 self-check nameservers |
| `cluster-issuer.yaml` | kubectl | Let's Encrypt DNS-01 issuer + wildcard cert |
| `longhorn-values.yaml` | Helm, then Argo CD | block storage, 3-replica hard zone anti-affinity |
| `argocd-values.yaml` | Helm | GitOps controller (insecure, TLS terminated upstream by NPM) |
| `kube-prometheus-stack-values.yaml` | Helm, then Argo CD | Prometheus/Alertmanager/Grafana |
| `velero-values.yaml` | Helm, then Argo CD | daily cluster-object backups to MinIO (`upgradeCRDs: false`: the hook's bitnami/kubectl image no longer exists) |
| `loki-values.yaml` | Argo CD | single-binary log store, Longhorn PVC, 7d retention |
| `alloy-values.yaml` | Argo CD | log collector DaemonSet (all nodes) to Loki |

sealed-secrets is installed from its upstream **release `controller.yaml`**
(v0.38.4), because the Bitnami Helm repo is gone. The controller key is
escrowed outside the repository.

## How these files are applied

The cluster was first built with raw `helm install` / `kubectl apply` while no
git source was reachable. Since GitOps came up (2026-07-06), cert-manager,
ingress-nginx, Longhorn, kube-prometheus-stack, Velero, Loki and Alloy are
**managed by Argo CD** through the app-of-apps in the gitops repository
(`clusters/homelab/`), and these values files are the source of truth it
references. Cilium, kube-vip, sealed-secrets and Argo CD itself stay
bootstrap-tier: installed by hand, not Argo CD-managed.

## Divergences from ADR 0008 (forced by coexistence with the old v1 cluster)

Discovered live during the 2026-07-04 build; all revertible once v1 is gone:

| Design (ADR 0008) | Actual | Why |
|-------------------|--------|-----|
| worker 8 vCPU / 20 GB / 350 GB | node-4 4c/6 GB, node-5 4c/10 GB / 120 GB Longhorn | RAM/disk were shared with the v1 cluster (powered off 2026-07-17); workers since grown per ADR 0010. Historical comparison row. |
| kube-vip via in-cluster ClusterIP | kube-vip env `KUBERNETES_SERVICE_HOST=127.0.0.1:6443` | kube-proxy is disabled and there is no CNI at bootstrap, so 10.43.0.1 doesn't route; kube-vip must reach the local apiserver directly. |

**Also:** `disable-kube-proxy` is **server-only** in k3s v1.34.x. Putting it in
an agent config makes k3s-agent exit fatally. Agents inherit it cluster-wide.

**Kubeconfig gotcha:** `~/.kube/config` must give the v2 cluster **unique**
cluster/user names (`homelab-v2`), not k3s's default `default`. The old
cluster's context also used `default`, and a merge silently kept the old
v1 server address under the new context name.
