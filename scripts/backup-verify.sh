#!/usr/bin/env bash
# Verify that Proxmox Backup Server actually holds a recent backup for every
# guest the backup job claims to cover.
#
# PBS primary runs as a VM (198.51.100.51) on pve-4, datastore on the `tank` pool
# via NFS. A secondary (pbs2, 198.51.100.52 on pve-3) pulls a nightly
# sync copy (ADR 0004 and ADR 0005 in the private repository).
#
# 2026-07-27 REWRITE. The previous version pointed at the retired PBS on the
# old TrueNAS box, listed a guest inventory that predates the
# k3s v2 rebuild, and — more importantly — did not verify anything: it printed
# a checklist and asked the operator to go look in the UI. A verification that
# depends on somebody remembering is a verification that does not happen.
#
# It now asserts two things, and fails loudly on either:
#
#   1. Every VMID in the enabled PBS vzdump job has a snapshot in the datastore
#      newer than MAX_AGE_HOURS. Snapshot existence is evidence; a task that
#      reported OK is only a claim.
#   2. The most recent vzdump task on every node exited OK. This is the check
#      whose absence let pve-2 fail 8 backup windows unnoticed between 07-11 and
#      07-25 — PVE raised each one to `mail-to-root`, which nobody reads.
#
# Read-only. Safe to run any time, any number of times.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PBS_HOST="${PBS_HOST:-198.51.100.51}"
PBS_PORT="${PBS_PORT:-8007}"
PBS_DATASTORE="${PBS_DATASTORE:-pbs-datastore}"
STORAGE="${STORAGE:-pbs}"

# The PBS job runs `2,22:30`, so the longest healthy gap is 20h plus the run
# itself. 26h flags a genuinely missed window without crying over a slow night.
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"

# Any cluster member works — the PVE API proxies /nodes/<other> queries. pve-1
# is the default because it sits on the LAN alongside PBS.
QUERY_NODE="${QUERY_NODE:-198.51.100.11}"

failures=0
fail()  { echo -e "  ${RED}FAIL${NC}  $*"; failures=$((failures + 1)); }
pass()  { echo -e "  ${GREEN}ok${NC}    $*"; }
warn()  { echo -e "  ${YELLOW}warn${NC}  $*"; }

echo "========================================="
echo "  Backup Verification — $(date)"
echo "  PBS ${PBS_HOST}:${PBS_PORT}  datastore ${PBS_DATASTORE}"
echo "========================================="
echo

# --- is PBS even up ---------------------------------------------------------
echo "--- PBS reachability ---"
if ! curl -sk --connect-timeout 5 "https://${PBS_HOST}:${PBS_PORT}" >/dev/null 2>&1; then
  fail "cannot reach PBS at ${PBS_HOST}:${PBS_PORT}"
  echo
  echo "Nothing further can be verified. Check the PBS VM on pve-4 and the tank NFS mount."
  exit 1
fi
pass "PBS answering at https://${PBS_HOST}:${PBS_PORT}"
echo

rsh() { ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${QUERY_NODE}" "$@" 2>/dev/null; }

if ! rsh true; then
  echo -e "${RED}ERROR: cannot ssh to the query node root@${QUERY_NODE}${NC}"
  exit 1
fi

# --- what is the job supposed to cover -------------------------------------
# Read the live job definition rather than a hardcoded inventory, so a guest
# added, removed or migrated cannot silently fall out of the expected set.
expected="$(rsh "pvesh get /cluster/backup --output-format json" | STORAGE="$STORAGE" perl -MJSON::PP -0777 -ne '
  my $j = decode_json($_); my @v;
  for my $job (@$j) {
    next unless ($job->{type} // "") eq "vzdump";
    next unless ($job->{storage} // "") eq $ENV{STORAGE};
    next unless ($job->{enabled} // 0);
    push @v, split(/,/, $job->{vmid} // "");
  }
  my %seen; print join(" ", sort { $a <=> $b } grep { !$seen{$_}++ } @v);
')"

if [[ -z "$expected" ]]; then
  echo -e "${RED}ERROR: no enabled vzdump job targets storage '${STORAGE}'${NC}"
  exit 1
fi

echo "--- Backup freshness (limit ${MAX_AGE_HOURS}h) ---"
echo "  expected guests: $(wc -w <<<"$expected" | tr -d ' ') from the enabled '${STORAGE}' job"
echo

# One listing for the whole datastore beats one API round-trip per guest.
listing="$(rsh "pvesm list ${STORAGE}")"
now=$(date +%s)

for v in $expected; do
  newest=$(grep -E "^${STORAGE}:backup/(vm|ct)/${v}/" <<<"$listing" \
           | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
           | sort | tail -1)
  if [[ -z "$newest" ]]; then
    fail "$v — NO backup in ${STORAGE} at all"
    continue
  fi
  # PBS stamps snapshots in UTC; -u keeps the comparison honest.
  epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$newest" +%s 2>/dev/null \
       || date -u -d "$newest" +%s)
  age_h=$(( (now - epoch) / 3600 ))
  if (( age_h > MAX_AGE_HOURS )); then
    fail "$v — newest backup is ${age_h}h old ($newest)"
  else
    pass "$v — ${age_h}h old ($newest)"
  fi
done
echo

# --- did the last window actually succeed on each node ----------------------
echo "--- Last vzdump task per node ---"
nodes="$(rsh "pvesh get /cluster/resources --type node --output-format json" \
        | perl -MJSON::PP -0777 -ne 'my $j=decode_json($_); print join(" ", map { $_->{node} } @$j);')"

for n in $nodes; do
  row="$(rsh "pvesh get /nodes/${n}/tasks --typefilter vzdump --limit 1 --output-format json" \
        | perl -MJSON::PP -0777 -ne '
            my $t = eval { decode_json($_) } || [];
            if (@$t) { printf "%s|%s", $t->[0]{starttime} // 0, $t->[0]{status} // "running"; }
          ')"
  if [[ -z "$row" ]]; then
    warn "$n — no vzdump task history (node down, or it runs no backup job)"
    continue
  fi
  when=$(date -r "${row%%|*}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo unknown)
  status="${row##*|}"
  if [[ "$status" == "OK" ]]; then
    pass "$n — $when  $status"
  else
    fail "$n — $when  $status"
  fi
done

echo
echo "========================================="
if (( failures == 0 )); then
  echo -e "${GREEN}PASS${NC} — every expected guest has a backup within ${MAX_AGE_HOURS}h and the last window succeeded on every node."
  exit 0
fi
echo -e "${RED}FAIL${NC} — ${failures} problem(s) above."
echo "If a node shows a failed task but its guests are fresh, the window recovered"
echo "on a later run; see scripts/vzdump-pbs-retry.sh for the pve-2 retry path."
exit 1
