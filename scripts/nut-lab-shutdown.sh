#!/bin/sh
# nut-lab-shutdown.sh — orchestrated, dependency-safe shutdown of the whole lab.
#
# Runs on the NUT MASTER (pve-4, 198.51.100.14) as upsmon's SHUTDOWNCMD. When the
# CyberPower ST625U hits the low-battery trigger, upsmon sets FSD (all NUT
# netclients begin self-shutdown via their own upsmon) and then execs this
# script on the master. This script's job is to bring down the devices that are
# NOT NUT-managed (Raspberry Pi, OPNsense, workstation) plus belt-and-suspenders
# the Proxmox netclients, in an order that respects the lab's dependencies, then
# power off pve-4 itself LAST.
#
# SAFE ORDER (why):
#   1. Leaf devices first — workstation, Raspberry Pi. Nothing depends on them.
#   2. Proxmox netclients — each runs its own nut-host-shutdown.sh (guests off,
#      then poweroff). The cross-VLAN ones (pve-2 on the cluster VLAN, pve-5 on the sandbox VLAN)
#      are only reachable from pve-4 THROUGH OPNsense, so they must be dispatched
#      while the router is still up.
#   3. OPNsense router — only after every cross-VLAN SSH has been dispatched;
#      once it is down, the cluster VLAN and the sandbox VLAN subnets are unreachable from
#      pve-4.
#   4. pve-4 itself LAST — it hosts TrueNAS (tank), PBS, and the tier VMs that the
#      rest of the lab mounts/depends on, so it waits for the same-subnet peers
#      to go dark (bounded) before halting. Just before its own halt it issues
#      `upscmd shutdown.return` (step 3c): the UPS cuts its outlets after
#      `offdelay` and re-energises them when mains returns, so the whole lab
#      gets the AC transition its BIOS auto-power settings need. This replaces
#      killpower, which does NOT work on the ST625U — verified by the
#      2026-07-19 test (/etc/killpower absent, UPS stayed energised); the
#      POWERDOWNFLAG is harmless but buys nothing.
#
# Every remote action is best-effort and time-bounded: a hung or already-down
# host can never stall the sequence (the battery is draining). Failures are
# logged and the sequence continues.
#
# Config lives inline below and can be overridden by /etc/nut/lab-shutdown.conf
# (same variable names). That is where the workstation details belong: they
# are host-specific and stay out of the repository.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# ---------------------------------------------------------------------------
# Configuration (override in /etc/nut/lab-shutdown.conf)
# ---------------------------------------------------------------------------

# Proxmox netclients. Same-subnet hosts (reachable directly from pve-4) and
# cross-VLAN hosts (reachable only through OPNsense — must go before the router).
PVE_SSH_USER="${PVE_SSH_USER:-root}"
PVE_SAME_SUBNET="${PVE_SAME_SUBNET:-198.51.100.13 198.51.100.11}"      # pve-3, pve-1
PVE_CROSS_VLAN="${PVE_CROSS_VLAN:-192.0.2.5 203.0.113.15}"      # pve-2 (cluster VLAN), pve-5 (sandbox VLAN)
# Helper already deployed on every Proxmox node by ups-nut.yml.
PVE_HELPER="${PVE_HELPER:-/usr/local/sbin/nut-host-shutdown.sh}"

# Raspberry Pi 5 (independent Docker host, same LAN). The SSH user needs
# passwordless sudo for shutdown, e.g. in visudo:
#   admin ALL=(root) NOPASSWD: /sbin/shutdown
RPI_HOST="${RPI_HOST:-198.51.100.55}"
RPI_USER="${RPI_USER:-admin}"

# OPNsense router (FreeBSD). Key-only root SSH; key must be added via the web UI
# (System > Access > Users > root > Authorized keys) so it survives config apply.
OPNSENSE_HOST="${OPNSENSE_HOST:-198.51.100.1}"
OPNSENSE_USER="${OPNSENSE_USER:-root}"

# macOS workstation (idle desktop on the LAN). NOT set by default — fill these
# in /etc/nut/lab-shutdown.conf on pve-4. Leave WORKSTATION_HOST empty to skip
# it safely.
#   WORKSTATION_METHOD=osascript : `osascript ... shut down` (no sudo; needs a
#                                  logged-in GUI session + Remote Login
#                                  enabled). Preferred.
#   WORKSTATION_METHOD=sudo      : `sudo /sbin/shutdown -h now` (needs
#                                  passwordless sudo for shutdown; works
#                                  headless).
WORKSTATION_HOST="${WORKSTATION_HOST:-}"
WORKSTATION_USER="${WORKSTATION_USER:-}"
WORKSTATION_METHOD="${WORKSTATION_METHOD:-osascript}"

# SSH behaviour. Short connect timeout so unreachable hosts fail fast; identity
# is root's default key on pve-4 unless SSH_KEY is set.
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
SSH_KEY="${SSH_KEY:-}"
# Grace after dispatching guest shutdowns before we drop the router / pve-4. Keep
# it short — this whole script runs on battery. Tune with the pull-plug test.
ROUTER_GRACE="${ROUTER_GRACE:-10}"

# After the router is down, pve-4 waits for the same-subnet Proxmox peers to
# actually go dark before halting itself — it serves their NFS storage (see
# step 3b). Hard cap: the battery is draining, so pve-4 halts regardless once
# PEER_WAIT_MAX is reached. 90 s comfortably covers the 20 s guest timeout plus
# host teardown, and still fits the budget.
PEER_WAIT_MAX="${PEER_WAIT_MAX:-90}"
PEER_WAIT_POLL="${PEER_WAIT_POLL:-3}"

# Optional heads-up push before the network dies (uses the NUT notifier if set).
NOTIFY_CMD="${NOTIFY_CMD:-/usr/local/sbin/nut-notify.sh}"

# Load overrides last so the conf file wins over the defaults above.
# shellcheck source=/dev/null
[ -f /etc/nut/lab-shutdown.conf ] && . /etc/nut/lab-shutdown.conf

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { logger -t nut-lab-shutdown "$*" 2>/dev/null; echo "nut-lab-shutdown: $*" >&2; }

ssh_opts() {
  printf '%s' "-o BatchMode=yes -o StrictHostKeyChecking=accept-new \
-o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o ServerAliveInterval=2 \
-o ServerAliveCountMax=2"
  [ -n "$SSH_KEY" ] && printf ' -i %s' "$SSH_KEY"
}

# remote_poweroff USER HOST LABEL REMOTE_CMD
# Fire-and-forget: the remote command is detached so the box powers off on its
# own and the SSH call returns immediately (bounded by ConnectTimeout).
remote_poweroff() {
  _user=$1; _host=$2; _label=$3; _cmd=$4
  [ -z "$_host" ] && { log "skip $_label (no host configured)"; return 0; }
  log "-> $_label ($_user@$_host)"
  # Wrap in an explicit /bin/sh rather than letting the LOGIN shell parse the
  # command: OPNsense's root shell is the opnsense-shell console menu, which
  # silently fails on a top-level `nohup … &` (verified 2026-07-19 — rc=1, the
  # command never ran, and best-effort dispatch made it look like a WARN we
  # could ignore). /bin/sh exists on every target here, so this form is
  # universal. $_cmd must not contain single quotes.
  # SC2046/SC2029: word-splitting ssh_opts and expanding $_cmd on this side
  # are both intended. SC2015: `log` cannot meaningfully fail, so the
  # A && B || C form is safe here.
  # shellcheck disable=SC2046,SC2029,SC2015
  ssh $(ssh_opts) "$_user@$_host" "/bin/sh -c 'nohup $_cmd >/dev/null 2>&1 &'" \
    </dev/null >/dev/null 2>&1 \
    && log "   dispatched $_label" \
    || log "   WARN could not reach $_label (continuing)"
}

# ---------------------------------------------------------------------------
# Sequence
# ---------------------------------------------------------------------------

log "=== lab shutdown initiated on $(hostname) — UPS low battery ==="

# 0. Best-effort push while the WAN is still routable (router is still up here).
[ -x "$NOTIFY_CMD" ] && NOTIFYTYPE=SHUTDOWN "$NOTIFY_CMD" >/dev/null 2>&1 &

# 1. Leaf devices — workstation + Raspberry Pi (parallel, nothing depends on them).
if [ -n "$WORKSTATION_HOST" ]; then
  case "$WORKSTATION_METHOD" in
    sudo) remote_poweroff "$WORKSTATION_USER" "$WORKSTATION_HOST" "workstation" \
            "sudo /sbin/shutdown -h now" & ;;
    *)    remote_poweroff "$WORKSTATION_USER" "$WORKSTATION_HOST" "workstation" \
            'osascript -e "tell application \"System Events\" to shut down"' & ;;
  esac
else
  log "skip workstation (WORKSTATION_HOST unset in /etc/nut/lab-shutdown.conf)"
fi
remote_poweroff "$RPI_USER" "$RPI_HOST" "Raspberry Pi" \
  "sudo /sbin/shutdown -h now" &

# 2. Proxmox netclients — dispatch guest shutdown + poweroff on each. The
#    cross-VLAN hosts go now, while OPNsense is still routing. (They also
#    self-shut via their own upsmon; this is a redundant, idempotent fallback.)
for h in $PVE_CROSS_VLAN $PVE_SAME_SUBNET; do
  remote_poweroff "$PVE_SSH_USER" "$h" "Proxmox $h" "$PVE_HELPER" &
done

# Wait for all dispatch SSH calls to return (each bounded by ConnectTimeout).
wait

# 3. Brief grace so in-flight guest shutdowns get going, then drop the router.
log "grace ${ROUTER_GRACE}s before powering off the router"
sleep "$ROUTER_GRACE"
remote_poweroff "$OPNSENSE_USER" "$OPNSENSE_HOST" "OPNsense router" \
  "shutdown -p now"

# 3b. Wait for the same-subnet Proxmox peers to actually go dark before pve-4
#     starts halting. WHY (2026-07-19 pull-plug test): pve-4 began its own halt at
#     T0+65 s — 10 s after dispatch — while pve-3/pve-1/pve-2/pve-5 were still
#     inside their guest shutdowns on storage NFS-mounted from TrueNAS, which is
#     a GUEST OF pve-4. Pulling tank out from under them mid-shutdown is the most
#     likely cause of the long tail (nodes dark from +81 s all the way to
#     +190 s, against a nominal 45 s cap). A fixed ROUTER_GRACE cannot express
#     "they are done"; this can.
#
#     Only the same-subnet peers are observable here — once OPNsense is down,
#     pve-2 (cluster VLAN) and pve-5 (sandbox VLAN) are unreachable from pve-4 by design, so
#     unreachable is treated as dark. The cap is hard: the battery is draining
#     and pve-4 must halt regardless. Exceeding it is a finding, not a reason to
#     wait longer.
log "waiting up to ${PEER_WAIT_MAX}s for same-subnet peers to go dark"
_waited=0
while [ "$_waited" -lt "$PEER_WAIT_MAX" ]; do
  _alive=""
  for h in $PVE_SAME_SUBNET; do
    ping -c 1 -W 1 "$h" >/dev/null 2>&1 && _alive="$_alive $h"
  done
  [ -z "$_alive" ] && { log "   all same-subnet peers dark after ${_waited}s"; break; }
  sleep "$PEER_WAIT_POLL"
  _waited=$((_waited + PEER_WAIT_POLL))
done
[ -n "$_alive" ] && log "   WARN peers still up at cap (${PEER_WAIT_MAX}s):$_alive — halting anyway"

# 3c. Tell the UPS to drop its outlets and re-energise when mains returns.
#     `shutdown.return` is supported by the ST625U (upscmd -l, 2026-07-29) and
#     closes the short-outage recovery gap: without it the outlets stay
#     energised after the lab halts, so mains returning produces no AC
#     transition and nothing auto-boots (the confirmed 2026-07-12 failure
#     mode — five power buttons by hand). The load drops `offdelay` seconds
#     after this command (ups.conf: 120 s), which must outlive pve-4's own halt
#     below; the countdown runs in the UPS, so pve-4 halting does not cancel it.
#     Best-effort: a failure here only means recovery needs hands, not that
#     the shutdown is unsafe.
UPS_NAME="${UPS_NAME:-st625u}"
# Dedicated instcmd-only account (NOT upsmon — that password is distributed
# to every netclient; this one exists only on pve-4, root-readable).
# ACCEPTED RESIDUAL (security review 2026-07-29): upscmd 2.8.1 offers no
# non-argv auth path (-h shows only -u/-p), so the password is visible in
# /proc cmdline while the call runs — roughly 10 s (-t) plus connection/auth
# time, mid power-loss cascade. Acceptance ASSUMES pve-4 has no untrusted local
# users and its process table is not remotely readable; the credential is
# scoped to shutdown.return (rack-wide power cycle, still destructive) plus
# a beeper no-op. Revisit if NUT grows a nutauth.conf-style option or pve-4
# ever gains untrusted local users.
NUT_USER="${NUT_USER:-labshut}"
NUT_PASS_FILE="${NUT_PASS_FILE:-/etc/nut/labshut.pass}"
NUT_PASS=$(cat "$NUT_PASS_FILE" 2>/dev/null)
if [ -n "$NUT_PASS" ]; then
  # -w -t 10: wait for the driver's tracked result. Neither a zero exit nor
  # output containing SUCCESS is enough on its own: upscmd exits 0 even when
  # the tracked result is "ERR …" (only a timeout is nonzero), a plain
  # untracked OK only means upsd accepted the submission, and a substring
  # match would confirm e.g. "UNSUCCESSFUL". Confirmed means rc==0 AND the
  # final output line is exactly SUCCESS (the tracked result goes to stderr,
  # captured here; earlier lines may be driver/SSL chatter). Anything else is
  # logged verbatim as unconfirmed.
  _out=$(upscmd -w -t 10 -u "$NUT_USER" -p "$NUT_PASS" "$UPS_NAME" shutdown.return 2>&1)
  _rc=$?
  _last=$(printf '%s\n' "$_out" | tail -n 1)
  if [ "$_rc" -eq 0 ] && [ "$_last" = "SUCCESS" ]; then
    log "UPS shutdown.return confirmed [$_out] — outlets drop in ~offdelay, auto-return on mains"
  else
    log "WARN shutdown.return NOT confirmed [rc=$_rc: $_out] — UPS may stay energised; short-outage recovery needs hands"
  fi
else
  log "WARN $NUT_PASS_FILE unreadable — skipping shutdown.return"
fi

# 4. pve-4 itself LAST — stop its guests (TrueNAS/PBS/tier VMs), then halt.
log "powering off this node (pve-4) last"
if [ -x "$PVE_HELPER" ]; then
  exec "$PVE_HELPER"
else
  log "WARN $PVE_HELPER missing — falling back to plain poweroff"
  exec /sbin/shutdown -h +0
fi
