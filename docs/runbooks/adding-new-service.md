# Runbook: Adding a New Service

> **Status (2026-09-25):** current. The detailed k3s workflow is
> [`k3s-v2/06-operations.md`](../../k3s-v2/06-operations.md) (W1); this page is
> the decision and the short version.

## Decision: where does it run?

| If the service is... | Deploy to... |
|---------------------|-------------|
| A containerised app, platform component or anything that benefits from scheduling, self-healing or Longhorn storage | **k3s cluster, via the gitops repository** (the default) |
| A monitoring/automation service that must keep working when the cluster is down | the observability tier VM |
| An end-user app that is a poor fit for Kubernetes | the apps tier VM |
| Reverse proxy / tunnel | **nothing new** — the edge tier VM is ingress-only (ADR 0006) |
| A test or experiment | `preprod-1` or the sandbox host, never production first (ADR 0011 decision 7) |

The tier VMs are the three function-tier Docker VMs from ADR 0006 (edge,
apps, observability). The cluster is the main path; reach for a tier VM only
when the service has a reason to live outside it.

## Adding to the k3s cluster (default path)

1. **Create the app directory in the gitops repository:**
   ```
   clusters/homelab/apps/<app>/
   ├── application.yaml     # ArgoCD Application (or Helm values reference)
   ├── deployment.yaml      # namespace, PSS labels, resources, probes
   ├── service.yaml
   ├── ingress.yaml         # host: <app>.apps.example.com, class nginx
   └── pvc.yaml             # storageClassName: longhorn (only if stateful)
   ```
   Per manifest: namespace set, image tag pinned, resource requests and limits
   set, liveness/readiness probes, labels `app.kubernetes.io/name` and
   `app.kubernetes.io/part-of: homelab`.

2. **ArgoCD Application:**
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: <app>
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: <gitops-repo-url>
       path: clusters/homelab/apps/<app>
       targetRevision: main
     destination:
       server: https://kubernetes.default.svc
       namespace: <app>
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

3. **Secrets**, if any: seal them with sealed-secrets and commit only the
   sealed form. Never commit a plain Secret.

4. **Commit and push.** ArgoCD picks it up (or `argocd app sync <app>` to skip
   the poll). Watch `argocd app get <app>` until Synced/Healthy.

5. **Expose it.** Add an NPM proxy host on the edge VM:
   `<app>.apps.example.com` → the ingress-nginx LoadBalancer IP
   (`http://192.0.2.200:80`), websockets on, reusing the `*.apps.example.com`
   wildcard certificate.
   - No DNS change is needed: OPNsense Unbound (wildcard redirect zone) and
     Pi-hole (wildcard) already resolve any `*.apps.example.com` name to NPM.
   - ⚠️ Do **not** add per-host overrides beneath the wildcard in the OPNsense
     GUI — Unbound refuses to start when local-data exists beneath a redirect
     zone.

6. **Verify** from the LAN: `curl -I https://<app>.apps.example.com` → 200/302.

7. **Monitor** it if it matters: a ServiceMonitor for kube-prometheus-stack if
   it exposes metrics, and an uptime check.

**Rollback:** `git revert` the commit; ArgoCD converges back. Do not fix forward
with `kubectl edit` — self-heal overwrites it.

## Adding to a tier VM (Docker Compose)

Only when the decision table points here.

1. Use a **directory per service**, each with its own `docker-compose.yml` and,
   if it needs secrets, an `.env.example`. Services do not share a compose
   stack or Docker networks.
2. Pin the image tag and use bind mounts (`./data:/data`), not named volumes.
3. The real `.env` lives only on the VM (mode 600). Never commit it.
4. Deploy on the VM with `docker compose up -d`, then add the NPM proxy host
   (`<service>.apps.example.com` → `http://<tier-vm-ip>:<port>`) exactly as in
   step 5 above.
5. If it exposes metrics, add a scrape target on the observability VM and
   reload Prometheus.
