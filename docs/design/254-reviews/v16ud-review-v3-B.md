# Review v3.1 (reviewer B) — `docs/design/254-v16-ud.md` at b2812b0

I read the whole document again. I checked it against the source at b2812b0 (`feed/` = wsl.36) and the harness on
`test/254-v16-group4`. I checked §0.4 / §15 line by line against the owner's raw probe log
`docs/design/254-reviews/v16ud-eud1.log`. Read-only: no node, no ssh. The mesh id in the log is not a finding (owner).

## E-UD1 (§0.4 / §15) against the raw log

The design reads every item correctly:
- **AP:** on, `ssid=BCM2711-6c89 key=set disabled=0`, `phy1-ap0` up (log #4, #5).
- **Keyguard:** no mark (#8).
- **Missing tools:** no `stat` (#9). No `od`, `timeout` or `base64`; `hexdump` and `setsid` are present (13b).
- **Config file mode:** recorded (9b; the lines are kept locally).
- **Panic:** `kernel.panic=3`, from `sysctl.d/10-default.conf:4`, over the cmdline `panic=10` (16b).
- **sysrq:** 502 (#17).
- **Helper pid:** 4204 (#18).
- **uci:** `/tmp/.uci` is 0700 root, no changes (#19).
- **Stale `update-last`:** 0600, 171 B, wsl.35 from and to, boot `bad82cfc…` (20b).
- **Slot B:** `bad=0` (#21).
- **p5:** fresh (#22).
- **joinwatch:** 4730, enabled (#23).
- **dd input side:** busybox `dd` keeps `if=` on fd 0, and `pos:` advances on mmcblk0p4 (#15).

Nothing in §0.4 overclaims. The output side of `dd` is correctly still marked as owed, and it gates the kill arm.

The decision to keep the stale `update-last` is sound. On wsl.36 the running version is neither `from_version` nor
`to_version`, so status answers row 5 with no sha (`updwork.go:889-890`). The tick's disarm needs
`apply_boot_id` = this boot (`:934`). Prepare overwrites the file (`:229-232`). Snapshot, restore and compare keep it
byte-identical (`prov-base-254.sh:100-104, 273-275`). Small note: "row 5 or row 11" in §4.1 — row 11 (`st(0, 0)`)
carries `ul.Sha` (`:886-887, 917`), so "no sha" admits only row 5. That is harmless.

## v2 findings: fixed in source terms?

| v2 finding | State | Checked |
|---|---|---|
| B M1 Y had V's SUMS | **fixed.** Y = `badpayload`; `sums_sha(Y) ≠ X` is asserted in WSL, with a fixture | §3.3 table; `updwork.go:208-211`; `bulk.go:62-66` |
| B M2 journal after the restore; no single action | **fixed in design:** `undo-done`, inline inverses, `pl undo` before `pr_restore`, `pr_release`'s undo must find nothing, no wireless export on this bench. See MINOR-2 for an order mismatch in §7. | `prov-254.sh:545-566, 586-602`; `prov-undo-lib-254.sh:237-262` |
| B M3 watcher lifetime and output | **mostly fixed:** setsid, pidfile, 900 s `/proc/uptime` deadline, `ud9.stop`, one-shot, only a younger `dd`, p6 log. Two new problems: **MAJOR-1** (sync before acting) and MINOR-1 (registration order). | — |
| B M4 / A M3 openmanetd | **fixed by removal:** no non-exempt key; UD13 P = `--check` text; UD6 (b) = safe ssid with joinwatch stopped | `batman-config-save:462-468, 486-497`; `batman-slot:565-577` |
| B m1 P9 rc 8 / rc 14 / remedy | fixed (retries; gated FAIL / ungated WARN) | `batman-config-save:263` |
| B m2 journal plumbing; `ap-restore` | fixed in design. It is unexercised on this bench (MINOR-4). | — |
| B m3 where the secret lives | fixed. No wireless export on this bench (`ssid-restore`); `hexdump` producer; the file mode recorded | log 9b, 13b |
| B m4 ownership gaps | fixed (§5) | — |
| B m5 run-time guard | fixed (`pr_pc` refuses, offline test) | — |
| B m6 / A m3 reserve label; no kill reserve | fixed | — |
| B m7 / A m6 Q9 | fixed (§12, including `ap_key_sha=`) | `main.go:48`; `node.go:463-473` |
| B m8 small items | fixed | `batman-slot:61-65, 1064` |
| A M1 caps line breaks `exec` / `proxy` | fixed (stderr, helper-socket ops only, byte-identity tests) | `main.go:553-565` |
| A M2 fleet P9 | fixed (gated on a `pupdate…` dirty flag; strict only in this unit's `pr_begin`) | — |
| A m1 EBusy from the config-save lock | fixed (§1.1 retry) | `update.go:328-329` |
| A m2, m4, m5, m7–m10 | fixed. m10 is half settled by E-UD1 #15; the rest goes through observe mode | — |

## Findings

### MAJOR-1 — the watcher's `sync` before acting can push the cut past the window: a correct product can FAIL, and the kill check is made at the wrong time

**Scenario.** §1.5-6: every result line is appended to `/opt/batdata/log/dv-ud9-<run>.log` "and **`sync`ed before it
acts**". A plain `sync` flushes all dirty pages system-wide. When the watcher fires (pos ≥ SQ/2), the stream `dd`
(`dd of=$TROOT bs=1M conv=fsync`, `batman-slot:856`) has tens of MB of B's rootfs dirty in the page cache: `conv=fsync`
syncs only at the end. A global `sync` blocks until those reach the SD card, which takes seconds on a card. Meanwhile
the helper keeps feeding the pipe.

**Consequences.**
- The `pos < SQ − 8 MiB` invariant of the kill sub-arm (§1.5) is tested when pos is read, not when `kill -9` lands. If
  the stream finishes during the sync, the orphan `dd` gets the whole rootfs, `write_slot` verifies, and B ends
  `bad=0` / VERIFIED. That is a FAIL of a correct product, attributed to it.
- In the cut sub-arm the slot is BAD whatever happens (`batman-slot:468-473`). But "mid-stream" is no longer what was
  cut, and a sync that outlasts the stream turns the cut into "after `write_slot`". `write_slot` clears BAD on success
  (`:774-775`), so that is also a FAIL.

**Fix.**
- Kill: act first, then write and flush the log. A SIGKILL loses no RAM.
- Cut: flush only the log's filesystem. Use `sync -f <logfile>` (syncfs of p6) if the node's busybox has it — add a
  read-only probe (`sync --help 2>&1`) — or write the line with `dd conv=fsync` on the log file alone. Neither flushes
  the B block device's cache.
- Both sub-arms: re-read pos right after the action and log it (`UD9-FIRE pos=<p> pos_after=<q>`, after the fact for
  the cut). The judge accepts only `pos_after < SQ − 8 MiB` for kill. Anything else is INVALID "late", never FAIL.
- Offline: a stubbed `sync` that takes 10 s must still yield a valid order (action before the global flush), or the
  late outcome must be INVALID.

### MAJOR-2 — `ssid-restore`'s argument goes through an unquoted `set --` in the root undo executor: `*` in an ssid globs

**Scenario.**
- The executor rebuilds each journal line with `set -- $(awk -v id="$_id" '$1==id' "$_j")`
  (`prov-undo-lib-254.sh:239-240`). That is unquoted, so it word-splits **and** expands pathnames.
- The new `ssid-restore <S0 ssid>` validates the ssid "against `apChars` and 1–32 characters". `apChars` contains `*`
  (`settingsset.go:66`), and real ssids may also contain inner blanks (`apSSIDOK`, `:77-79`).
- The S0 ssid is set by the owner through the app (`settings.set` key 20, via provd). It is data from a lower-privileged
  path, consumed by root.
- An ssid like `Lab*` expands, in the dead-man's or the host executor's working directory, to file names. `uvalid`
  re-checks the expanded words, and plain names pass `apChars`. `uact` then commits and `p5-save`s a **wrong** AP ssid.
  If the word count changes instead, the line is CRIT and the change is never undone.

There is no code execution here (no `eval`), but a privileged restore that writes a value it did not record is exactly
the case the design rules ask to rule out. The bench's S0 ssid (`BCM2711-6c89`) happens to be safe; the code path does
not depend on that.

**Fix.**
- Store the ssid hex-encoded in the journal (`ssid-restore <hex>`, validated `[0-9a-f]{2,64}`) and decode in `uact`.
  Alternatively, refuse to register any ssid outside a glob- and blank-free subset; an ssid outside it makes the step
  INVALID before the change.
- Offline: a journal line with `*` and with a blank, replayed in a directory full of files, restores the exact recorded
  value or refuses at registration.

### MINOR-1 — the watcher's `kill-pg` cannot be registered "before starting it"

§1.5-1 says the `kill-pg <pgid>` undo is registered **before** the start, but the pgid only exists after `setsid`
starts the watcher. The real order is start → read the pidfile → register, with a gap in which a host death leaves an
unregistered watcher. The 900 s deadline, the one-shot rule and the "only a younger `dd`" rule bound that gap. Say so,
and keep it short: register in the same ssh call that starts it.

### MINOR-2 — §7 states the wrong replay order; after a reboot during UD6 (b), P9 does not see it

- **Replay order.** §1.2 registers `svc-start joinwatch` first, then `p5-save`, then `ssid-restore`. The executor
  replays in reverse (`sort -rn`, `prov-undo-lib-254.sh:238`): `ssid-restore` → `p5-save` → `svc-start`. That is the
  better order. §7 says `svc-start` → `ssid-restore` → `p5-save`; correct the text.
- **Reboot during UD6 (b).** If 04 reboots (power) while UD6 (b) has the **safe** `dv-s<run8>` ssid committed:
  - joinwatch starts at boot;
  - the AP comes up on air under the dv ssid;
  - joinwatch's on-join save makes p5 **fresh with that ssid**.

  So the §7 claim "the next `pr_begin` or gated P9 sees `--check` rc 5" is false. What repairs it is the p6 journal
  replay in the next prov unit's `pr_begin` (`prov-254.sh:209-214`). That works only if `ssid-restore` is
  `uwhere` = `p6 slot:A`, which §4.3 does not state. State the binding, and correct §7.
- **Fleet P9.** Have the fleet P9 WARN on `undo-pending` non-empty, so a node in this state is visible before the next
  prov unit.

### MINOR-3 — UD13's inline restore marks `p5-save` done without running it

§1.2 step 7: "S0 ssid, commit, start joinwatch, `undo-done` both lines". After UD13's PreSave, p5 holds no ssid line
(SKIP_UNSAFE drops it, `batman-config-save:466`). The restore then relies on joinwatch's next on-join save. Run
`batman-config-save --save` inline, assert `--check` rc 0, and only then mark the line done. The same applies to UD6 (b).

### MINOR-4 — ap-on / `ap-restore` is privileged code that this PR would ship untested

E-UD1 shows the AP on at S0. On this bench the branch never runs, and the PR would carry a root restore (uci import,
mark copy, `wifi reload`) that has never been executed. Scope comes from the field: drop ap-on and `ap-restore` from
this PR, and make "AP off at `pr_begin`" an INVALID with the reason. Re-add both when a bench actually needs them, with
a test.

### MINOR-5 — the kept wsl.35 `update-last` becomes live if 04 ever runs wsl.35 again

On wsl.35 (`ver == from_version`), the record's `apply_boot_id` and `rebooting` would drive rows 8–10. UD11 (downgrade to
an older image) is in #255. Add one line to #255's checklist: "04's S0 carries a wsl.35 `update-last`
(`v16ud-eud1.log` 20b); a downgrade arm must take it into account".

## Owner's provisional answers

- **Q12 — accept.** `--check` printing `p5 stale: wireless.default_radio0.ssid` **without** "(unpersistable" proves
  that the committed quote reached config-save and was skipped by `SKIP_UNSAFE`. Two other implementations would print
  something else: a value hidden from `--check` would print "fresh", and a config-save without the exemption would add
  "(unpersistable". So the text discriminates, and `ok=true` plus the PreSave log line complete the row.
- **Q13 — accept, with the stated bounds.** `pr_compare` already stops joinwatch (`prov-254.sh:455-457`). The node is on
  a committed boot, so autocommit does not depend on it. The stop is journalled and checked by `pidof` on restart.
  MINOR-2 covers the reboot case.
- **Q9 / Q10 / Q11:** as decided; nothing new.

## Lifecycle and resources: what I looked for and found covered

- Host death in each arm.
- An abort on B committed.
- A reboot while joinwatch is stopped (MINOR-2).
- A watcher outliving its arm (bounded).
- Upload readers blocked on a FIFO (a host-side `timeout`, and the 471 reader's pid is killed).
- `update-last` both in S0 and after the arms.
- The p6 journal surviving reboots.
- No new `/tmp` name without an allowlist row.
- The ownership table now lists every resource the arms touch.

## Verdict

**REJECT for this round under the owner's rule (no MAJOR may stay open).** 0 BLOCKER, 2 MAJOR, 5 MINOR.

Both MAJORs are local: the order of `sync` and action in the watcher (MAJOR-1), and the encoding of one journal
argument (MAJOR-2). Every v1 and v2 BLOCKER and MAJOR of both reviewers is fixed in source terms, and §0.4 matches the
raw E-UD1 log. Once MAJOR-1 and MAJOR-2 are fixed as described, I expect APPROVE.
