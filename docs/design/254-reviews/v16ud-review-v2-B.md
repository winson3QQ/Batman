# Review v2 (reviewer B) — `docs/design/254-v16-ud.md` v2 (89b06a7)

The whole document was read again, against the source at 89b06a7 (`feed/` = wsl.36), the harness on
`test/254-v16-group4`, both v1 reviews and the owner's decisions (Q3, Q6, Q8; provisional Q9–Q11). Read-only: no node,
ssh or device. Emphasis as asked: lifecycle / host death / undo journal; restore and compare incl. `update-last`; guards
and lints; the compromised uid-471 provd and a local unprivileged process (the dd watcher and the AP-on step in
particular).

## v1 findings: checked against the source, not the disposition table

| v1 finding | State in v2 | Evidence I checked |
|---|---|---|
| B BLOCKER-1 `update-last` | fixed: `STATEFILES` + `PR_UST0` status compare + offline negative control (§4.1) | `prov-base-254.sh:36, 100-104, 273-275`; `updwork.go:881-917` |
| B M1 / A B3 generator order | fixed (§3.3 repack from V's listing; `tar -C dir .` is a negative control) | `updwork.go:484-509, 548`; `build-ab-payload.sh:90` |
| B M2 / A M3 reason 11 | fixed by the why-string rule; UD8 (4) uses a directory entry, which is the only member that reaches the count rule | `updwork.go:291, 543-551`; `update.go:269`; `node.go:235, 245` |
| B M3 / A m3 serial 0 | fixed (`--unsafe-serial`) | `signrel.py:375-376` |
| B M4 / A M2 observability | UD7 fixed (`bulk-open X` after the refusals). **UD20c / UD20b not fixed: see MAJOR-1** | `updwork.go:860-883`; `bulk.go:62-66` |
| B M5 / A M1 UD10 | fixed (0 + 23, re-check, 3, then UD1's apply) | `updwork.go:878-882, 695-711`; `254-p3-impl.md:396, 929` |
| B M6 / A M4 guards | fixed in design (§2); see MINOR-5 for runtime enforcement | `test-slot-guard-254.sh:458-460` |
| B M7 abort paths | fixed (§4.2) | `prov-254.sh:371, 494, 575-584, 395-405` |
| B M8 P9 / undo / dead-man | P9 lines and journal entries added. **The order in which the journal replays relative to the restore is wrong: see MAJOR-2** | `prov-254.sh:545-566, 586-602`; `prov-undo-lib-254.sh:76, 241-245` |
| B M9 UD9 | trigger choice fixed (position watcher, kernel-fact identification). **Watcher lifetime / output channel undefined: see MAJOR-3** | `batman-slot:847-861`; `provstore/exec.go:93`; `node/update.go:38` (60 s retry on rc 14) |
| A B1 reason at key 1 | fixed | `node.go:75-81`; `p3.go:165-168`; `main.go:652` |
| A B2 uncommitted uci | fixed (commit + undo); P9 `--check` catches a leftover (see MINOR-1) | `batman-config-save:143-146, 462-468, 494-495` |
| A M6 UD1 race | fixed (hold + `release_guarded`) | `batman-autocommit:582-589` |
| A M7 / Q8 | fixed (device flip + out-of-tree module, ⚠️ build risk stated) | — |
| A M8 AP | decided (Q6) and designed (§4.3); see MAJOR-2, MINOR-2/3 | `settingsset.go`, `halow-setkey:8-20, 35, 129` |
| v1 minors (both) | addressed | spot-checked: reboot count 18, listener stated, sysrq = hard reset, W narrowed to `update.status` |

Also verified for v2's new claims: the UD20 neg why "owner-op signature / nonce" (`node.go:745`); `die_c` writes the
otalog DIE line with `rc=` for `write` (`batman-slot:61-65, 1064`); the 60 s rc-14 retry (`node/update.go:38, 205-209`);
`errBody` puts the reason-code at key 1 (`node.go:75-81`).

## Findings

### MAJOR-1 — UD20c's and UD20b's Y has the same `SHA256SUMS` as X: the "swap" is no swap and both rows FAIL

Scenario. §1.2 takes Y = "the manifest of UD8 payload 1: version V, different `SHA256SUMS`". `malicious 1` (§3.3)
replaces a **listed** dtbo by a symlink of the same name; the listing is kept (that is what makes the member "listed"),
so `SHA256SUMS` is byte-identical to V's and key 4 of Y = X. The same holds for malicious 2, 3, 4 and `mutate` (all keep
V's SUMS by design); only `badpayload` changes the root line. Pending, `bulk.open` and `prepare` compare **only** the sums
sha (`update.go:362-366`; `bulk.go:62-66`; `updwork.go:208-211`). So in UD20c the owner's `bulk-open Y` succeeds (P
passes), but `bulk-open X` also succeeds (expected 15 → FAIL), and in UD20b the prepare passes the sha check and is then
refused for "the caller does not hold the upload window" (`updwork.go:212-214`) — 15, but with the wrong why → FAIL
under the why-string rule. The rows cannot pass on a correct product.
Fix: Y must have a different `SHA256SUMS`: either `badpayload`'s manifest (root line changed; already signed with
`--allow-no-key`) or v1's `swapy` (an extra listed overlay). Add to the generator acceptance and to the unit: "sha of
Y's SUMS ≠ X", checked in WSL before the node is touched; a match is INVALID.

### MAJOR-2 — the undo journal replays **after** the snapshot restore and its compare, re-applying intermediate states (incl. the AP-on passphrase into p5); and "run the action now" has no interface

Scenario. `pr_end` = `pr_restore` (p5 + overlay + compare + reboot) → `pr_brewrite` → `pr_finish_snap` → `pr_release`,
and only `pr_release` runs the journal (`pl undo`, `prov-254.sh:555-558`). Nothing in the units marks a line done, so
every registered line replays then, newest first (`prov-undo-lib-254.sh:241-245`). With §4.3's registrations in the
refuse arm: ap-on → [p5-save, ap-restore]; UD13 (a) → [p5-save, uci-restore wireless (export taken **after** ap-on)];
UD13 (b) → [p5-save, uci-restore openmanetd]. Replay order on the already-restored node: openmanetd export →
p5-save → **wireless export of the AP-on state (AP enabled, the random passphrase)** → **p5-save (writes that passphrase
into p5 again)** → ap-restore → p5-save. The end state is S0 only if every step succeeds; a failure leaves the node with
the AP-on config and the random key in p5 — after the unit already printed "S0 restored". The status compare of §4.1
runs before `pr_release` as well, so it cannot see this either.
Second gap: §1.2 UD13 says "restore the ssid now (run the action)". The lease script offers only `undo` (the whole
journal, with segment 1, `prov-lease-254.sh:98`; `prov-undo-lib-254.sh:160-190`), which would also run `ap-restore` and
switch the AP off for every later row.
Fix: (1) a new `undo-done <id>` (under the lease) and have the unit perform each inverse inline, then mark it done; the
journal is then only the host-death path. (2) In `pr_end` / `pr_abort`, run `pl undo` **before** `pr_restore`, so the
snapshot compare and the status compare cover the result. (3) Register `uci-restore wireless` once, before ap-on (the S0
export), not again after it; that also keeps the random passphrase out of the p6 exports (MINOR-3). Offline: a stubbed
journal with a failing `ap-restore` must end in a FAIL line, not in "S0 restored".

### MAJOR-3 — the UD9 watcher's lifetime and output channel are undefined: its proof can be lost, and a stray watcher can fire later

Scenario. §1.5 starts the watcher "in the same ssh command just before the guarded prepare". That session is `pr_pc`'s,
which ends as soon as the prepare answers phase 2; the first pass then runs for minutes before any stream `dd` exists
(`updwork.go:349-368`). A foreground watcher dies with the session (or on SIGPIPE at its first print); a backgrounded
one has no defined output: in the cut sub-arm a tmpfs file or `logread` is gone after `sysrq b`, so the P
"`UD9-FIRE pos` within [SQ/2, SQ − 8 MiB)" cannot be read. Nothing bounds it either: no deadline, no pidfile, no undo
line. After a host death or an abort before the second pass, a root process that `kill -9`s the helper or writes
`sysrq b` keeps waiting for the next `batman-slot write` whose `dd` matches — e.g. the dead-man's restore or the next
run's write arm in the same boot.
Fix: start it detached (`setsid`, stdin `/dev/null`) with a pidfile in `/tmp/run/batman-dv/<run>/`; a hard deadline
(first pass + stream bound, e.g. 900 s) after which it prints `UD9-MISS timeout` and exits; one-shot; register
`kill-pg <pgid> ud9-watch` (an existing boot-bound action, `prov-undo-lib-254.sh:68, 76`) **before** starting it; write
`UD9-FIRE` to a p6 file (`/opt/batdata/log/dv-ud9-<run>.log`, root 0600) **and `sync`** before acting, plus `logger`;
the host reads it after `pr_find`. `pr_release` and P9 assert no watcher is alive. Offline: a stub watcher past its
deadline exits with `UD9-MISS`; the abort path kills its group.

### MAJOR-4 — Q11: `openmanetd.config.roipconfigured` has an unlisted second writer and reader whose behaviour is unproven

Evidence. `docs/design/202-config-survival-closeout.md:18, 59`: at run time **openmanetd** flips
`dhcpconfigured / roipconfigured`, changes `ahwlan.ipaddr` and reboots; `254-p1-impl.md:954`: config-save persists only
those two openmanetd keys. openmanetd is an external binary; nothing in this repo shows when it reads the key or what a
value other than its own does. The design asserts "no arm triggers a reload" and leaves it ⚠️; §5 lists the harness as
the only writer of `/etc/config/openmanetd`. In UD6 (b) the value is committed for the whole first pass (minutes). The
worst plausible case is openmanetd treating "not 1" as "not configured", rewriting its config and rebooting 04 mid-arm;
a milder one is openmanetd re-committing the file, so `uci-restore` then reverts openmanetd's own change.
Fix: probe read-only in E-UD1 (current value; `strings` of the openmanetd binary / its upstream source for the key and
the code path that reads it; whether its init has a `procd_add_reload_trigger openmanetd`); derive the test value from
the current one (append `'`, so "1" stays a prefix) instead of `0'q`; assert openmanetd's pid and the boot id are
unchanged across the exposure (a change → INVALID with the evidence); list openmanetd as a second writer in §5. If the
probe cannot settle it, keep the exposure to UD13 (b) (seconds) and run UD6 (b) only after the owner accepts the risk.

### MINOR-1 — P9 `batman-config-save --check` rc ≠ 0 FAILs on a lock-busy answer

joinwatch saves every 15 s while joined; `--check` answers rc 8 "lock-busy" while that runs
(`batman-config-save:263`). A FAIL there is a spurious preflight failure. Retry rc 8 a few times; only 5 / 7 / other are
FAILs. Likewise the P9 `bootinfo` of the inactive slot can get rc 14 (a slot verb in progress): retry, then INVALID,
not FAIL. The "`update-last` exists" FAIL needs its remedy text (who may delete it, after checking what).

### MINOR-2 — `rm-hold` / `ap-restore` need their journal plumbing stated; `ap-restore` departs from its reserved meaning

`uwhere` (`prov-undo-lib-254.sh:76`) decides p6 / tmpfs and the slot binding; both new actions must be p6 +
`slot:A` (overlay files and a p6 flag), with argument validation like `uci-restore` (export path inside
`$UJP/<run>/`). The reserved `ap-restore` was meant as "C0 written back through halow-setkey" (`:70`); v2 restores by
`uci import` + mark copy + `wifi reload radio0`. Say why that is equivalent for the bench S0 (keyguard-blocked, placeholder
key, `disabled=1`) and that `wifi reload radio0` does not touch the mesh radio (checked in E-UD1 from `uci show
wireless` section → device mapping).

### MINOR-3 — secrets: where the AP-on passphrase actually lands

§4.3 says the journal export holds "the previous AP key". With v2's order, UD13 (a)'s `uci export wireless` is taken
after ap-on and holds the **new** random passphrase too (p6, root 0600), and the replay of MAJOR-2 writes it into p5
again. The passphrase also sits in `/etc/config/wireless` for the run: record its mode in E-UD1 (`ls -l`) and state who
can read it, since this unit creates the secret. The FD3
producer needs `base64` in the node's busybox (probe in E-UD1); an empty or short result must stop the step (the product
also refuses a bad length) — never retry with a weaker source.

### MINOR-4 — ownership table gaps

Missing rows: `/etc/halow-keyguard.blocked` (product: keyguard, `halow-setkey`; harness: the `ap-restore` copy);
`/etc/config/openmanetd` (openmanetd itself, MAJOR-4); the p6 journal exports (harness; contain secrets); the watcher's
pidfile and log (harness).

### MINOR-5 — guard enforcement is static only

Lint (1) is line-based; a call that builds the op name in a variable (`pr_pc … -- $op`) evades it. Make `pr_pc` itself
refuse `update-prepare` / `update-apply` without `GUARD=` (fail-closed at run time), with an offline test.

### MINOR-6 — Q10 (`write-hang` reserve): acceptable, but label the result

`write-hang` parks before the first rootfs byte (`batman-slot:855`): a PASS through it proves "cut after `begin_write`,
before the stream", not the mid-stream row. The PR must report it under that name. Do not rely on `set -C` for safety
(noclobber does not stop writing through an existing non-regular target); the post-check (root owner, regular, 1 link —
the same rule `opf` applies) is the guard. The other conditions in §1.5 are sound (the parked orphan dies with the
reset; segment 1 of the undo already removes `/tmp/batman-fault.*`, `prov-undo-lib-254.sh` useg1).

### MINOR-7 — Q9: agree, with the reason written down

`short()` prints the first 8 bytes of sha256 of the password (`main.go:48`); the password is 24 characters from
`genPassword` (`node.go:463-471`), random, well over 100 bits. A 64-bit hash prefix of that is not a practical offline
verifier. A checklist line on #254 is right; put this reason in it so the next reader does not reopen it.

### MINOR-8 — small precision items

- §1.2 step 0: the old binary prints no `PROVCLIENT caps=` line; exempt it explicitly and say where the pinned old
  binary comes from (path + sha).
- §1.5 kill: the "st line shows rc 13" is the otalog `SLOT DIE cmd=write rc=13` line (`batman-slot:61-65`, `TRACE=1`
  for `write` at `:1064`); name it so the judge matches the real text.
- §1.7: the ap-on / ap-off cycle (one `wifi reload` each) touches only the phone AP if MINOR-2 holds; say so in the
  side-effects column.

## Owner questions

- Q9: agree (MINOR-7).
- Q10: agree with MINOR-6's labelling.
- Q11: not yet sound; needs the probe and the guards of MAJOR-4.
- Q3 / Q6 / Q8 as decided: implemented as decided, with MAJOR-2 / MINOR-2 / MINOR-3 for Q6.

## Verdict

**REJECT for this round (revise and re-review the whole document)** — under the owner's rule no MAJOR may stay open.
There is no BLOCKER: every v1 BLOCKER from both reviewers is fixed and verified against the source. The four MAJORs are
local: one input choice (MAJOR-1), the journal order and an `undo-done` interface (MAJOR-2), the watcher's lifetime
(MAJOR-3) and the evidence for one config key (MAJOR-4).

Counts: 0 BLOCKER, 4 MAJOR, 8 MINOR.
