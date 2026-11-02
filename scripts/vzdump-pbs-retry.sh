#!/usr/bin/env bash
# Retry the PBS backup window on this node if it did not land.
#
# WHY THIS EXISTS
# ---------------
# pve-2 is the only PVE node whose management address lives on the cluster VLAN
# (192.0.2.5), so its backup traffic to PBS at 198.51.100.51 crosses the
# router at 192.0.2.1. Since the .97 datastore came into use on 2026-07-05:
#
#     pve-1 (same L2)   0 failures / 63 runs
#     pve-3 (same L2)   1 failure  / 61 runs   (1.6%)
#     pve-2 (routed)    8 failures / 62 runs   (12.9%)
#
# Every failure is `could not activate storage 'pbs': ... Can't connect to
# 198.51.100.51:8007`, raised at storage activation — before any guest is
# touched, so one dropped connect kills the whole job for every VMID in it.
# On 07-22 02:30, 07-23 02:30 and 07-25 22:30 the other two nodes completed
# against that same PBS in the same minute, so PBS was up and the fault is on
# the path. The underlying cause is NOT fixed by this script and pve-3's single
# failure shows the routed path is an amplifier, not the whole story.
#
# WHY ONLY THE 02:30 WINDOW
# -------------------------
# The PBS job runs `2,22:30`, so the windows are 4h apart one way and 20h the
# other. A 22:30 miss is retried by the 02:30 job on its own. A 02:30 miss
# opens a 20h hole — and 6 of the 8 failures were 02:30. One run at 04:30
# closes the gap that actually matters.
#
# WHAT IT CHECKS
# --------------
# Not "did the task report OK" — whether a backup for each in-scope guest
# actually exists in PBS and is newer than MAX_AGE_HOURS. A task status is a
# claim; a snapshot is evidence.
#
# Read-only unless a backup is genuinely missing. Safe to run any time.

set -euo pipefail

export STORAGE="${STORAGE:-pbs}"   # exported: the perl block below reads $ENV{STORAGE}
MAX_AGE_HOURS="${MAX_AGE_HOURS:-4}"
STATE_DIR="${STATE_DIR:-/var/lib/vzdump-pbs-retry}"
STATE_FILE="$STATE_DIR/last-run"
DRY_RUN="${DRY_RUN:-0}"
NODE="$(hostname)"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

record() {
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$STATE_FILE" >/dev/null
}

# Only one of these at a time, and never on top of a running backup window.
exec 9>"/run/vzdump-pbs-retry.lock"
if ! flock -n 9; then
  log "another retry run holds the lock; exiting"
  exit 0
fi

if pgrep -f '/usr/sbin/vzdump' >/dev/null 2>&1; then
  log "a vzdump is still running; the window has not finished. Exiting without action."
  record "SKIP vzdump still running"
  exit 0
fi

# --- scope: the guests this node owns that the PBS job is supposed to cover ---
# Read from the live job definition rather than a hardcoded list, so a guest
# that migrates or leaves the job does not silently fall out of the retry.
job_vmids="$(pvesh get /cluster/backup --output-format json 2>/dev/null | perl -MJSON::PP -0777 -ne '
  my $j = decode_json($_);
  my @v;
  for my $job (@$j) {
    next unless ($job->{type} // "") eq "vzdump";
    next unless ($job->{storage} // "") eq $ENV{STORAGE};
    next unless ($job->{enabled} // 0);
    push @v, split(/,/, $job->{vmid} // "");
  }
  my %seen; print join(" ", grep { !$seen{$_}++ } @v);
')"

if [[ -z "$job_vmids" ]]; then
  log "ERROR: no enabled vzdump job targets storage '$STORAGE'; nothing to verify"
  record "ERROR no enabled job for storage $STORAGE"
  exit 1
fi

local_vmids=""
for d in "/etc/pve/nodes/$NODE/qemu-server" "/etc/pve/nodes/$NODE/lxc"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*.conf; do
    [[ -e "$f" ]] || continue
    local_vmids+=" $(basename "$f" .conf)"
  done
done

scope=""
for v in $job_vmids; do
  for l in $local_vmids; do
    [[ "$v" == "$l" ]] && scope+=" $v"
  done
done
scope="$(tr ' ' '\n' <<<"$scope" | sed '/^$/d' | sort -n | tr '\n' ' ')"

if [[ -z "${scope// /}" ]]; then
  log "no guests on $NODE are in the '$STORAGE' job; nothing to do"
  record "OK no in-scope guests"
  exit 0
fi
log "in scope on $NODE: $scope"

# --- precondition: is the storage reachable at all? ---
# If it is not, a retry would fail exactly the way the window did. Say so
# loudly (systemd marks the unit failed) rather than burning a vzdump run.
if ! pvesm status --storage "$STORAGE" 2>/dev/null | awk 'NR>1 {print $3}' | grep -q active; then
  log "ERROR: storage '$STORAGE' is not active right now — retry would fail the same way"
  record "FAIL storage $STORAGE unreachable at retry time"
  exit 1
fi

# --- evidence: newest snapshot per guest ---
now=$(date +%s)
cutoff=$(( now - MAX_AGE_HOURS * 3600 ))
stale=""

for v in $scope; do
  newest=$(pvesm list "$STORAGE" --vmid "$v" 2>/dev/null \
           | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
           | sort | tail -1)
  if [[ -z "$newest" ]]; then
    log "  $v — NO backup in $STORAGE at all"
    stale+=",$v"
    continue
  fi
  epoch=$(date -u -d "$newest" +%s)
  age_h=$(( (now - epoch) / 3600 ))
  if (( epoch < cutoff )); then
    log "  $v — STALE: newest is $newest (${age_h}h old, limit ${MAX_AGE_HOURS}h)"
    stale+=",$v"
  else
    log "  $v — ok: $newest (${age_h}h old)"
  fi
done

stale="${stale#,}"

if [[ -z "$stale" ]]; then
  log "window landed for every in-scope guest; no retry needed"
  record "OK window landed ($scope)"
  exit 0
fi

# --- retry, with the same options the scheduled job uses ---
log "RETRYING vzdump for: $stale"
record "RETRY triggered for $stale"

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1 — would run: vzdump $stale --storage $STORAGE --mode snapshot --fleecing 0 --notes-template '{{guestname}}' --notification-mode notification-system"
  exit 0
fi

if vzdump "$stale" \
     --storage "$STORAGE" \
     --mode snapshot \
     --fleecing 0 \
     --notes-template '{{guestname}}' \
     --notification-mode notification-system; then
  log "retry succeeded for $stale"
  record "PASS retry succeeded for $stale"
  exit 0
else
  rc=$?
  log "retry FAILED for $stale (exit $rc) — the 20h gap is still open"
  record "FAIL retry failed for $stale (exit $rc)"
  exit 1
fi
