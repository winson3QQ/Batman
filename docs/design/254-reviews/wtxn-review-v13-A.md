# Review of 254-wireless-txn.md v13 (§19, whole design re-read) — reviewer A, round 2, 2026-10-30

Read-only: the whole design (v13), `halow-setkey`, `99-batman-chanfix`, helper `main.go` / `node.go` / `wtxn.go`,
`sock/sock.go`, `meshjoin.sh`, the harness units and stubs, the 04 captures. No node access. The round-1 review is
`wtxn-review-v12-A.md`.

## 1. Status of the v12 findings

| v12 | status | reason |
|---|---|---|
| M1 `up=true` read-back breaks blocked-radio writes | **CLOSED** | rule 2 scopes it to "the write leaves the morse radio enabled"; `--ap` alone / `--mesh-id` alone / hand-off radio → uci-only; shell case (e). Residual wording, see N5 (the predicate is computable but not written down; `--channel` on a blocked radio must stay rc 3). |
| M2 settle fail-open | **CLOSED** | rule 1: rc 2 before any write, unreadable status = not settled, helper mapping cited (`node.go:1157-1160`, `wtxn.go:329-331`). New consequences attacked in N2–N4 (no lockout that is not already the dead-radio path; one chanfix regression). |
| M3 morse phy undefined / orphan too narrow | **CLOSED** (down case) / **PARTIAL** (write-mode orphan) | phy = `/sys/class/ieee80211/phyN/device` ↔ uci `path`, probed on 04; orphan = every mesh netdev on that phy while netifd is down+disabled+not pending, operator netdevs included (stated). The roles-swapped join case (§19.5 "caught by its read-back → Finish → previous state … settles and verifies") still rests on netifd's next setup cleaning its own splist orphan — ⚠️ unverified; see N6. |
| M4 timing contract | **CLOSED** | budgets include LOCKWAIT; `pr_pc` ≥ 240 s for every net-apply / leave; "client timeout is not a bound". I verified the helper side: the socket's `Idle` is a read deadline armed before each request and a write deadline at reply time (`sock/sock.go:145,166`); the handler itself has no deadline, and the 34 s leave reply in repro 2 confirms a long verb is answered. |
| M5 non-existent rebuild evidence | **CLOSED** | §19.1/§19.3 now say the rebuild after an escalation was not exercised; the orphan unit asserts it on hardware with a setkey restore and 02 as a neighbour. |
| M6 PASS without the window | **CLOSED** | INVALID "window did not open", up to 3 retries after `back_to_a`; `pr_result` emits `UNIT … INVALID` (rc 2, `prov-254.sh:456-458`), which `cl_judge` does not accept as PASS — honest. Criterion needs a number, N9. |
| m7 `satisfied()` by the supplicant's view | **PARTIAL** | noted and left unchanged; the stated reason ("a Finish's setkey verifies by netifd") is wrong: `satisfied()` runs BEFORE the setkey and short-circuits it (`wtxn.go:317-323`, `how = "already"`), so on an orphan with a `wantNet` Finish no setkey runs at all. Still no reachable path after rule 1 that I can construct without an outside reload, so MINOR stays; fix the sentence or add netifd `up` to `satisfied()` (N7). |
| m8 kill-by-argv | **CLOSED** | `exe` + `Uid` check, TERM then KILL with re-check, `pgrep` run directly (the `sh -c` self-match seen on 04). Two gaps in N6 (no candidate pid; `(deleted)` suffix). |
| m9 key in the status blob | **CLOSED** | fields only, canary extended to the host run dir. |
| m10 stale text / chanfix copy | **CLOSED** | §6 qualified, §8 rows, settle function sourced from `/usr/lib/batman/wireless-settle.sh`. |
| m11 other reload writers | **CLOSED** | mesh11sd probed (`restart_mesh` never called); `retry_setup_failed` → rc 3 at once. |
| m12 stub gaps | **CLOSED** | cases (a)–(i) + five mutants; `kill` / `iw dev del` recording stubs. |
| m13 user-visible exit | **CLOSED** | stated; one text nit: after `EApply 21` the FIRST retry runs Finish at once (`finishFails` is 0 — the leave's own forget failure does not call `noteFinish`, `node.go:1212-1218`), it is the second retry inside 60 s that gets `EState 22`. |

## 2. New findings

### N1 — MAJOR: rule 2 assumes netifd shows `pending=true` the moment `wifi reload` returns
Rule 2 reads the status "after `wifi reload`" and takes `up=true pending=false` as "setup done". That is only true if
netifd switches the device to TEARDOWN (pending) synchronously inside the `network reload` ubus call, before the
call returns. If the state change is deferred to uloop, the first status read after the reload sees the OLD
`up=true pending=false` and rc 0 is returned at once — the §19.1 bug in the same window, now with a different cause.
Evidence in hand: the sampler's uptime-87 line shows `pend=true` within 1 s of the join's reload — consistent with
synchronous, not proof of "no sub-second gap". netifd's `wireless.c` is not in either tree; "from memory of upstream"
is not evidence under rule 4.
Fix, one of:
- (a) read-only probe on 04 before implementation: `ubus call network.wireless status` at ≥ 10 Hz straddling one
  `wifi reload` with a changed mesh key; required: every sample after the call returns shows `pending=true` until
  `up=true` reappears. Record it in §19.1. If it ever shows the old `up=true` first, the design needs (b).
- (b) make the read-back independent of ordering: besides `up=true pending=false`, require netifd's reported running
  config to be the one just written — the morse radio's `interfaces[].config.mesh_id` / `.key` and `config.channel`
  in the same status output (the fields exist: `wstatus.json`), compared in-process, never logged. Then an
  unchanged-looking status cannot be mistaken for the new setup. Stub model for the mutant: a reload whose status
  stays at the old `up=true` for 1 s before flipping to pending must not yield rc 0.
I recommend (a) now and (b) as the implementation regardless (cheap: the status is already parsed).

### N2 — MINOR: the settle gate's "section must be present" on a node whose HaLow module is dead
If the morse driver did not probe (dead module, §8 "dead HaLow"), I believe netifd still lists `radio1` from uci with
`retry_setup_failed=true` — ⚠️ not shown. If instead the section is absent, every setkey call becomes rc 2 instead of
rc 3: a join is then `EApply` with `.txn` removed (nothing changed — correct), a Finish keeps `.txn` with backoff
(as before). Both fail-closed, so no lockout; but §8's premise line "setkey with the radio off returns rc 3" and the
`radiooff.sh` evidence should be re-stated as "rc 3 or rc 2 (not settled)". Say which, or add the dead-module
status to the next time the module is unloaded for another reason (not worth a dedicated destructive probe).

### N3 — MINOR: chanfix "not settled → skip this try" can give up on exactly the slow boot it exists for
`99-batman-chanfix:61-79`: 6 tries 8 s apart, after waiting for `wlh0` to exist (which happens BEFORE netifd's
`wireless_set_up`, so the first tries routinely meet `pending=true`). On a slow first boot (regdomain settling,
the 3-reload boot of §19.1) all six can be skipped → "gave up" → the fresh slot stays on ch42 → the trial fails
and rolls back. Today's chanfix reasserts anyway. Fix: per try, wait for settle up to 30 s with the shared function
(it already holds the lock up to 90 s), and do not count a try that never reasserted; keep the lock-busy fail-open.
Shell test (chanfix-lock.sh): pending for 20 s → the reassert still happens, once, after it.

### N4 — MINOR: boot Finish meeting the gate's rc 2 has no retry timer
`BootFinish` runs once (`wtxn.go:413-427`); `finishGated` is verb-triggered only. A boot whose netifd is still
pending 30 s after `waitRadioUp` (or at once in the forget case, which does not wait: `finishWantsRadio` → false)
leaves `.txn` until the next app action or boot: saves blocked, `halow-status` says "unfinished". Not a crash loop,
not new (the dead-radio path), but it now triggers on a merely slow boot. State it in §4.3 / §8 and put a bounded
retry (e.g. once after 5 min, under the same backoff accounting) on the #254 checklist — a helper change, outside
the §19 freeze lift.

### N5 — MINOR: write rule 2's predicate down (it is computable, the text only names examples)
"Leaves the morse radio enabled" must be decided inside setkey between the release step (`:220-232`) and
`uci commit` (`:233`): enabled ⇔ staged `uci -q get wireless.$RADIO.disabled` ≠ `1` after the release step
(⚠️ assumption that `uci get` returns the staged delta — trivially probed read-only: `uci set …; uci get …; uci
revert …` on a scratch key); hand-off ⇔ `disabled=1` and not in the mark (the forget's `inmark` logic, `:176-181`),
also evaluated before the commit. And state that `--channel` on a blocked or hand-off radio keeps today's rc 3
(the centre frequency cannot be read; the §8 premise) — "uci-only as today" is ambiguous for the channel path.

### N6 — MINOR: E2/E3 edge cases, and the write-mode orphan assumption
- No candidate pid for an orphan netdev (a supplicant started with another argv shape, or already dead): say E3
  proceeds and logs `no s1g for <dev>`; a supplicant left without its interface is harmless on the air, and netifd's
  next `kill_wait` removes it.
- `/proc/<pid>/exe` reads `/usr/sbin/wpa_supplicant_s1g (deleted)` if the binary were replaced in place; not an A/B
  case — state "exact match; a `(deleted)` suffix is not accepted (fail-closed, rc 3)".
- The netdev name is substituted into an ERE; netdev names allow only `.` as a metacharacter — note it, no escaping
  needed.
- §19.5 roles-swapped join: "caught by its read-back (rc 3 → Finish → previous state, whose forget / setkey then
  settles and verifies)" assumes netifd's NEXT setup cleans the orphan it listed in the splist (the orphan netdev
  carries the name `wlh0` the setup needs). §19.1 shows a TEARDOWN did not clean it; whether a SETUP does is ⚠️
  unverified and decides whether write-mode orphans self-heal. Cheap to learn inside `prov-forget-orphan-254`: a
  second arm on the fixed image that skips the escalation and runs the setkey restore directly on the hand-made
  orphan; record the outcome (not a pass/fail criterion of the unit). Alternatively state the join case as "not
  self-healing; a later leave's escalation clears it".

### N7 — MINOR: correct the m7 sentence in §19.5
Replace "a Finish's setkey verifies by netifd" with "a Finish on an orphan with a network to restore would judge
`already` from the supplicant's view and skip the setkey (`wtxn.go:317`); no path reaches that after rule 1 without
an outside reload; adding netifd `up=true pending=false` to `satisfied()` is on the #254 checklist (helper change)".

### N8 — MINOR: the orphan unit's side effects and abort paths
The unit writes `/var/state` (`splist`), creates a root netdev + a root `wpa_supplicant_s1g` with the lab key, and
commits `disabled=1` + the mark. Its header must list all of them and say that the S0 restore + reboot is run on
EVERY exit, INVALID and abort included (the splist and the hand-made process are not undone by the overlay restore —
only the reboot clears them); on abort before the forget the unit itself kills the s1g it started (by the pid it
recorded) and deletes the netdev. The conf copy in the 0700 run dir is removed in the same exit path. Also state the
lab-key exposure honestly: the hand-made mesh point beacons the lab mesh id with the lab key — the same thing the
node does every day; nothing new is on the air.

### N9 — MINOR: give the "window opened" criterion a number
A single `pending=true` sample occurs on every reload (teardown + setup ≈ 1 s on an idle node, where the bug never
reproduced: repro 1, repro 3). The discriminating condition of §19.1 was a teardown of ≥ 3 s. Criterion: ≥ 2
consecutive sampler lines with `pending=true` between the join's reload (`key` changes) and the join's `txn=0`;
fewer → INVALID. Record the count in the unit log so the ≤ 1/5 INVALID expectation can be checked over runs.

## 3. Whole-design consistency (unchanged parts re-read against §19)
- §2/§3/§4 (Finish, rc mapping): rc 2 from the gate fits every existing branch (`applyNet`: RemoveTxn + EApply;
  `finish`: failure, `.txn` kept; `leave`: EApply 21). No new state, no new writer of `.txn` / the marker / the mark.
- §6: the lock semantics unchanged; the gate adds ≤ 30 s under the lock, inside the 90 s LOCKWAIT of the next writer.
- §8 lifecycle: the two new rows are there; N4 adds "slow boot with `.txn`" (today's dead-radio row, say so).
- §9 security: new inputs are kernel/netifd/root-process data; argv impostors ignored (exe + Uid); nothing logged
  carries the key; every unknown is fail-closed. Agreed.
- §15.4 / §16.5: consistent with rule 2's hand-off handling.
- Ownership statement in §19.3 is now explicit and the TOCTOU reason (`disabled=1` committed first) is given. Agreed.

## 4. Verdict
**APPROVE-WITH-CHANGES.** One MAJOR (N1): the read-back's correctness depends on an unproven netifd ordering
property; settle it with the 10 Hz probe before implementation and build the config comparison into the read-back
regardless. The MINORs are text/contract precision (N5, N7, N9), one chanfix regression (N3) worth fixing in the same
PR since chanfix is touched anyway, and the orphan unit's exit discipline (N8). No re-review of the whole document
is needed if the N1 probe confirms synchronous state; if it does not, the revised rule 2 comes back for review.
