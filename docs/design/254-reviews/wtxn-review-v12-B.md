# Review of 254-wireless-txn.md v12 (§19) — reviewer B (2026-10-30)

> Note: this path previously held the round-12 review B of `254-stage1-impl` (committed in e7aa8c5, recoverable with
> `git checkout e7aa8c5 -- docs/design/254-reviews/review-v12-B.md`). The author should rename this file (e.g.
> `wtxn-review-v12-B.md`) and restore the old one; the reviewer was told to create this exact path.

Scope: the whole design read for consistency with §19; findings centred on §19. Sources actually read: `halow-setkey`
(275 lines), `99-batman-chanfix`, `main.go` (run / SetKeyNoPersist / ForgetMesh / RadioState / LiveMeshUp /
daemon / waitRadioUp), `node.go` (dispatch, applyNet, leave), `wtxn.go` (desired, satisfied, noteApply, finish,
finishGated, BootFinish, finishWantsRadio), harness `setkey-forget-lock.sh`, `lib-wireless-stubs.sh`,
`prov-254.sh` (pr_pc, pr_ota_b, back_to_a, restore), `prov-downgrade-left-254.sh`, `prov-netjoin-254.sh`,
`prov-leave-ota-254.sh`, `prov-dv-254.sh`; node captures `repro-preproforget2251030181713/{wl.log, logread.log,
boot-logread.log, wstatus.json, uci-wireless.txt}`, host logs `prov-reproforget{,2,3,4}-254-w15c.log`,
`prov-reprorace{,2}-254-w15c.log`, `prov-reproorphan-254-w15c.log`, and the node probes `repro-sampler.sh`,
`race-node.sh`, `escalate-node.sh`, `orphan-node.sh`, `prov-reproforget2-254.sh`. Not on disk and therefore
⚠️ unverified: netifd's `wireless.c` semantics, `/lib/netifd/wireless/morse.sh`; I use only what the captures show.

Angle: real use first (operator with the app, node under load, node just rebooted, two owners, a retry storm), then
the actors of §9 / §19.3, then every §19 assumption against the sources and the captured logs.

## 0. What the captures actually show (the basis for the findings below)

- `wl.log` (uptime, 1 Hz): 86 `up=true pend=false meshdev=wlh0 key=123456 txn=0` → 87 `up=false pend=true
  meshdev=wlh0 key=635042 txn=1` → **88 `up=false pend=true meshdev= wlh=0 key=635042 txn=0`** → 89 `dis=true
  pend=true meshdev=wlh0 key=CHANGE txn=1 setkey=1` … 99 `pend=true` → 100..249 `up=false dis=true pend=false
  meshdev=wlh0`.
  So the join's `halow-setkey` returned rc 0 and the helper removed `.txn` (88) **while no mesh netdev existed at
  all** — the new `wlh0` (s1g 15225) only appeared at 04:21:42 = uptime ≈ 89. The join took the `--channel` path
  (`config updated on: … channel=40`, `halow-setkey:241-266`, the channel was unchanged 40 → 40) and its read-back
  was satisfied at uptime 87 by the **OLD** `wlh0` (still on 922000 kHz while netifd was tearing it down), not by
  "the NEW wlh0 the moment it existed" as §19.1 says. The mechanism §19.1 names is wrong; the conclusion (rc 0 while
  `pending=true`) is right, and the consequence is bigger: with an unchanged channel the shipped read-back is
  satisfied *instantly and always*, on every node, idle or not — the window is not "netifd's setup time", it is
  "netifd's whole teardown + setup".
- `logread.log`: 04:21:39 join reload → netifd script 14310 → old s1g 6459 TERMINATING 04:21:40 → "radio1 is now
  down" **04:21:42** (teardown 3 s) → script 15011 → s1g 15225 `UNINITIALIZED->ENABLED` 04:21:42 → **the forget's
  reload at 04:21:42** (same second) → `MESH-GROUP-STARTED dvd-3f4c8f1c` → "radio1 is now down" at **04:21:52**
  with s1g 15225 and `wlh0` alive; the leave's forget rc 3 at 04:22:15 (code 21), the retry's Finish rc 3 at
  04:22:49 (code 22). `wstatus.json`: `up=false pending=false disabled=true retry_setup_failed=false`.
- `boot-logread.log`: the boot itself runs three setup/teardown cycles of radio1 within 7 s (04:20:31 / :33 / :36,
  three reloads from the boot scripts), each reload landing on a radio that had just come up, and every one of them
  cleaned up correctly. The orphan needs the reload to land **inside a running setup script** (15011 was between
  `morse_wpa_supplicant_add` and `wireless_set_up`), not merely "during pending". ⚠️ Consistent hypothesis, not
  pinned: netifd cancels the running setup script (kills 15011), and the daemonised `-B` s1g plus the netdev it
  created survive, the device being marked down without its teardown handler. §19.1's "the exact point is not
  pinned" is honest; the fix must then not depend on *which* reload hits the window — see B-M1.
- `prov-reproforget4`: E0 `up=false dis=true pend=false meshdev=wlh0 s1g=[15409] splist=[ wlh0 ]`, E1 `wifi down`
  no change, E2 kill → process gone / netdev stays, E3 `iw dev wlh0 del` → gone, E4 forget rc 0. ✅ the
  escalation works on the real orphan. ⚠️ Nothing after E4 exercised a `wifi reload` rebuild on that node: the S0
  restore that followed is an overlay restore **plus a reboot** (`pr_restore_cycle`, `prov-254.sh:356`). §19.3's
  "as repro 4's restore … showed" is not supported by repro 4.
- `prov-reproorphan`: the hand-made orphan was never created (`O0 morse phy = []`, `iw phy "" interface add` failed),
  so "FAIL orphan: forget did not fail" is the probe failing, not a negative control; `O5 restore rc=3 … got '?'` after
  `wifi down radio1` (E1) with `up=false dis=false pend=false meshdev=` for 60 s — consistent with `wifi down`
  clearing netifd's autostart; `wl.log` shows `auto=true` throughout repro 2 where no `wifi down` ran. ✅ enough to
  keep `wifi down` out of the fix.
- `prov-reprorace2`: `wifi down → wifi up → forget` 0–2 s later never opened the window (setup done in ≤ 1 s on an
  idle node). Round 1 (two reloads 0 s apart on an up radio) never opened it either.
- Helper side (`node.go:1212-1217`, `wtxn.go:387-394`): a forget rc 3 → `noteApply` sets the unverified file, the
  verb returns EApply 21; the retry → `finishGated` → `finish` → `ForgetMesh` again (rc 3 again, 33 s) → EState 22;
  from then on, retries within the backoff get EState at once. `.txn` stays; `config-save --check` rc 5; OTA refused.

## 1. Findings

### B-M1 (MAJOR) — "still pending at 30 s → reload anyway" re-creates the very trigger being fixed, for every write mode, and the stated reason does not hold.
Scenario (node just rebooted, or under load, or a boot-script reload still in flight — `boot-logread.log` shows
three reloads of radio1 within 7 s of boot; "any load makes it slower", §19.1): the app sends `net.apply` (or a
leave; or the boot Finish re-applies a network) while netifd's setup of radio1 is pending for > 30 s. §19.2 then
commits uci and reloads into the running setup — exactly what produced the orphan at 04:21:42. For a **join /
update** the cancelled setup leaves a `wlh0` + s1g with the **previous** key on the air; netifd's new setup then
either (a) fails to create `wlh0` (name taken) → `retry_setup_failed` → read-back rc 3 → Finish → restore → reload
into the same mess → `.txn` stuck until a reboot (the M6 lockout class §15.1 was written to kill), or (b) succeeds
and leaves two s1g on one phy. The join has no escalation; §19.3 only covers `--forget-mesh`. The reason given —
"the change in flight is netifd's own (boot, chanfix under the same lock, an operator's `wifi`); the read-back
below decides" — is backwards: chanfix *drops* the lock before netifd has finished processing its reload
(`99-batman-chanfix:75-76`), so "under the same lock" does not protect anything, and the read-back cannot see an
orphan with the old key. The fail-open also sits **after** `uci commit` (`halow-setkey:233-235`, `:188-190`), so
when it fires, "nothing changed" (rc 2) is already impossible.
Evidence: `wl.log` 87-100; `logread.log` 04:21:42 → 04:21:52; `halow-setkey:186-190, 233-235`.
Fix: move the settle wait **before any uci write and before the mark write**, right after the lock
(`halow-setkey:136`): poll netifd until the morse radio is `pending=false` (empty / malformed status = not settled);
at the deadline → **rc 2 "netifd still reconfiguring the radio after 30 s; nothing changed"** (fail closed) for every
write mode, `--forget-mesh` included. Helper mapping already exists: rc 2 on a join → `RemoveTxn` + EApply
(`node.go:1158-1160`, the app retries); rc 2 in Finish → `.txn` kept, backoff (`wtxn.go:329-331`) — acceptable, it
is retried. For a leave, rc 2 before the commit is impossible (ForgetMesh runs after the commit, `node.go:1208-1212`)
→ EApply 21, retry → Finish → forget — the same path as today, but without the orphan. Lifecycle check of the
fail-closed variant at boot: a forget at boot never meets a pending radio (uci already holds `disabled=1` from the
failed forget's commit, netifd does not set it up); a network Finish at boot runs after `waitRadioUp` (`main.go:612`).
Test: shell case (b) becomes "pending never clears → rc 2, zero commits, mark untouched"; mutant = the deadline
branch reloading anyway. Keep the escalation (§19.3) as the backstop for an orphan produced outside the lock.

### B-M2 (MAJOR) — the deterministic orphan unit is not a faithful model, and the `wifi reload` rebuild after an escalation is unproven on hardware.
The real orphan was **in netifd's splist** (`/var/state/wireless: wireless._phy0.splist=' wlh0 '`, E0) and named
`wlh0`; the hand-made one (`wlhx`, `iw phy … interface add`, `orphan-node.sh`) is outside splist. The path that
matters after the escalation is the next setup's `morse_interface_cleanup` iterating a splist that names a netdev
setkey already deleted (`kill_wait`, `ip link set dev wlh0 down`, `iw dev wlh0 del` on a missing device). Whether
morse.sh tolerates that (plain errors) or aborts (setup fails, radio stranded until reboot) is ⚠️ unverified: repro 4
rebooted after E4 (`pr_restore_cycle`), repro-orphan never created an orphan, and race-node's restores ran after a
*verified* forget (no escalation). §19.3's "the next `wifi reload` rebuilds from uci, as repro 4's restore and the S0
restores showed" is therefore not evidenced. The unit as written would pass without ever exercising this.
Evidence: `prov-reproforget4-254-w15c.log` E0/E3/E4 then `[19:21:30] P5-RESTORED … (reboot now)`;
`prov-reproorphan-254-w15c.log` O0-O2; `prov-254.sh:356`.
Fix: in `prov-forget-orphan-254` create the orphan **as the real one**: name `wlh0`, phy from
`/sys/class/net/wlh0/phy80211` taken before the teardown, and `uci -P /var/state set wireless._<phy>.splist=' wlh0 '`
after netifd's down (so splist names it as in E0); then forget (expect escalation rc 0), then
`halow-setkey --mesh <lab> --mesh-id openmanet1 --channel 40 --no-persist` and assert rc 0 **and** netifd
`up=true pending=false` and 02 a neighbour within 180 s. Negative control for the rebuild claim: the same restore on
wsl.15 after the hand-made orphan is removed by hand the same way (kill + `iw dev del`) — if it also passes, the
splist-stale path is tolerated and the claim is evidenced; if it fails, the escalation must also clear the splist
entry (`uci -P /var/state revert`/`delete` of that netdev) and the design says so. List the unit's side effects
(feedback_destructive_test_side_effects): a second mesh point with the lab key on the morse phy (possibly the same
MAC as the later `wlh0`) is on the air for seconds, 02 may see a flapping peer; the copied s1g conf holds the lab key
→ 0600 in the root-only run dir and removed at the end.

### B-M3 (MAJOR) — the black-box unit reports PASS when the condition it exists to test did not occur.
§19.6: "a PASS on a run where the window did not open proves less, and the log says which it was". Repro 3 is such a
run (leave in 4 s, `code=0`); on the new setkey that is indistinguishable from "the fix worked". A unit whose
discriminating event is absent has found nothing to check and must not report clean (global rule: "a test that finds
nothing to check must FAIL, never report clean"). The window opened 4/5 times only after the specific
B-trial-rollback reboot, for an unexplained reason (§19.1 ⚠️), so the rate can change with any image.
Fix: the unit asserts, from the sampler, that at the instant the leave's `--forget-mesh` took the lock netifd reported
the morse radio `pending=true` **or** that the join's setkey observed `pending=true` for ≥ 1 sample before returning
(the fix makes the join wait, so the second condition is the one that will hold); if neither, the unit prints
`INVALID … window did not open` (rc 2 via `pr_result`), not PASS. Also add the cheap arm that *forces* the window
without the 25-minute OTA dance: start the leave while a 1 Hz sampler shows `pending=true` produced by a preceding
`wifi reload` on a loaded node (`stress`/`dd` on p6 for a few seconds), and keep the OTA arm as the reproduction of
record. Negative control stays "same unit on wsl.15".

### B-m1 (MINOR) — §19.1 misstates the mechanism; the read-back's `--channel` check is satisfiable by the old netdev.
Per §0, the join's rc 0 came from the old `wlh0` at uptime 87 (`meshdev=wlh0`, `txn` cleared at 88 when
`meshdev=` empty). Correct the text, and make the ordering of §19.2's read-back explicit: first `up=true
pending=false`, **then** (`--channel` only) the mesh netdev's `CENTRE_KHZ`. Reason beyond accuracy: the shell case (a)
must model "old netdev present, `morse.khz` already right, status pending" so that the mutant "`up=true` check
removed" is killed — the current stub (`lib-wireless-stubs.sh` `wifi`) removes/recreates the netdev atomically and
never reports `pending`, so case (a) as described can be passed by a setkey that only waits for the netdev.

### B-m2 (MINOR) — `retry_setup_failed=true` should end the read-back at once, not after 60 s.
netifd reports it (`wstatus.json` has the field; `wl.log` sampled it `retry=false` throughout). With §19.2 a failed
setup is only noticed by the 60 s deadline; the helper then waits 60 s under its mutex for nothing. Fix: in the
read-back loop, `retry_setup_failed=true && pending=false` → rc 3 immediately ("netifd gave up setting up the
radio"). Test: stub flag.

### B-m3 (MINOR) — escalation guard must also require `pending=false`, and must say that an operator's own mesh netdev on the morse phy is fair game.
§19.3 touches a netdev "when netifd has already reported the morse radio `up=false disabled=true`". At the
FORGET_WAIT deadline netifd may still be mid-teardown (`pending=true`, 10 s in the capture); killing s1g and deleting
`wlh0` under netifd's own `morse_interface_cleanup` is harmless but makes two writers of one resource for that
second. State the guard as `up=false disabled=true pending=false`. Also state the ownership consequence: after a
leave, **any** mesh-point netdev on the morse phy is removed, including one an operator added with `iw` by hand
(§16.5 / §15.6 B m4 keep a hand-*disabled* radio out of the mark, but a hand-added mesh netdev is not protected and
should not be — nothing of a network may stay on the air after a leave). Lifecycle rows: crash of setkey between
E2 and E3 (netdev stays, s1g gone) → the next forget escalates again, idempotent — state it; netifd restart with
the orphan present → the orphan survives (netifd does not own it) → the escalation is what clears it — state it.

### B-m4 (MINOR) — `kill` by `pgrep -f` pid: harden against pid reuse and argv spoofing; add SIGKILL.
Threat walk (§9 actors): a local unprivileged process cannot create a netdev on the phy nor run the real
`wpa_supplicant_s1g` (CAP_NET_ADMIN), but it *can* name its own argv `wpa_supplicant_s1g -i wlh0`. Effect: root
`kill`s the attacker's own process (no gain), the log line names a wrong pid, and if it ignores SIGTERM the 3 s wait is
burnt (then `iw dev del` proceeds — the orphan is still cleared; no fail-open). Pid reuse between `pgrep` and `kill`:
the orphan is a daemon that does not exit by itself; window negligible but free to close. Fix: before `kill`, require
`/proc/<pid>/status` Uid 0 and `readlink /proc/<pid>/exe` = `/usr/sbin/wpa_supplicant_s1g`; SIGTERM, wait ≤ 3 s,
then SIGKILL; log pid + exe. Negative test: a non-root process with that argv is not killed and the escalation
still verifies. Do not wrap the `pgrep` in `sh -c` (the wrapper's own cmdline would match — the memory's pgrep
self-match trap; the sampler's `pgrep -f halow-setkey` counts 2-3 for that reason).

### B-m5 (MINOR) — §19.4's time budget omits the lock wait and the Finish-first; the P2 timeout text is wrong.
Worst cases with the lock busy (an operator setkey or chanfix, LOCKWAIT 90 s): leave = 90 + 30 (settle) + 30
(FORGET_WAIT) + ~15 = ~165 s; net.apply = 90 + 30 + 60 = 180 s, plus a verb-triggered Finish before it (another
setkey up to 180 s + `--save --txn` up to 300 s). All inside the helper's per-command 300 s (`main.go:81-90`), but
"a `network.leave` may take up to ~80 s, a `net.apply` ~100 s; DV uses 120 s" is not the bound. The client timing
out is survivable (the verb completes; `info.net`/retry answers "already"), so this is a contract statement to
correct, not a hole: give the per-command worst case and say the app must treat a timeout as "unknown, retry".

### B-m6 (MINOR) — `info.net` says `left=true` while the orphan carries the network key.
After the leave's commit the record is claimed + `Left`; `info.net` (`node.go:236-247`) reports `left=true`
although the radio is still on the mesh with the key (`joinwatch 04:22:51: radio=up type=mesh point
mesh=dvd-3f4c8f1c`). §4.1 says "a retried leave that finds `left` = true is done" — an app using that shortcut shows
"left" for a node that is on the air. The verb path is safe (a retried leave hits `finishGated` first, `dispatch`
:199-203). Fix: add key 4 `unfinished` (= `.txn` present) to `info.net` and state that `left` counts only with
`unfinished=false`; P2 checklist item.

### B-m7 (MINOR) — chanfix "6-line copy kept identical by hand".
§19.5 admits `check-provisioning-sync.sh` does not cover it. Put the settle wait in a sourced helper
(`/usr/lib/batman/rundir.sh` pattern, e.g. `wireless-settle.sh`: `settle_wait <radio> <secs>` returning 0/1) used by
both scripts, or add the pair to `check-provisioning-sync.sh`. Note chanfix's fail-open on lock busy ("reassert
anyway") now also reloads into a possibly pending radio; with B-M1's fail-closed settle it should instead skip that
try and continue its loop (it has 6 tries, 8 s apart).

### B-m8 (MINOR) — §6 and §8 text need updating.
§6 "Evidence (04 …): both within 2 s" now stands next to a 10 s teardown and an orphan; add the §19 rows to §8
(reload during a pending setup; orphan; escalation; settle rc 2) with their tests, and change the `--forget-mesh`
line to "verified as today, or after escalation".

## 2. Items checked and found sound

- **Timeline with the fix (B-M1 variant)**: join: lock → settle (already `pending=false` at 86) → commit → reload at
  t0 → read-back waits `up=true pending=false` (≈ t0 + 4-5 s on this boot: teardown 3 s + setup 1-2 s) → rc 0 →
  helper commit + save (≈ 2 s) → `net.apply code=0`. Leave: lock → settle (0 s) → commit placeholder+disabled →
  reload → netifd down ≤ 2 s → verified → rc 0. No overlap left; the ordering is enforced by the helper mutex (one
  verb at a time) plus the setkey lock, so two owners / two phones serialise the same way. 60 s read-back on a slow
  boot: the capture's worst teardown+setup was 3 + 1 s; 60 s has margin; `retry_setup_failed` handled by B-m2.
- **Forget on `up=true` at the deadline → rc 3, no escalation**: correct and fail-secure (netifd still owns a live
  radio; killing under it would be two writers). Helper: `.txn` kept, EApply 21 → retries EState 22 within the
  backoff → next Finish forgets again; the operator sees "retry"; recovery without a reboot = wait for the backoff
  and retry (the next forget finds netifd down and verifies, or escalates). State that in §19.2 (today it only says
  "rc 3 only after that").
- **Retry storm vs the 60 s backoff**: each retry inside the backoff is answered EState at once without a setkey
  (`wtxn.go:387-390`); one real attempt per backoff, doubling to 30 min; the boot Finish counts. Bounded.
- **Helper 300 s deadline** covers every per-command worst case (B-m5 numbers).
- **Secrets**: the new log line names a netdev and a pid only; the key never reaches argv (`--mesh -`,
  `main.go:154`); `ps` shows s1g's `-c /var/run/wpa_supplicant-wlh0.conf` path, not the key (pre-existing).
- **Trust boundary of the new inputs**: `iw dev` names are kernel-validated (no whitespace / `/`), `ubus` JSON is
  netifd's (root), `/proc/<pid>/cmdline` of root processes cannot be written by non-root; B-m4 closes the spoof.
- **Missing / malformed status**: `radio_down()` (`halow-setkey:164-167`) treats an empty `ubus` answer as "not
  down" → waits to the deadline → rc 3: fail-closed. The settle wait must do the same (B-M1 wording).
- **Downgrade / rollback**: setkey is a slot file; an older image behaves as today (orphan possible, recovery =
  reboot); no state format changes; `.txn` per slot. Upgrade with an orphan present: impossible across the reboot.
  Pi 3: unsupported (owner decision).
- **§15.4 `satisfied()`**: a forget is never satisfied (`wtxn.go:210`), so every Finish re-runs `--forget-mesh` and
  gets the escalation — consistent. §15.2 `waitRadioUp` (`meshjoin_radio_up`, chip view) is followed by setkey's own
  settle, as §19.5 says — consistent. §4.2 pre-check (hand-disabled radio) unchanged.
- **Shell cases (a)(c)(d)** are real tests (drive the interface, observe `wifi.log` / `fd9.log` order, rc) with a
  negative control on ebb9cf4; (b) must change per B-M1; (a) needs the old-netdev model per B-m1.

## 3. Verdict

**APPROVE-WITH-CHANGES.** No BLOCKER: the escalation is sound on the real orphan (E2-E4) and nothing in §19 makes a
path worse than today. Three MAJORs must be closed before implementation: the settle fail-open (B-M1 — fail closed,
rc 2 before any write, every write mode), the orphan unit's fidelity and the unevidenced rebuild-after-escalation
claim (B-M2 — splist-named `wlh0`, restore asserted on hardware), and the black-box unit's PASS-without-window
(B-M3 — INVALID, plus a forced-window arm). MINORs B-m1..m8 are one-line contract / text / test fixes; B-m4 is the
only one touching the security posture, and only as hardening.
