# Runbook: UPS pull-the-plug test (supervised)

> **Status (2026-09-25):** current as a procedure. The first drill ran on
> 2026-07-19 (shutdown passed, battery kept) and the re-drill of the retuned
> configuration passed on 2026-07-29.

A supervised test that proves the NUT shutdown story end to end on real
battery, measures true runtime after the 2026-07-06 deep discharge, and decides
whether the ST625U battery is replaced. The first run was paired with a
rack-maintenance window: the lab had to go down anyway, so the plug was pulled
instead of running the orchestrator by hand.

- Companion: [`ups-shutdown.md`](ups-shutdown.md) (design, deploy, tuning)
- Script under test: [`scripts/nut-lab-shutdown.sh`](../../scripts/nut-lab-shutdown.sh),
  deployed as `/usr/local/sbin/nut-lab-shutdown.sh` on pve-4

---

## Results of the first drill (2026-07-19)

Shutdown **passed**; battery **kept**. The configuration was retuned from these
measurements (see [Re-drill](#re-drill-proving-the-2026-07-19-retune)).

| Measurement | Value |
|---|---|
| Load on battery | 59 % ≈ 221 W of 375 W |
| `battery.runtime` at 100 % charge | 425 s (525 s after the test, at 57 % load) |
| LB fired | T0+40 s, via `battery.runtime.low = 300`; charge still ~92 % |
| Reported runtime on battery | collapsed to R0 ≈ 340 s almost at once, then decayed ~1 s/s |
| pve-4 began its own halt | T0+65 s, 10 s after dispatch |
| Netclient nodes dark | spread from T0+81 s to T0+190 s (~110 s), against a nominal 45 s guest cap |
| Time spent in guest shutdown | ~135 s against the 45 s nominal cap (`pct` had no explicit timeout) |
| Cascade duration | 170 s, 74 % of the battery budget |
| All dark | T0+210 s |
| `killpower` | unsupported: `/etc/killpower` absent, UPS stayed energised |
| Measured margin | not available: no 2 s `upsc` log was kept |

Findings on the way back up: four of the Dell nodes needed power-button
presses, pve-4 came back off the network (a cabling fault, fixed the same
day), and Proxmox reported `storage 'truenas' is not online` with PBS
unreachable. The OPNsense `opnsense-shell` dispatch trap (below and in
[`ups-shutdown.md`](ups-shutdown.md)) was also verified and fixed that day.

**Timing reality:** the LB trigger is `battery.runtime.low`, *not*
`battery.charge.low`. The drain phase before LB is well under a minute at this
load, not tens of minutes. The retuned configuration projects all-dark at
≈ T0+132 s. Budget ~20 min for the whole exercise including recovery.

---

## What this test proves

| Claim | How the test proves it |
|---|---|
| LB trigger fires at the configured threshold | `override.battery.runtime.low = 330`: watch `ups.status` flip `OL`→`OB`→`LB` (`charge.low` is inert at this load and was removed 2026-07-19) |
| Alerts survive the outage | ntfy pushes for ONBATT / LOWBATT / FSD land on the phone, all **page**-tier since 2026-09-14 (pve-4 pushes *out* to ntfy.sh, so it works while the lab dies) |
| Cross-VLAN clients get the message | pve-2 (cluster VLAN) and pve-5 (sandbox VLAN) power off even though OPNsense drops mid-sequence; this is why the orchestrator SSH-dispatches them *before* the router |
| Ordering is dependency-safe | pve-4 (TrueNAS/PBS/tier VMs) is last down |
| It fits in the battery | LB → all-dark measured against remaining runtime, with margin |
| Battery health | runtime at the measured load vs. what a healthy ST625U gives |

Two questions the drill also answers, worth recording either way:

- **Does `shutdown.return` cut and restore the outlets?** (`killpower` itself
  was answered on 2026-07-19: unsupported on the ST625U.) The orchestrator
  issues `shutdown.return` before pve-4 halts (`offdelay` 120 s). If the
  outlets never drop, that is a finding, not a failure: record it and fall
  back to Wake-on-LAN as the recovery path.
- **Does anything hang on NFS when the TrueNAS pool goes away?** On
  2026-07-19 pve-4 started halting ~10 s after the other nodes began their
  guest shutdowns, while their guests were still on storage NFS-mounted from
  TrueNAS. pve-4 now waits for its same-subnet peers to go dark (90 s cap).
  Watch for a node that is still up long after the others.

---

## Pre-flight (do all of this before touching the plug)

1. **Backups current.** Confirm the last PBS run succeeded and nothing is
   mid-flight. This is a graceful shutdown, but do it before an untested
   cascade.

2. **Baseline the UPS.** Write these numbers down; they are half the
   deliverable:

   ```bash
   ssh root@198.51.100.14 'upsc st625u | grep -E "battery.charge|battery.runtime|ups.load|ups.status|battery.date|ups.mfr"'
   ```

3. **All five nodes are actually monitoring.** A netclient that silently
   dropped its upsd connection is the failure mode this test exists to catch:

   ```bash
   # pve-3, pve-1, pve-2, pve-5
   for h in 198.51.100.13 198.51.100.11 192.0.2.5 203.0.113.15; do
     echo -n "$h: "; ssh root@$h 'upsc st625u@198.51.100.14 ups.status' 2>&1
   done
   ssh root@198.51.100.14 'systemctl is-active nut-server nut-monitor'
   ```

   All should read `OL`.

4. **Dispatch dry run.** Do not use a bare `ssh … true` reachability check:
   SSH returning 0 does **not** mean the remote command ran (see the
   opnsense-shell note in `ups-shutdown.md`). Use the real dispatch form with
   a harmless command, then check in a second pass that it actually executed:

   ```bash
   ssh root@198.51.100.14 'for ph in admin@198.51.100.55 root@198.51.100.1 \
       root@192.0.2.5 root@203.0.113.15 root@198.51.100.13 root@198.51.100.11; do \
     ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$ph" \
       "/bin/sh -c '\''nohup touch /tmp/nut-dispatch-probe >/dev/null 2>&1 &'\''" \
       </dev/null >/dev/null 2>&1 && echo "$ph: dispatched" || echo "$ph: WARN unreachable"; done'

   # second pass: did it RUN?
   ssh root@198.51.100.14 'for ph in admin@198.51.100.55 root@198.51.100.1 \
       root@192.0.2.5 root@203.0.113.15 root@198.51.100.13 root@198.51.100.11; do \
     r=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ph" \
       "/bin/sh -c '\''ls /tmp/nut-dispatch-probe >/dev/null 2>&1 && echo RAN || echo DID-NOT-RUN'\''" \
       2>/dev/null | tr -d "\r" | tail -1); echo "$ph: $r"; done'
   ```

   Clean up afterwards (`rm -f /tmp/nut-dispatch-probe` via the same form).
   Anything but `RAN` → fix it before testing, or you are validating a
   sequence with a hole in it.

5. **Workstation config present?**

   ```bash
   ssh root@198.51.100.14 'cat /etc/nut/lab-shutdown.conf'
   ```

   It should carry the workstation's pinned IP and SSH user, and
   `WORKSTATION_METHOD=osascript`. An empty `WORKSTATION_HOST` is skipped
   safely; in that case shut the workstation down by hand and note that the
   leg went untested.

   **Confirm the workstation is logged in before you start**, or the
   osascript leg fails:

   ```bash
   ssh root@198.51.100.14 'ssh <user>@<workstation-ip> "stat -f%Su /dev/console"'
   # must print the logged-in user, not root/_windowserver (= sitting at the login window)
   ```

6. **Alerting is armed:**

   ```bash
   ssh root@198.51.100.14 'NOTIFYTYPE=ONBATT /usr/local/sbin/nut-notify.sh'
   ```

   Confirm the push lands on the phone before you rely on it.

7. **Pick an observation post that is NOT on the UPS and NOT behind
   OPNsense.** Once the router goes, so does the network; you cannot watch
   this from a laptop on lab Wi-Fi. Practical options, in order:
   - a phone on cellular, watching the ntfy topic (the primary timeline);
   - a physical console/monitor on pve-4 for the last 30 s;
   - phone video of the rack LEDs: cheap, and it timestamps every power-off.

8. **Pick a stopwatch method.** The network dies mid-cascade, so *durable*
   timing comes from the phone, the 2 s log on pve-4 and the post-boot
   journals, not from a live SSH session. Record wall-clock time at each event
   below.

---

## The test

> Announce first. At the measured load, LB arrives within about a minute of
> pulling the plug, and the cascade then takes ~2–3 min.

**T0: pull the UPS from the wall.**

Expect within seconds: `ups.status` → `OB`, and an **ONBATT** push. Record T0.

**Drain phase.** For a live view while the router is still up, from the
observation post:

```bash
ssh root@198.51.100.14 'while :; do date +%T; \
  upsc st625u 2>/dev/null | grep -E "ups.status|battery.charge|battery.runtime"; \
  sleep 10; done' | tee ~/pullplug-$(date +%F).log
```

**T1: `LB` appears.** Expect a **LOWBATT** push, then **FSD**, then upsmon on
pve-4 execs `nut-lab-shutdown.sh`. Record T1 and the reported
`battery.runtime` at that moment; the whole margin calculation hangs on it.

**Cascade: watch the order.** Expected, per the script:

1. workstation + Raspberry Pi (parallel)
2. Proxmox netclients: pve-1, pve-2, pve-3, pve-5 (guests off, then poweroff)
3. OPNsense router, ~10 s after dispatch (`ROUTER_GRACE`)
4. pve-4 waits for pve-1 and pve-3 to go dark (90 s cap), issues
   `shutdown.return`
5. **pve-4 last:** its guests (TrueNAS/PBS/tier VMs), then halt

Your SSH session dies at step 3. From there it is LEDs, fan noise and the
video. Record T2 = router dark, T3 = **last device dark** (should be pve-4).

**T4: does the UPS cut output?** The orchestrator issues `shutdown.return`
*before* it starts stopping pve-4's own guests, logging
`UPS shutdown.return confirmed`. The outlets should drop **~120 s
(`offdelay`) after that log line's timestamp**, i.e. shortly after pve-4 goes
dark, since pve-4's halt runs inside the countdown. Define T4 relative to the
log timestamp (read it after boot from `journalctl -b -1 -t nut-lab-shutdown`),
not relative to T3: keying it to T3 would hide an unexpectedly slow pve-4
halt. If you are doing rack work rather than the short-outage test, **switch
the UPS off** first regardless.

Then do the maintenance.

---

## Recovery

1. Restore mains, UPS on.
2. **Expect unattended recovery: do NOT touch power buttons for at least
   5 minutes.** BIOS "power on after AC loss" is set on all five nodes
   (confirmed 2026-07-19) and the orchestrator issues `shutdown.return`, so
   the outlets should cycle and every host should boot with no hands. A manual
   button press here falsely records the recovery leg as passed.
   (On 2026-07-12 nothing auto-booted, because BIOS AC recovery was unset;
   fixed 2026-07-19.)
3. **Failure fallback only:** if unattended recovery has clearly not started
   after 5 minutes, power on by hand in dependency order: **OPNsense → pve-4
   (TrueNAS/PBS) → pve-1, pve-2, pve-3, pve-5**. Give pve-4 time to bring the
   storage pool up before the others mount it. Record which nodes needed
   buttons.
   - **The workstation needs a manual FileVault unlock.** It halts at the
     pre-boot unlock screen with no network. Until it is unlocked and logged
     in, **its shutdown leg will not work on the next outage**; check that
     `stat -f%Su /dev/console` prints the logged-in user before you call the
     lab recovered.
4. Guests have `onboot=1`; verify they actually returned.
5. Post-boot verification:

   ```bash
   ssh root@198.51.100.14 'upsc st625u | grep -E "ups.status|battery.charge|battery.runtime"'
   ssh root@198.51.100.14 'journalctl -b -1 -t nut-lab-shutdown --no-pager'   # the cascade log
   for h in 198.51.100.13 198.51.100.11 192.0.2.5 203.0.113.15; do
     echo "== $h"; ssh root@$h 'journalctl -b -1 -u nut-monitor --no-pager | tail -20'
   done
   ```

   The `-b -1` journals are the authoritative record of what happened after
   the network died; this is where the ordering claim is actually verified.
6. Confirm an **ONLINE** push arrived and that the battery recharges to 100 %.
7. k3s-v2: nodes `Ready`, no stuck volumes.

---

## Record the result

Fill this in and keep it with the drill date:

```
UPS pull-plug test — <date>
  Baseline:   charge __%  runtime __s  load __%  battery.date ____
  T0 plug pulled        __:__:__   (ONBATT push: Y/N)
  T1 LB / FSD           __:__:__   runtime remaining __s   (LOWBATT+FSD push: Y/N)
  T2 router dark        __:__:__
  T3 last device dark   __:__:__   (which device: ____)
  Cascade duration (T1→T3): __ min __ s
  Margin, MEASURED from /var/tmp/ups-drill.log (not inferred): __ s  = __ x
    (runtime remaining at T3 ÷ cascade duration; must be >= 2.0)
  pve-4 peer-wait: "all peers dark after __s" / "WARN still up at cap"
  UPS output cut via shutdown.return: Y/N at __:__:__
    (expected ~120 s after the "shutdown.return confirmed" journal timestamp;
     killpower itself: N — known, ST625U does not support it)
  Order correct (pve-4 last): Y/N     Anything hung: ____
  Workstation shut down cleanly: Y/N   (osascript leg)
  SHORT-OUTAGE TEST — mains restored at __:__:__ with charge __%
    Lab returned unattended within 5 min: Y/N
    If N: which nodes needed buttons: ____
  All hosts+guests returned: Y/N   pve-4 reachable on the network: Y/N
  TrueNAS + PBS up before dependents: Y/N
  Workstation unlocked + logged in after recovery: Y/N
  Verdict: PASS / TUNE / FAIL
  Battery decision: keep / replace  (reason: ____)
```

### Acceptance

- Cascade completes **inside** the runtime remaining at T1 with **≥ 50 %
  margin** (i.e. runtime at T1 ≥ 2× cascade duration).
- Order verified: pve-4 last, no host left stranded.
- ONBATT / LOWBATT / FSD pushes all received.
- Runtime and the battery keep/replace decision recorded.

### If it's tight or it fails

- **Margin thin** → in priority order: (a) get load off the UPS: the
  workstation and laptop do not need battery outlets, and load dominates
  runtime; (b) shorten the cascade (guest timeouts, now 20 s); (c) raise
  `override.battery.runtime.low`, but only to ~330; see the tuning-knob notes
  in `ups-shutdown.md` for why ≥340 is unsafe and why `charge.low` does
  nothing.
- **Not `override.battery.charge.low`.** An earlier version of this runbook
  recommended raising it to 60. That is a **no-op** at this load: the
  2026-07-19 test showed charge still ~92 % when LB fired.
- **Guest shutdown dominates the time** → lower the `--timeout` in
  `nut-host-shutdown.sh` (45 → 20 on 2026-07-19); k3s VMs tolerate a hard
  stop.
- **A cross-VLAN node was still up when the router died** → increase
  `ROUTER_GRACE` in `/etc/nut/lab-shutdown.conf` (costs battery; trade it off
  against margin).
- **Runtime far below expectations at this load** → the 17-hour deep
  discharge damaged the battery. Replace it, then re-run this test.

---

## Re-drill: proving the 2026-07-19 retune

The first run passed on shutdown but changed three things blind and produced
no measurable margin. This section is the delta for the re-drill (run
2026-07-29); everything above still applies.

**What changed since the first run:** `override.battery.runtime.low = 330`
(replacing the inert `charge.low`), guest timeouts 45 → 20 with an explicit
`pct --timeout`, pve-4 waiting for the same-subnet peers to go dark (90 s cap)
before halting, and `shutdown.return` issued just before pve-4 halts.

**What did NOT change:** load. The workstation and laptop stayed on the
battery outlets (decided 2026-07-19), so the UPS stays at ~221 W of 375 W.
Margin rests entirely on the threshold and cascade retune; there is no second
lever if this comes back tight. Projected all-dark ≈ T0+132 s against
425–525 s of capacity leaves ~290–390 s unused, which should clear the 2× bar,
but that is a projection and the drill is what turns it into a measurement.

### Pre-flight (in addition to the main pre-flight above)

1. **Deploy the retune, then verify it landed on the boxes.** The first run
   was nearly invalidated by a config that had been committed but never
   applied.

   ```bash
   cd ansible
   ansible-playbook -i inventory/hosts.yml playbooks/ups-nut.yml \
     -e @nut-vars.yml
   ```

   The vars file (kept outside the repository) must carry
   `nut_monitor_password`, `nut_ntfy_topic`, `nut_ntfy_topic_status` and
   `nut_instcmd_password` (the `labshut` credential, which renders
   `upsd.users` and `/etc/nut/labshut.pass`). The playbook refuses to run
   without both ntfy topics.

   ```bash
   ssh root@198.51.100.14 'upsc st625u battery.runtime.low'        # -> 330
   ssh root@198.51.100.14 'grep -c PEER_WAIT /usr/local/sbin/nut-lab-shutdown.sh'
   ssh root@198.51.100.14 'grep SHUTDOWNCMD /etc/nut/upsmon.conf'  # -> nut-lab-shutdown.sh
   for h in 198.51.100.13 198.51.100.11 192.0.2.5 203.0.113.15; do
     ssh root@$h 'grep -o -- "--timeout [0-9]*" /usr/local/sbin/nut-host-shutdown.sh'
   done                                                            # -> 20, twice per host
   ```

2. **Confirm `pct shutdown --timeout` exists** on this Proxmox version:
   `ssh root@198.51.100.13 'pct shutdown --help'`. It is documented, but it
   was added to the helper without being exercised. If absent, drop the flag
   rather than letting every LXC leg fail at shutdown time.

3. **Load-off command (answered 2026-07-29): `shutdown.return` is supported
   and wired in.** `upscmd -l st625u` lists `shutdown.return` (load off,
   auto-return when mains restores). It is issued at the tail of
   `nut-lab-shutdown.sh` just before pve-4 halts (tracked via `upscmd -w`,
   confirmed only on a `SUCCESS` result), with `offdelay = 120` /
   `ondelay = 180` in `ups.conf`. It runs as the dedicated **`labshut`**
   account, allowed exactly `shutdown.return` + `beeper.enable` (the latter
   only as a harmless auth probe). Its password exists only on pve-4, in two
   root-protected files (`/etc/nut/labshut.pass` 0600 and rendered into
   `/etc/nut/upsd.users` 0640). Do NOT grant instcmds to `upsmon`: that
   password is distributed to every netclient, which would make it a
   fleet-wide power-cut credential. Verify it is in place:

   ```bash
   ssh root@198.51.100.14 'upsc st625u ups.delay.shutdown; upsc st625u ups.delay.start'
   # -> 120 / 180 (offdelay/ondelay live in the DRIVER: the playbook's
   #    "restart nut driver" handler applies them; if these read 20/30 after a
   #    deploy, restart nut-driver@st625u and check the handler fired)
   ssh root@198.51.100.14 'grep -c shutdown.return /usr/local/sbin/nut-lab-shutdown.sh'
   # -> >= 1
   ssh root@198.51.100.14 'upscmd -w -u labshut -p "$(cat /etc/nut/labshut.pass)" st625u beeper.enable'
   # -> SUCCESS (proves auth + tracking without touching the load)
   ```

4. **Start a 2 s logger on pve-4**, the single most important addition:

   ```bash
   ssh root@198.51.100.14 'nohup sh -c "while :; do
       echo \"\$(date +%T) \$(upsc st625u 2>/dev/null | grep -E \"ups.status|battery.charge|battery.runtime|ups.load\" | tr \"\n\" \" \")\"
       sleep 2
     done" >>/var/tmp/ups-drill.log 2>&1 &'
   ssh root@198.51.100.14 'sleep 5; tail -3 /var/tmp/ups-drill.log'   # confirm rows
   ```

   It runs on **pve-4**, not the Pi: pve-4 owns the USB link, so `upsc` is a
   local call needing no network, and it halts last, so the log spans the
   whole event. Read `/var/tmp/ups-drill.log` after pve-4 comes back.

### Extra step during the drill

**Test the short-outage recovery path.** The long-outage path (battery
empties, UPS drops, mains returns, AC recovery boots everything) is the
*easy* case and is not what bites. Once the last node is dark and you have
confirmed it, **plug the UPS back in while the battery still has charge** and
start a stopwatch. Then do nothing for 5 minutes.

- If the lab comes back on its own, `shutdown.return` works and the missing
  `killpower` no longer matters.
- If nothing boots, `shutdown.return` failed in practice: check pve-4's
  `journalctl -b -1 -t nut-lab-shutdown` for the "confirmed" / "NOT
  confirmed" line, and whether the outlets ever dropped. Record it, recover by
  hand, and fall back to Wake-on-LAN as the remote-recovery path.

This is also the only clean way to prove pve-3 and pve-5 auto-boot, since
their OptiPlex 7090 BIOS does not expose `AcPwrRcvry` to the OS; behaviour is
the only evidence available for those two.

### Acceptance: all seven, or it does not pass

1. Cascade completes with **zero** `WARN could not reach`, order correct
   (pve-4 last).
2. **Measured** margin ≥ 2×: runtime remaining at all-dark ≥ cascade
   duration, computed from `/var/tmp/ups-drill.log`, not inferred from the
   threshold. This is the criterion the first run could not satisfy.
3. pve-4's syslog shows `all same-subnet peers dark after Ns` and **not** the
   `WARN peers still up at cap` line; node dark-times cluster rather than
   spreading across ~110 s as they did on 2026-07-19.
4. All five Proxmox nodes auto-boot unattended after power is restored.
5. pve-4 returns **on the network** unattended (proves the 2026-07-19
   cabling fix).
6. TrueNAS and PBS are up before dependent nodes need them (the first run
   came back with `storage 'truenas' is not online` and PBS unreachable).
7. ntfy pushes received for ONBATT, LOWBATT and FSD.

> Criteria 4–6 were **first-time proofs, not re-confirmations**: before the
> re-drill the lab had never been observed returning from a power event
> unattended.

---

## Known limitations

- **`killpower` is unsupported on the ST625U.** A permanent hardware
  limitation; `shutdown.return` is the replacement.
- **Workstation FileVault.** Accepted cost: after any power event the
  workstation needs a manual unlock before its shutdown leg works again.
- **Wake-on-LAN** remains the fallback remote-recovery path if
  `shutdown.return` ever stops cycling the outlets.
- The drill exercises **ntfy only**; the optional Telegram push is not part
  of it.
