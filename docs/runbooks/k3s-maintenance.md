# Runbook: K3s Cluster Maintenance

> **Status (2026-09-25):** current — a summary; the v2 operations docs are
> authoritative (note below).

> **Live cluster = v2 (ADR 0008), kubectl context `homelab-v2`, API on the
> kube-vip VIP `192.0.2.10:6443`.** Nodes: node-1–3 (192.0.2.11–33) / node-4–6
> (192.0.2.21–43). The **authoritative, v2-specific** ops procedures live in
> [`k3s-v2/06-operations.md`](../../k3s-v2/06-operations.md) and
> [`k3s-v2/08-backup-dr.md`](../../k3s-v2/08-backup-dr.md) — prefer those. The
> examples below are the generic pattern with v2 node names.

## Checking Cluster Health

```bash
# From any server node or machine with kubeconfig (context homelab-v2)
kubectl get nodes
kubectl get pods -A
kubectl top nodes
kubectl top pods -A
```

## Upgrading K3s

Use system-upgrade-controller (v2 has no Rancher) or the manual rolling upgrade below.

### Manual Rolling Upgrade

1. **Drain and upgrade server nodes one at a time:**
   ```bash
   # On each server node (start with server that's NOT the leader):
   kubectl drain node-2 --ignore-daemonsets --delete-emptydir-data

   # SSH to the node and upgrade:
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.XX.X sh -s - server

   # Uncordon:
   kubectl uncordon node-2
   ```

2. **Repeat for remaining server nodes**

3. **Upgrade worker nodes:**
   ```bash
   kubectl drain node-4 --ignore-daemonsets --delete-emptydir-data

   # SSH to worker:
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.XX.X sh -s - agent

   kubectl uncordon node-4
   ```

4. **Verify:**
   ```bash
   kubectl get nodes -o wide
   ```

## Longhorn Maintenance

### Check volume health
```bash
kubectl -n longhorn-system get volumes.longhorn.io
```

### Longhorn UI
There is no ingress for the Longhorn UI (ADR 0014); use an authenticated
port-forward from a privileged context:
```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

## ArgoCD Maintenance

### Access ArgoCD UI
```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443
```

### Get admin password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Force sync an app
```bash
argocd app sync <app-name>
```

## Adding a New Node to the Cluster

### Server node
```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server \
  --server https://192.0.2.10:6443
```

### Worker node
```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - agent \
  --server https://192.0.2.10:6443
```

Get the token from an existing server:
```bash
cat /var/lib/rancher/k3s/server/node-token
```

## Removing a Node

```bash
# Drain the node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Delete from cluster
kubectl delete node <node-name>

# On the node itself, uninstall:
/usr/local/bin/k3s-uninstall.sh        # server
/usr/local/bin/k3s-agent-uninstall.sh   # agent
```

## etcd Snapshot (Backup)

K3s with embedded etcd:
```bash
# On a server node:
k3s etcd-snapshot save --name manual-backup
k3s etcd-snapshot ls
```
