# #280 Stop treating `/tmp` as trusted IPC: decision state moves to a root-only run directory

Status: **design v2.1** — v1 REJECT; v2 APPROVE-WITH-CHANGES; §9 makes the changes binding · 2026-10-08 · Refs #280 #265 #261 #209 #91

## 0. Reality check (2026-10-08, 02/03/04 on 1.5.6-wsl.1; full inventory on #280)

**Filesystem layout**
- `/tmp` is a 1777 tmpfs, and `/var` is a symlink to `tmp`.
- **`/tmp/run` is root 0755.** procd creates it (`initd/early.c`); `/var/run` resolves to it.
- `/tmp/lock` (= `/var/lock`) is 1777.

**sysctls**
- `protected_symlinks=1` and `protected_hardlinks=1`: both set by OpenWrt's `/etc/sysctl.d/10-default.conf`.
- `protected_regular=0` and `protected_fifos=0`.

**Non-root processes on the host**
- dnsmasq, logd, network (hostapd/wpa_supplicant), nobody (gpsd/avahi), ntp.
- **ubus starts in procd's STATE_UBUS, which is before S10 uci-defaults.** The claim "nothing non-root runs before the uci-defaults" is therefore false.
- The OTS containers (uid 1000/999) do not bind the host `/tmp`.

**Verified on 03, as `nobody` via `start-stop-daemon -S -c nobody -n tmptrust280 -a /bin/sh`:**
- `touch /tmp/x` succeeds.
- `mkdir /var/run/x` fails with Permission denied.

**sysupgrade stage 2** (`lib/upgrade/stage2`)
- `/tmp` **is carried across** `supivot`. Our `platform-ab.sh:159` relies on that: it reads `/tmp/batdata.dev`.
- **`/var` in the ramfs is a real, fresh directory**: `mkdir -p $RAM_ROOT/var/lock`.
- **So a path spelled `/var/run/...` is not the same path in stage 2.**

**batpower**
- The shipped default is `source 'mock'` with `crit_action halt`. All three nodes run it.
- It reads `/tmp/batpower.mock` with no owner check. Any non-root process can halt a node.

**Other unprotected patterns**
- `$$` and timestamp names are predictable.
- `mkdir -p /tmp/<predictable>`: an attacker creates the directory first, so it belongs to them. Because that directory is not sticky, protected_symlinks does not apply inside it. Root then writes through planted symlinks, which lets the attacker clobber arbitrary files.
  - Examples: `www/cgi-bin/bundle`, `canary.$$` (its contents feed `docker import`), `bm-p7`, `95-p5.$$`, `slotchk.$$`.
- **The harness runs root-executed payloads out of predictable `/tmp` names on the node:**
  - `daily-validation.sh:597-600` (`.ko` + script, `insmod` / `sh`) and `:627`;
  - `node/soak-node.sh` (`cat > /tmp/dv-*.sh; sh`), `node/container-lifecycle.sh`, `node/dockerd-restart.sh`, `node/p5-onjoin-263.sh`;
  - docs: `golden-image.md:95`, `cloning-a-node.md:47,147`.

## 1. Threat model and goal

**Actor:** a non-root process on the node:
- a compromised host daemon such as dnsmasq, avahi, hostapd, ntpd or ubus;
- or a container that escaped into a non-root uid.

Root is out of scope, because root already owns the node.

**Goal:** this actor cannot change any of the following:
- commit or revert;
- which slot or partition boots;
- whether the node reboots or halts;
- a health verdict that gates commit;
- what is written to boot sectors or applied to UCI;
- **what root executes or `insmod`s.**

**Remaining capability (§6):**
- bounded delay or DoS;
- faking display-only text that is never used for a decision.

## 2. Design

### D1 Run directory: literally `/tmp/run/batman`, never spelled through `/var`
- `/tmp/run` is root 0755 (procd), so a non-root process cannot create anything in it.
- Spelling it `/tmp/run/...` means **stage 2 sees the same directory**: `/tmp` crosses `supivot` (review B1).
- Helper `usr/lib/batman/rundir.sh` (`RUNDIR=${BATMAN_RUNDIR:-/tmp/run/batman}`; the override exists for `tests/ab-card-invariants.sh`, which runs 95 on the WSL host):
  - **`batman_rundir`**
    1. Parent check: `/tmp/run` must be `-d`, `! -L`, owned by root, and not group- or other-writable.
    2. `mkdir -m 700 "$RUNDIR"` if it is missing.
    3. Verify: `-d`, `! -L`, `-O`, and `ls -ld` shows `drwx------` (busybox has no `stat`).
    4. On success it returns rc 0. On failure it logs, returns rc 1, and the caller fails closed (§3).
  - **`batman_tmp [-d]`:** `mktemp [-d] "$RUNDIR/t.XXXXXX"`. This replaces every `$$`, timestamp and `mkdir -p /tmp/<name>` path.
  - **Guarded source:** `[ -r /usr/lib/batman/rundir.sh ] && . /usr/lib/batman/rundir.sh || <fail closed>`. In ash, a `.` of a missing file aborts the script, so the guard is required.
- **Stage 2 support** (`platform-ab.sh`):
  - Add `rundir.sh` to `RAMFS_COPY_DATA` and `/bin/mktemp` to `RAMFS_COPY_BIN`.
  - Proof: on both boards, the stage-2 trace shows `S2 BEGIN p6trace=yes` together with the new `batdata.dev` path (§7).
- **Distribution:**
  - The `deploy/provisioning` copy goes into the `check-provisioning-sync.sh` pairs and into the `depersonalise.sh` install.
  - `batman-payload-host` gets a DEPENDS on `batman-provision`, which installs the helper.

### D2 What moves into `$RUNDIR` (classes A–C, plus everything root executes or writes)

Basenames stay **unchanged**, so the harness can resolve the directory (D4).

**autocommit**
- `decided`, `committed`, `run/`, `wd`, `hold-consumed`, `deadline`, `start`, `canary-ok`, `why`, `hold-discarded`, `ctl/`, `ctl.dry/`, `dryrun.log`.
- Temp files: `canary.*`, `p5.*`.

**slot / firmware**
- `batman-fw-override`, `-pending`, `batman-reboot.want`, `batman-slot.lock/`, `batman-slot.busy`.
- Temp files: `mbr.*` and `batfw.*`.
- `slotchk.*`; `p7` read-back.

**platform-ab**
- `batdata.dev`, `p6t/`, `s2-p1/`, `ab-check.*`, `ab-exclude`, `ab-payload`.
- The `case "$RUNDIR/p6t/"*` in `batman-slot:412-413` follows the move.

**storage / uci-defaults**
- `95-mbr.*`, `95-p5.*`, `bm-p7`, `batman-storage.crit`, `batdata-mount.booted`, `p5-restored`, `overrides.*`, `p5-chanfix.*`.

**power**
- `batpower.state`, `shutdown.reason`, the mock input (D3).

**payload**
- `PAYLOAD_RUNDIR` defaults to `$RUNDIR`. This covers lock, pid, stopping and stop0.
- `firstload-<t>.latch`, `-drift.json`, `-restarts.state`, `-verify.log`, `-resources.log`, `.converging`.
- `batman-ots-pause` (p6 `reconcile-resources.sh`, plus its operator doc).

**joinwatch / config-save**
- `config-saved`, `joinwatch.state`, `cfgsave-*`.

**cgi bundle**
- The report directory comes from `batman_tmp -d`, no longer `rm -rf; mkdir -p /tmp/<host>-report-<ts>` (review M2).

**Operator interfaces that stay in `/tmp`, checked**
- `batman-autocommit.hold`, `batman-fault.*`, `batman-slot.allow-*`.
- The reader requires `-f`, `! -L`, `-O`, **and link count 1** (`ls -ln` field 2), so a hardlink to a root-owned file is refused even if `protected_hardlinks` is ever 0 (review M6).
- A file that fails these checks is logged and shown by halow-status as `TAMPER: <path> not root-owned` — not silently ignored.

### D3 batpower: no production read from a writable path
- **Default `none`, in both places** (review m8):
  - the generated config;
  - the binary's own fallback: `cfg source none`.
- Read dispatch: `hwmon` / `i2c` / `mock` are explicit; anything else is `none`, which means `UNKNOWN` and no action.
- `mock` reads `$RUNDIR/batpower.mock`, which only root can write.
  - It is honoured only with `option mock_ok '1'`, so bench use stays possible.
- Migration rewrite of an existing `mock` config to `none`: kept for the non-A/B golden nodes; it does nothing on A/B nodes, because the overlay is fresh after every flash.
- **Rollback to an old slot brings back the old behaviour.** This is documented.
- `batpower.state` consumers: halow-status, batman-slot and flightrec all run as root. The EMS collector (#65) does not exist yet. Its future reader must run as root or read through halow-status JSON.

### D4 Harness: version-tolerant, and no root execution from predictable `/tmp`
- **Resolve the directory per node (review M5):** `R=/tmp/run/batman; [ -d "$R" ] || R=/tmp`. Basenames are identical, so one variable serves pre-#280 and post-#280 nodes. Applied in:
  - `daily-validation.sh` 288, 462, 637, 640, 1221;
  - `fault-injection.sh` 191, 195, 209, 210, 225, 246, 278;
  - `node/p5-onjoin-263.sh`;
  - `depersonalise.sh`.
- **Staging (review M1):** every copy-then-execute on the node becomes
  `d=$(ssh node 'mktemp -d')`, then scp into `$d`, then run from `$d`, then `rm -rf $d`.
  - Applies to `daily-validation.sh` 597-600 and 627, and to `node/soak-node.sh`, `node/container-lifecycle.sh`, `node/dockerd-restart.sh`, `node/p5-onjoin-263.sh`.
  - The docs `golden-image.md` and `cloning-a-node.md` say: scp the image into a `mktemp -d` directory, not to `/tmp/<name>`.

### D5 Defence in depth
- New `/etc/sysctl.d/90-batman.conf`: pins `protected_symlinks=1` and `protected_hardlinks=1`, and sets `protected_regular=2` and `protected_fifos=2`.
- **Before enabling `protected_regular=2` (review m7):**
  - Every remaining `/tmp` write must have its exit status checked. A refused `>` must not leave attacker content behind, and the static check enforces this for the allowlisted writers.
  - The restart paths must be exercised: dnsmasq restart, network/wifi reload, opkg, sysupgrade, luci, and openmanetd.
- **openmanetd** uses `dbFile: /tmp/openmanetd.db` (`depersonalise.sh:179`, golden images only): a root SQLite file in `/tmp`. It moves to `$RUNDIR`, or golden images are declared out of scope (decided in implementation, and recorded).
- **If any restart path breaks under `protected_regular=2`, D5 ships with only the symlink and hardlink pins**, and the gap is recorded on #280. D1–D4 are the actual fix; D5 is only defence in depth.

### D6 Regression guards
**Static CI check `scripts/check-tmp-trust.sh`** (review M3)
- **Scope:** `feed/**`, every `deploy/**` file that lands on a node (including `deploy/ots/*`), `scripts/node/**`, and the remote snippets in `scripts/*.sh` (strings passed to ssh).
- **Patterns:**
  - `/tmp\b`, `/var/(tmp|lock)\b`, `\$\{[A-Z_]*:-/tmp`;
  - `$$`, `$(date` or `$(cut -c… /proc/sys/kernel/random/boot_id)` inside a path;
  - `mkdir -p /tmp/`;
  - `tar -C /tmp`;
  - `df -k /tmp` is allowed as a read.
- Every hit must match an allowlist line `path-regex <TAB> reason`. The allowlist covers display-only paths (`meshled.*`, `bat-hosts`) and the checked operator interfaces. For the operator interfaces, the checker also verifies the reader has `! -L`, `-O` and the link-count test.
- **Mutation proofs, one per bypass form:**
  - a literal `/tmp/autocommit.decided`;
  - a `${X:-/tmp}` default;
  - a `$$` path;
  - `mkdir -p /tmp/x`;
  - an operator interface missing `-O`.
  - Each must make the check FAIL.

**Runtime `tmp-trust-280` (daily-validation, every fleet node) — safe by construction (review B2)**
- **Version gate:** it runs only when `/usr/lib/batman/rundir.sh` exists. Otherwise it reports SKIP with the reason "pre-#280 image" — never a planted mock on an old image.
- **Permission assertions:**
  - `/tmp/run` is root 755 and `$RUNDIR` is root 700;
  - the sysctls match `90-batman.conf`;
  - a non-root `mkdir $RUNDIR/x` gets EACCES.
- **batpower, without the daemon ever seeing three bad readings:**
  1. As root, `batpower once` (one tick, confirm ≥ 2, checked first) with a non-root-planted `/tmp/batpower.mock=1000`. The tick must record `UNKNOWN`, not `1000`.
  2. Daemon check:
     - a root guard loop on the node (via setsid) deletes the planted file within 1 s of any numeric reading appearing in `$RUNDIR/batpower.state`;
     - CRIT needs 3 consecutive readings, so a regression shows up as a FAIL and the node does not halt;
     - assert: across 45 s, the state never shows a numeric reading from the planted value.
- **Negative control, run for real:** the same test pointed at the old code path through a bench seam (`BATPOWER_MOCK_PATH=/tmp/batpower.mock` honoured only in `once` mode). It must read `1000`. That proves the oracle can tell the difference.
- **Dynamic sweep after a full daily-validation run:**
  - `find /tmp /tmp/lock -maxdepth 2 -user root` (busybox `find` supports `-user`);
  - every entry must be on the allowlist;
  - this catches runtime-built names that the static grep misses (review m12).
- **Planted operator interface:**
  - A `nobody`-owned `/tmp/batman-autocommit.hold` must NOT hold;
  - halow-status must show TAMPER;
  - a dry-run autocommit must not report "held".

## 3. Fail closed when the run directory is unusable (it should never be: `/tmp/run` is root 755)

| component | behaviour |
|---|---|
| autocommit main | never commits; `why=run dir unsafe` (logged, and printed to the console) |
| autocommit watchdog | **explicit fallback (review M4):** `mkdir $RUNDIR/wd` failing because the directory itself is unusable is NOT "another watchdog is running". The watchdog runs anyway and reverts at the deadline, with no claim. This is safe because main cannot commit and batman-slot refuses apply in this state, so nothing else writes p7 |
| batman-slot | refuses apply / commit / rollback with a reason. `is-trial`, `active` and the other reads still work: the Pi 3 MBR cache is skipped and the MBR is read raw every time (slower, correct) (review M4) |
| batpower | `UNKNOWN`, no action |
| payload-run / guardian | refuse start/converge; the drift verdict is FAIL (visible) |
| 95-batman-storage / uci-defaults | `mktemp` directly in `/tmp`. O_EXCL with a random name is safe against pre-creation |
| stage 2 (platform-ab) | the stage-2 trace is skipped (as today when p6 cannot be found); the OTA proceeds |

## 4. Alternatives
- **Only `protected_regular=2`:** it does not cover `mkdir` claims, `[ -f ]` tests, globs, or directories created first by an attacker. Not taken.
- **Per-path owner checks:** about 70 sites, and every new marker would have to remember to do it. Not taken; one directory plus the CI allowlist enforces this instead.
- **`/var/run/batman`:** wrong in stage 2 (review B1). Not taken.
- **A per-boot random run directory name published by root:** not needed, because procd already guarantees a 0755 parent. Not taken.

## 5. Ordering and compatibility
- **New slot booting after an OTA from an old slot:** `/tmp` is a fresh tmpfs, so no old state carries over. Stage 2 runs the **old** slot's `platform-ab` (the running image) against old paths, so it is consistent with itself.
- **The first boot of the new slot** creates `$RUNDIR` on demand.
- **Rollback to an old slot:** the old code uses the old paths, again consistent. The old exposure returns, as documented.
- **Harness across versions:** D4 resolves the directory per node.

## 6. Known limits
- Display-only `/tmp` text can still be faked: `meshled.*`, `bat-hosts` (alfred).
- tmpfs exhaustion is a DoS. Writes fail, components fail closed, and the deadline revert still runs.
- **Liveness checks match on argv** (`pid_is`, `pgrep -f "docker load"`, `"payload-run --worker"`), so a non-root process can fake them. The effect is bounded by `DEFER_MAX` (600 s) and the 1800 s claim cap: a delay, never a commit (review m11).
- Rolling back to a pre-#280 slot reopens the exposure.

## 7. Test plan
1. **Offline:**
   - `check-tmp-trust.sh` plus its 5 mutation proofs;
   - `test-payload-run.sh` under GNU and busybox (with `PAYLOAD_RUNDIR`);
   - `test-harness-265.sh`;
   - `ab-card-invariants` with `BATMAN_RUNDIR`;
   - shellcheck.
2. **rc 1.5.7-wsl.1, both boards; ab-card.**
3. **Stage-2 proof on both boards:** an OTA whose ota-trace shows `S2 BEGIN p6trace=yes` and a complete stage-2 chain, with `batdata.dev` read from `$RUNDIR`.
4. **Fleet OTA, then the full destructive daily-validation**, including `tmp-trust-280` on all 3 nodes:
   - fi-r1/r3/r4 and hold-261 prove autocommit is intact after the move;
   - cleanstop-274 and converge-274 prove the same for payload;
   - ab-selftest covers slot.
5. **D5:**
   - for one boot per board: dnsmasq restart, `wifi reload`, `opkg update`;
   - one sysupgrade;
   - one full run;
   - `logread | grep -iE "permission denied|EACCES"` must show nothing unexpected.
   - If it fails: ship D5 with the pins only, and record it.

## 8. v1 review → v2

| # | finding | resolution |
|---|---|---|
| B1 | `/var` is fresh in stage 2; `rundir.sh` and mktemp are not in the ramfs | D1 uses the literal `/tmp/run/batman` path; D1 stage-2 support (`RAMFS_COPY_*`); §7.3 proof |
| B2 | the runtime test could halt a node | D6 version gate; one-tick oracle; guard loop; real negative control through a bench seam |
| M1 | the harness executes files from predictable `/tmp` | D4 `mktemp -d` staging; D6 scope includes `scripts/node` and ssh snippets; docs updated |
| M2 | bundle and `mkdir -p /tmp/<name>` | D2 moves them all to `batman_tmp -d`; D6 bans `mkdir -p /tmp/` |
| M3 | inventory gaps; regex bypasses | D2 completed; D6 patterns and 5 mutations; full `deploy/` scope |
| M4 | the watchdog `mkdir \|\| exit 0` contradicts §3; the Pi 3 MBR cache | §3 explicit watchdog fallback; raw MBR read |
| M5 | harness version skew | D4 per-node directory resolve with identical basenames |
| M6 | hardlinks | D5 pins the sysctl; D2 adds the link-count check and a halow-status TAMPER flag |
| m7 | `protected_regular` side effects; openmanetd db | D5 checked writes, restart paths and openmanetd; fallback to pins only |
| m8 | batpower binary default; migration; rollback; EMS | D3 |
| m9 | `/tmp/run` creator; ubus before S10 | §0 corrected; D1 parent check |
| m10 | provisioning sync, depersonalise, payload-host DEPENDS, guarded `.`, test override | D1 |
| m11 | argv-spoofable liveness checks | §6, bounded |
| m12 | the runtime test was tautological | D6 permission assertions, dynamic sweep, operator-interface TAMPER |
| m13 | `ots-pause` on p6 | D2 payload, plus its doc |

## 9. v2 re-review (APPROVE-WITH-CHANGES): resolutions, binding on the implementation

### N3: exact path table (supersedes the short names in D2)
**Every full basename is kept; only the directory changes.**

- **Old:** `/tmp/<basename>`
- **New:** `$RUNDIR/<basename>`, where `RUNDIR=/tmp/run/batman`
- **Exception:** `$$` / timestamp names become `batman_tmp`, `mktemp` in `$RUNDIR`. The name is random; the prefix is kept for readability.

| family | basenames (unchanged) |
|---|---|
| autocommit | `autocommit.decided/` `autocommit.committed` `autocommit.run/` `autocommit.wd/` `autocommit.hold-consumed` `autocommit.deadline` `autocommit.start` `autocommit.canary-ok` `autocommit.why` `autocommit.hold-discarded` `autocommit.ctl/` `autocommit.ctl.dry/` `autocommit-dryrun.log` |
| autocommit temp | `canary.XXXXXX/` `autocommit.p5.XXXXXX/` |
| slot / fw | `batman-fw-override` `batman-fw-override-pending` `batman-reboot.want` `batman-slot.lock/` `batman-slot.busy` |
| slot temp | `batman-slot.mbr.XXXXXX` `batfw.{root,new,sec,sec.old,ro}.XXXXXX` `slotchk.XXXXXX/` |
| platform-ab | `batdata.dev` `p6t/` `s2-p1/` `ab-exclude` `ab-payload/`; temp `ab-check.XXXXXX` |
| storage | `batman-storage.crit` `batdata-mount.booted` `p5-restored` `bm-p7/`; temp `95-mbr.XXXXXX` `95-mbr.bak` `95-mbr.now` `95-p5.XXXXXX/` `overrides.XXXXXX` `p5-chanfix.XXXXXX` |
| power | `batpower.state` `batpower.mock` `shutdown.reason` |
| payload (`PAYLOAD_RUNDIR` default = `$RUNDIR`) | `batman-firstload-<t>.latch` `batman-payload-<t>-drift.json` `batman-payload-<t>-restarts.state` `batman-payload-<t>-verify.log` `batman-payload-<t>-resources.log` `batman-payload-<t>.converging` `batman-payload-<t>.lock` `batman-payload-<t>.pid` `batman-payload-<t>.stopping` `batman-payload-<t>.stop0` `batman-ots-pause` |
| joinwatch / cfgsave | `config-saved` `joinwatch.state` `cfgsave-onjoin.state` `cfgsave-pi3gate.failed` `cfgsave-mount.failed`; temp `cfgsave-mbr.XXXXXX` `cfgsave-p7.XXXXXX/` |
| cgi bundle | report dir from `batman_tmp -d` (`<host>-report.XXXXXX/`) |

- `check-tmp-trust.sh` cross-checks this table against the harness. Every `/tmp/<name>` or `$R/<name>` read in `scripts/**` must name a basename from this table, or from the allowlist.

### N1: the batpower oracle covers the mock path
`tmp-trust-280` runs steps 1 and 2 twice:

1. **Default config** (`source=none`).
2. **Staged, uncommitted mock config:**
   - `uci set batpower.main.source=mock; uci set batpower.main.mock_ok=1` (not committed);
   - restart batpower;
   - run the test;
   - `uci revert batpower`;
   - restart batpower again.

With the staged mock config:
- a correct build reads the absent `$RUNDIR/batpower.mock` and reports `UNKNOWN`;
- a regression reads the planted `/tmp` value.

### N2: the time-bounded plant makes the test safe whatever the build does
- **Precondition:** read `confirm` and `interval` from uci. SKIP with a reason unless CONFIRM ≥ 3 and INTERVAL ≥ 10.
- The plant lives for at most `(CONFIRM−1)×INTERVAL − 5` s, which is 15 s at the defaults.
- A root guard, `setsid` on the node with a `trap`, deletes it at that deadline **unconditionally**, even if ssh drops.
- It deletes it earlier on any of these:
  - a numeric reading in **either** `/tmp/batpower.state` or `$RUNDIR/batpower.state`;
  - a kmsg `LOW BATTERY` line.
- Fewer than CONFIRM consecutive readings cannot reach CRIT, so the node cannot halt even on a full regression.
- **FAIL condition:** any numeric reading equal to the planted value.

### N4: static check patterns (added)
- **FAIL on `(/var)?/run/batman` anywhere** except two exact allowlist entries:
  - the `RUNDIR=` literal in `rundir.sh`;
  - the harness resolver.
- This stops anyone spelling the path through `/var` again, which was B1.
- Add `/dev/shm` and `/tmp/shm`, which are 1777 (`early.c`).
- **D5 wording corrected:** a grep cannot prove a write checks its exit status. The allowlisted `/tmp` writers are display-only, each one listed, and each entry carries the reviewer's note. Nothing that influences a decision stays in `/tmp`.

### N5: harness resolve keyed on the version marker
- `R=/tmp; [ -r /usr/lib/batman/rundir.sh ] && R=/tmp/run/batman` (same gate as `tmp-trust-280`).
- On a post-#280 node whose `R` is missing: **FAIL** ("run dir missing"), never a fallback to `/tmp` names an attacker can plant.

### N6: watchdog fallback details
1. **How to tell "unusable" from "taken":** `batman_rundir` runs first. Only its rc 1 selects the no-claim fallback. A failed `mkdir autocommit.wd` on a good run dir still means `exit 0` (another watchdog is running).
2. **Without a claim, every procd respawn of main can start another watchdog.** They all revert to the same committed slot, which is harmless and logged. This is documented, not deduplicated: the case should never happen.
3. **hold-once is lost:** `HOLDC` cannot be written after the p6 flag was removed, so a held trial is reverted. This is the safe direction and is documented.
4. **`batman-slot reboot`:** the `want` file cannot be written, so it explicitly takes the plain-reboot path (`why=run dir unusable`). The batdata-mount self-check is the backstop.

### N7: §3 stage-2 row corrected
If the run dir is unusable in stage 2, batman-slot refuses apply: **the OTA is refused (fail closed)** and the node reboots onto the old slot. The stage-2 trace records why.

### N8: dynamic sweep
- `find /tmp /tmp/lock /tmp/shm -mindepth 1 -maxdepth 1 -user root ! -path /tmp/run`, compared against a stock-entry allowlist:
  - `.uci`, `resolv.conf*`, `state`, `log`, `etc`, `hosts`, `dhcp.leases`, `luci-*`, `sysinfo`, `overlay`, `extroot`, …
  - The list is captured from a fresh boot of each board and committed alongside the check.
- **Plus:** any root-owned file whose parent directory is not root-owned is a FAIL. That is the M2 pattern.

### N9: `BATMAN_RUNDIR` override and races
- The parent check runs on `dirname "$RUNDIR"`.
- Under the override (tests only), the parent must be owned by the invoking user and not other-writable.
- The create step is `mkdir -m 700 "$RUNDIR" 2>/dev/null` followed by **always** verifying, whether or not the mkdir succeeded (EEXIST from a concurrent creator is fine).

### N10: harness enumeration
The static check is authoritative; the D4 list is examples only. Known extra snippets are fixed with `mktemp` staging or `$R`:
- `daily-validation.sh` 274, 296, 400-406;
- 964, 1100, 1114 — rc.d links rebuilt from a `/tmp` glob; a planted name could add an S/K link.
