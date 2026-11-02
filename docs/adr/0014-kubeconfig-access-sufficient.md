# 0014 — Kubeconfig-based access is sufficient for the single-operator k3s-v2 cluster

**Status:** Accepted 2026-09-30 — decided by the operator on 2026-09-28.

## Context

k3s-v2 has one human operator. ArgoCD and Grafana already use Forgejo OIDC.
A 2026-08-05 re-scope established that Longhorn UI and the deployed Hubble
have no ingress: access is through authenticated `kubectl port-forward`.
Only kubectl OIDC remained, with an explicit alternative of recording why
kubeconfig access is sufficient. The per-human read-only kubeconfig already
exists and was used for real reads on 2026-09-30.

## Decision

Reuse certificate-based kubeconfig access for this single-operator cluster.
Retain authenticated, RBAC-authorized port-forward access for Longhorn UI and
Hubble. Do **not** add kube-apiserver `oidc-*` arguments or a Longhorn/Hubble
ingress. ArgoCD and Grafana retain their existing Forgejo OIDC integration.
This avoids another API authentication dependency and UI exposure without a
current multi-user or external identity requirement.

## Consequences

- Use the per-human read-only kubeconfig for daily reads; reserve the admin
  certificate for break-glass. As documented in the gitops repository's
  read-only kubeconfig runbook and minting script, the certificate CN
  identifies the human. `homelab:readonly` is its group for
  audit legibility; permissions come from per-human bindings, not a group binding.
- Read-only access excludes Secrets, writes, exec and `pods/portforward`.
  Retaining UI port-forward access therefore requires a separately authorized
  privileged context; it does not grant tunnels to the daily read-only identity
  or make the Longhorn UI read-only. This ADR adds no RBAC grants.
- Certificate upkeep remains the operator's responsibility: the script requests
  90 days by default, but the signer can clamp the lifetime; check the printed
  actual `notAfter`. Rotate by re-running the script with the same username;
  existing bindings remain valid and the old certificate lasts until its expiry.
  Kubernetes has no certificate revocation: removing both per-human bindings
  through GitOps removes their grants after sync, not certificate authentication.
- Shared-admin-credential retirement is **out of scope and not completed by
  this ADR**. It has a fleecing/break-glass safety dependency and is a separate
  follow-up, which must preserve recovery access before anything is removed.
  The runbook's old in-cluster Forgejo rationale predates the relocation recorded
  in [ADR 0011](0011-lab-operating-posture.md); it is not this decision's premise.

## Revisit triggers

- A second human operator needs cluster access.
- Longhorn UI or Hubble is exposed through an ingress.
- An external identity requirement makes certificate-based access insufficient.
