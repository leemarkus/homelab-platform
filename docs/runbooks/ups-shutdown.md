# Runbook: UPS safe shutdown (CyberPower ST625U + NUT)

> **Status (2026-09-25):** current. The lab-wide shutdown cascade passed its
> supervised re-drill on 2026-07-29 (see [`ups-pull-plug-test.md`](ups-pull-plug-test.md)).

Automated, graceful shutdown of the whole lab when the UPS runs low on
battery, so a power event never again drops the k3s clusters uncleanly (the
2026-07-06 outage did exactly that).

- Playbook: [`ansible/playbooks/ups-nut.yml`](../../ansible/playbooks/ups-nut.yml)
- Orchestrator: [`scripts/nut-lab-shutdown.sh`](../../scripts/nut-lab-shutdown.sh)
- Drill procedure and results: [`ups-pull-plug-test.md`](ups-pull-plug-test.md)

## Hardware and topology

- **UPS:** CyberPower ST625U: 625 VA / **375 W**, standby (offline) topology,
  USB HID. 8 outlets: **4 battery+surge, 4 surge-only**.
- **On the UPS:** all five Proxmox nodes (pve-1, pve-2, pve-3, pve-4, pve-5),
  the workstation (idle) and a laptop, on one extension plugged into the
  battery outlets.
- **Load: ~221 W of 375 W (59 %)**, measured 2026-07-19. Up sharply from the
  ~124–135 W (33–36 %) read on 2026-07-10. **`battery.runtime` at 100 % charge
  is 425 s (~7.1 min)**, not the ~19 min previously documented.
- **The LB trigger is `battery.runtime.low`, not `battery.charge.low`.** It is
  set to **330** (`charge.low` was removed on 2026-07-19 as inert: charge was
  still ~92 % when LB fired). The projected "~125 s of drain before LB" was
  wrong: LB actually fired at **T0+40 s** with `runtime.low = 300`, because
  reported runtime collapses to ~340 s the instant the load moves to battery.
  At 330 it should fire ~10 s in. The whole cascade must fit in what remains;
  see [Tuning knobs](#tuning-knobs).
- **Data:** the UPS USB cable goes into **pve-4 (198.51.100.14)**, the NUT
  **master**. pve-1, pve-2, pve-3 and pve-5 are **netclients**. pve-4 shuts
  down **last** because it hosts TrueNAS, PBS and the tier VMs the others
  depend on.
- **Not NUT clients:** the Raspberry Pi 5, the OPNsense router and the
  workstation. The orchestrator on pve-4 shuts them down over SSH. The laptop
  has its own battery and is left alone.

```
ST625U ──USB──> pve-4 (NUT master / netserver, upsd on :3493) ── shuts down LAST
   │                  ▲        ▲        ▲           ▲
   └─power ext──────> │        │        │           │  (netclients poll upsd)
   (5 nodes +       pve-3    pve-1    pve-2       pve-5
    workstation,
    laptop)
```

## Why NUT still works on one extension

NUT reads the **UPS** over USB (battery %, on-battery, runtime). It does not
care how power is distributed downstream. One extension on a battery outlet is
a normal single-UPS setup. The only hard requirement is that the extension is
on a **battery** outlet, not a surge-only one or the wall.

## Prerequisites

1. **USB cable on pve-4.** Verify on pve-4: `lsusb | grep -i 0764`
   (CyberPower).
2. **Reachability to `pve-4:3493`:** pve-1 and pve-3 share pve-4's subnet;
   pve-2 (cluster VLAN) routes to 198.51.100.14 the same way it reaches TrueNAS
   (198.51.100.50). **pve-5 (sandbox VLAN) is isolated by design**, so it
   needs a narrow OPNsense rule:
   - Firewall → Rules → **OPT1 (sandbox VLAN)**: pass, proto TCP, source
     `203.0.113.15`, dest `198.51.100.14`, dest port `3493`. Without it, run
     the playbook with `--limit 'pve-1,pve-2,pve-3,pve-4'`.
3. **Secrets:** a 0600 vars file kept outside the repository (`nut-vars.yml`)
   must carry `nut_monitor_password`, `nut_ntfy_topic`,
   `nut_ntfy_topic_status` and `nut_instcmd_password` (the `labshut` instcmd
   credential, required since 2026-07-29). The playbook asserts both ntfy
   topics are present before it writes `notify.env`: a run without
   `nut_ntfy_topic` would otherwise wipe the topic and silently kill outage
   alerting.

   **Key renamed 2026-09-14:** `nut_ntfy_topic_notify` →
   `nut_ntfy_topic_status`, and its value is now the **status** topic (the
   middle notification tier was retired). Rename the key in the vars file; a
   run with the old key fails at the assert.

## Deploy

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/ups-nut.yml \
  -e @nut-vars.yml
# to skip pve-5 for any reason, add: --limit 'pve-1,pve-2,pve-3,pve-4'
```

Verify the driver bound and the clients connected:

```bash
ssh root@198.51.100.14 'upsc st625u'                 # battery.charge, ups.status OL
ssh root@198.51.100.13 'upsc st625u@198.51.100.14'   # a client (pve-3) can read it
ssh root@198.51.100.14 'upsc st625u ups.status'      # OL = online, OB = on battery
ssh root@198.51.100.14 'grep SHUTDOWNCMD /etc/nut/upsmon.conf'   # -> nut-lab-shutdown.sh
```

## Orchestrated lab shutdown (Pi, OPNsense, workstation)

The Proxmox nodes self-shut via their own `upsmon` slave, but the **Raspberry
Pi, OPNsense router and workstation are not NUT clients**. To cover them, the
master's `SHUTDOWNCMD` on pve-4 is `/usr/local/sbin/nut-lab-shutdown.sh`
(source: [`scripts/nut-lab-shutdown.sh`](../../scripts/nut-lab-shutdown.sh),
deployed by `ups-nut.yml`). When the UPS hits LB, upsmon sets FSD and execs it
on pve-4. It powers everything off in a **dependency-safe order**:

1. **Leaf devices:** workstation and Raspberry Pi, in parallel; nothing
   depends on them.
2. **Proxmox netclients:** dispatches `nut-host-shutdown.sh` on each (guests
   off, then poweroff). The cross-VLAN hosts (pve-2 on the cluster VLAN, pve-5 on
   the sandbox VLAN) go **while OPNsense is still routing**, because pve-4 can only
   reach them through the router. Redundant with their own upsmon, and
   idempotent.
3. **OPNsense router** (`shutdown -p now`), after a short `ROUTER_GRACE`
   (10 s) and only after the cross-VLAN dispatches. Once it is down, the
   the cluster VLAN and the sandbox VLAN subnets are unreachable from pve-4.
4. **pve-4 waits for its same-subnet peers** (pve-1, pve-3) to stop answering
   ping, capped at `PEER_WAIT_MAX` (90 s). They run guests on storage
   NFS-mounted from TrueNAS, which is a guest of pve-4, so pulling it away
   mid-shutdown stalls them.
5. **`upscmd shutdown.return`** as the dedicated `labshut` account: the UPS
   drops its outlets `offdelay` (120 s) later and re-energises them when mains
   returns, giving every host the AC transition its BIOS "power on after AC
   loss" setting needs. `killpower` does not work on the ST625U (the UPS stayed
   energised in the 2026-07-19 test), so this replaces it.
6. **pve-4 itself last:** stops TrueNAS/PBS/tier VMs, then halts.

Every remote call is best-effort and time-bounded (`ConnectTimeout=5`, remote
poweroff detached), so a hung or already-down host never stalls the sequence.

> **Best-effort means failures are quiet.** A target that cannot be reached
> logs `WARN could not reach <label> (continuing)` and the cascade moves on,
> so a broken leg looks like a successful shutdown unless you read the
> journal. This happened once: OPNsense's root login shell is the
> `opnsense-shell` console menu, which **silently refuses** a top-level
> `nohup … &` (verified 2026-07-19: rc=1, the command never ran). Every
> dispatch is therefore wrapped in an explicit `/bin/sh -c '…'`, which works
> on all targets. `$_cmd` must not contain single quotes. When adding a
> target, verify it **ran** the command, not just that SSH returned 0.

### Prerequisites (one-time, on pve-4)

1. **root SSH key from pve-4 to each target** (BatchMode, no password
   prompt). Verified 2026-07-19 by having each target actually *execute* a
   dispatched command, not merely accept the connection:
   - **Proxmox nodes:** root keys are already trusted between cluster members.
   - **Raspberry Pi:** add pve-4's root key to the Pi's SSH user (`admin` in
     the examples below). That user needs passwordless sudo for
     `/sbin/shutdown`.
   - **OPNsense:** add pve-4's root key through the web UI (System > Access >
     Users > root > **Authorized keys**). Keys written only to `~/.ssh` are
     wiped on config apply; the durable store is the `authorizedkeys` field
     in `/conf/config.xml`.
   - **Workstation (macOS):** enable Remote Login, install pve-4's key, and
     confirm `osascript` can drive System Events over SSH (the automation
     permission prompt must have been accepted once).
     - A shutdown target on **Wi-Fi** is a weak link: one access-point hiccup
       during an outage and the leg fails quietly. Prefer a wired connection.
     - **`WORKSTATION_METHOD=osascript` is the method that works here.** The
       `sudo` alternative needs passwordless sudo; with a password,
       `BatchMode=yes` turns the prompt into an instant failure. osascript
       needs a **logged-in GUI session**; see the FileVault note below.
2. **Workstation config:** set the real values on pve-4 in
   `/etc/nut/lab-shutdown.conf` (created by the playbook with
   `force: false`, never committed), or pass them at deploy time
   (`-e nut_workstation_host=… -e nut_workstation_user=…`):

   ```
   WORKSTATION_HOST=198.51.100.x    # pinned by a DHCP reservation
   WORKSTATION_USER=admin
   WORKSTATION_METHOD=osascript
   ```

   An empty `WORKSTATION_HOST` is skipped safely. Keep it a **literal IP,
   never a hostname**: pve-4 resolves DNS via the Pi (198.51.100.55), and the
   orchestrator shuts the Pi down in the same step it dispatches the
   workstation, so a hostname would race its own nameserver. If the
   workstation has more than one interface, reserve the same address for each.

   > **FileVault makes the workstation leg single-use.** With FileVault on and
   > no auto-login, the workstation boots to the pre-boot unlock screen after
   > any power event and stops there, before macOS starts: no sshd, no
   > network, no GUI session. The shutdown works once; the **next** outage
   > finds it unreachable, the orchestrator logs a WARN and moves on, and the
   > workstation keeps drawing battery. Unlock and log in after every outage,
   > or treat this leg as needing manual recovery. Do not restart a headless
   > workstation remotely: it goes dark until a display and keyboard are
   > attached.

### Dry run: check the dispatch path

Verify the dispatch reaches every target without shutting anything down. A
bare `ssh … true` is not enough (see the opnsense-shell note above); the
pull-plug runbook has the two-pass form that proves the command actually ran:
[Pre-flight, step 4](ups-pull-plug-test.md#pre-flight-do-all-of-this-before-touching-the-plug).

Quick reachability check from pve-4:

```bash
# Pi = admin, OPNsense/Proxmox = root
ssh root@198.51.100.14 'for ph in admin@198.51.100.55 root@198.51.100.1 \
    root@192.0.2.5 root@203.0.113.15; do \
  ssh -o BatchMode=yes -o ConnectTimeout=5 $ph true \
    && echo "$ph: OK" || echo "$ph: UNREACHABLE"; done'
```

Then run the full cascade under the supervised
[pull-the-plug test](ups-pull-plug-test.md), so the order
(leaf → clients → router → pve-4) is timed against the real runtime.

## Reading the current power draw

Read the live load from the UPS (the ST625U reports percent load; multiply by
the 375 W rating for watts):

```bash
ssh root@198.51.100.14 'upsc st625u ups.realpower 2>/dev/null || \
  awk "BEGIN{print $(upsc st625u ups.load)/100*375\" W (from ups.load %)\"}"'
ssh root@198.51.100.14 'upsc st625u | grep -E "ups.load|battery.charge|battery.runtime"'
```

At this load the estimated runtime is short (about 7 minutes at full charge),
and that number drives the low-battery threshold below.

## The pull-the-plug test (supervised)

> **Step-by-step procedure and recorded results:
> [`ups-pull-plug-test.md`](ups-pull-plug-test.md)**: pre-flight checks,
> timing sheet, recovery order, acceptance criteria. The summary below is the
> design intent; that runbook is what you execute.

First run 2026-07-19 (shutdown passed, battery kept); re-drill 2026-07-29.

1. `upsc st625u`: note `battery.charge` (100 %?) and `battery.runtime` (s).
2. Announce, then **pull the UPS from the wall**. Watch `ups.status` flip to
   `OB`, then `LB` at the low threshold.
3. Confirm the cascade: netclients power off first, **pve-4** last (it waits
   for the same-subnet peers to go dark, then runs the guest-shutdown helper).
4. **Time it, and log the curve.** Poll `upsc st625u` every 2 s into a file on
   **pve-4**: it owns the USB link, so `upsc` needs no network, and it halts
   last, so the log spans the whole event. Without this you get a pass/fail
   but no measured margin (the 2026-07-19 test's margin could not be
   reconstructed afterwards for exactly this reason).
5. Restore power and confirm all hosts and VMs auto-boot (they have
   `onboot=1`).

## Tuning knobs

Ordered by how much margin they actually buy. The thresholds are the
*weakest* lever.

1. **UPS load:** 221 W of 375 W (59 %) as of 2026-07-19, up from ~130 W, and
   runtime fell from ~19 min to ~7 min. The laptop has its own battery and the
   workstation needs a manual FileVault unlock after any power event
   regardless, so moving both to **surge-only** outlets costs nothing and
   roughly doubles runtime.
2. **Cascade duration:** 74 % of the budget. Guest timeout in
   `nut-host-shutdown.sh` is `--timeout 20` (was 45; `pct` is now bounded
   too); k3s VMs tolerate a hard stop. `PEER_WAIT_MAX` (90 s) caps pve-4's
   wait.
3. **`override.battery.runtime.low`** in `/etc/nut/ups.conf` on pve-4: the
   *actual* LB trigger. Its usable range is only 300 (fires at +40 s) to ~340
   (fires at the first poll), because reported runtime collapses to
   R0 ≈ 340 s the moment the load goes to battery. Set to **330**. Do not set
   ≥340: a 5 s grid blip would shut down the whole lab.
4. **`override.battery.charge.low`:** **inert at this load; do not re-add.**
   At LB the charge was still ~92 %; it would not reach 50–60 % until
   ~170–200 s in, long after the runtime trigger. Raising it reads like a fix
   and does nothing.

Battery health: **keep** (2026-07-19): 525 s at 57 % load, better than before
the test. The deep-discharge damage suspected after the 17-hour drain on
2026-07-06 is not real.

## Alerting (ntfy)

On-battery, low-battery, online and comms events push to a phone via
**ntfy**. Only the **master (pve-4)** notifies, so each event pushes once, via
NUT's `NOTIFYCMD`:

- Script: `/usr/local/sbin/nut-notify.sh` (deployed by the playbook).
- Targets: `/etc/nut/notify.env` (root:nut 0640, because upsmon runs
  `NOTIFYCMD` as the `nut` user). It holds two ntfy topics plus an optional
  Telegram token and chat id; the values come from the vars file kept outside
  the repository.
- **Two tiers since 2026-09-14:** `NTFY_TOPIC` is the **page** topic and
  carries **ONBATT / LOWBATT / FSD / SHUTDOWN**: mains power gone is act-now
  on a ~7 minute runtime. `NTFY_TOPIC_STATUS` is the muted status topic and
  carries **ONLINE / REPLBATT / COMMBAD / COMMOK**, the after-the-fact half.
  NUT posts to both directly, not through Alertmanager.
- `NOTIFYFLAG`s on pve-4 include **`EXEC`** for ONLINE/ONBATT/LOWBATT/FSD/
  SHUTDOWN/REPLBATT/COMMBAD/COMMOK (netclients stay `SYSLOG+WALL` only).
- **Why public ntfy.sh, not self-hosted:** an outage alert must survive the
  lab losing power. pve-4 is the last node down and pushes out to ntfy.sh, so
  the message actually lands; a self-hosted ntfy would already be dark.

Test without pulling the plug (sends a real push):

```bash
ssh root@198.51.100.14 'NOTIFYTYPE=ONBATT /usr/local/sbin/nut-notify.sh'
curl -s "https://ntfy.sh/<topic>/json?poll=1&since=2m"   # confirm receipt
```

**Telegram (optional):** `nut-notify.sh` also posts to Telegram's
`sendMessage` API when `nut_telegram_token` and `nut_telegram_chatid` are
supplied. Left unset, that leg stays off.

The **page** topic also carries **k3s-v2 cluster criticals** (node down, cert
expiry, disk, etc.) via Alertmanager and an in-cluster ntfy bridge;
non-critical cluster alerts appear on the status board instead. Cluster alerts
only fire while the cluster is up; power and outage alerts come from NUT on
pve-4, independent of the cluster.

## Health check

`upsc st625u ups.status` should read `OL` normally. `OB` = on battery,
`LB` = low battery (shutdown imminent), `RB` = replace battery.
