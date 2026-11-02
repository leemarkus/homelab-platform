#!/usr/bin/env bash
# Prove that roles/cilium renders the SAME values production's Helm release is
# running. Phase 0 of docs/runbooks/cilium-adoption.md, and the gate that must
# stay green before phase 3 touches production.
#
# WHY THIS EXISTS AS A SCRIPT AND NOT A ONE-OFF COMMAND. The adoption works by
# letting k3s's helm-controller run `helm upgrade --install cilium`, which takes
# over the existing release. Helm does not merge with what is already there —
# the rendered values ARE the new release. So any key the role omits is silently
# removed from the CNI's configuration.
#
# That is not hypothetical. On 2026-07-28 this comparison found the role missing
# `k8sClientRateLimit: {qps: 50, burst: 100}`, which production has been running
# since 2026-07-04 (live in cilium-config as k8s-client-qps / k8s-client-burst).
# Adopting without it would have reset the CNI's API client to chart defaults on
# a six-node cluster — applying cleanly, reporting success, and degrading later
# under load, far from the change that caused it.
#
# Comparison is SEMANTIC (parsed, key-sorted), not textual: YAML key order and
# quoting differ harmlessly between a Helm release and a Jinja template, and a
# check that fails on those gets ignored within a week.
#
#   ./verify-cilium-values.sh              # against production (k3s_v2)
#   CILIUM_HOST=203.0.113.20 CTX=preprod \
#     ./verify-cilium-values.sh            # against a pre-prod release
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CTX="${CTX:-homelab-v2}"
NS="${NS:-kube-system}"
# The one value that legitimately differs per cluster: production reaches the
# API through the kube-vip VIP, a single-node pre-prod through its own address.
CILIUM_HOST="${CILIUM_HOST:-192.0.2.10}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v helm >/dev/null || { echo "helm not found"; exit 1; }
command -v ansible-playbook >/dev/null || { echo "ansible-playbook not found"; exit 1; }

# Render through ANSIBLE, not a hand-rolled Jinja call — the point is to test
# the artefact the role will actually write, filters and all.
cat > "$WORK/render.yml" <<'EOF'
- hosts: localhost
  gather_facts: false
  connection: local
  become: false
  tasks:
    - template:
        src: "{{ role_template }}"
        dest: "{{ out }}"
        mode: "0600"
      vars:
        ansible_managed: "rendered for verification"
EOF

# NOTE ON PRECEDENCE, learned the hard way: extra-vars outrank task vars, so the
# per-cluster host MUST be passed as an extra var *after* the defaults file.
# Setting it as a task var while loading defaults via -e silently rendered
# `k8sServiceHost: 127.0.0.1` (ansible_host for localhost) and the diff still
# looked plausible.
ansible-playbook "$WORK/render.yml" \
  -e "role_template=$REPO/ansible/roles/cilium/templates/cilium-helmchart.yaml.j2" \
  -e "out=$WORK/rendered.yaml" \
  -e "@$REPO/ansible/roles/cilium/defaults/main.yml" \
  -e "cilium_k8s_service_host=$CILIUM_HOST" >/dev/null

helm --kube-context "$CTX" get values cilium -n "$NS" -o yaml > "$WORK/live.yaml"

python3 - "$WORK" <<'PY'
import sys, yaml, json, difflib
w = sys.argv[1]
chart = yaml.safe_load(open(f"{w}/rendered.yaml"))
role  = yaml.safe_load(chart["spec"]["valuesContent"])
live  = yaml.safe_load(open(f"{w}/live.yaml")) or {}

def norm(o):
    if isinstance(o, dict): return {k: norm(v) for k, v in sorted(o.items())}
    if isinstance(o, list): return [norm(x) for x in o]
    return o

rj = json.dumps(norm(role), indent=2, sort_keys=True)
lj = json.dumps(norm(live), indent=2, sort_keys=True)

if rj == lj:
    print(f"PASS  roles/cilium renders exactly the live release's values "
          f"({len(rj.splitlines())} normalised lines)")
    sys.exit(0)

print("FAIL  the role would CHANGE the running Cilium configuration.")
print("      Every '-' line below is a setting adoption would REMOVE.\n")
for line in difflib.unified_diff(lj.splitlines(), rj.splitlines(),
                                 "live release", "roles/cilium", lineterm=""):
    print("  " + line)
sys.exit(1)
PY
