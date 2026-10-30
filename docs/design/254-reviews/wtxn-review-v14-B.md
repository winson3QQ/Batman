# Review of 254-wireless-txn.md v14 (§19) — reviewer B, round 3 (confirmation, 2026-10-30)

Read: §19 v14 in full (lines 470–714) against the unchanged §1–§18; reviewer A's ordering probe raw data
(`scratchpad/core/runs/race-preproprobe2541030195215/{fast.log,race.txt}`) checked by hand. Read-only; no node
access.

## 1. Disposition of my round-2 findings

| round 2 | status | reason |
|---|---|---|
| N-M1 INVALID rule non-discriminating | **CLOSED** | §19.6: INVALID unless ≥ 3 consecutive 1 Hz samples `pending=true` during the join AND the setkey line `read-back: netifd up after <n> s` with n ≥ 3 (the duration that opened the window 4/5 on 04, ≤ 1–2 s when it did not); FAIL final; INVALID-only retries ≤ 3 from a Left node; the forced-window arm honestly marked ⚠️ not promised. The rule can now fire on the fixed code. |
| N-M2 rule 2 scope / channel rc | **CLOSED** | Predicate computed in setkey from the staged `uci -q get wireless.$RADIO.disabled` after the release step (`:220-232`; staged-read probed, `race.txt` "N5 staged get = [1] … after revert = []"); blocked / hand-off radio → non-channel uci-only rc 0 as today, **channel path rc 3 as today**; §8 premise reworded "rc 3, or rc 2 when not settled"; §16.5 / §17.3 stay true. |
| N-m1 chanfix skip spin | **CLOSED** | Per-try settle ≤ 30 s under the lock, skip uncounted (A2 N3's reason: six skips must not strand the slot) **plus** a 5 min total deadline — bounded either way; shell case stated. |
| N-m2 hung netifd exit | **CLOSED** | §19.5: rc 2 text names the reboot exit, `halow-status` shows pending; "no retry timer" stated as pre-existing with a checklist item. |
| N-m3 TOCTOU before KILL / del | **CLOSED** | §19.3: status re-read before each kill and each del, must still be down+disabled+not pending, else rc 3. |
| N-m4 stub mechanics | **CLOSED** | Fake s1g = real process (copy of `/bin/sleep`), effect asserted, exe/Uid sed-patched, KILL branch stated untested, `wifi` stub flips asynchronously. |
| N-m5 key from the node | **CLOSED** | Read from the node's uci into a root-only 0600 file before the teardown, `--mesh -`; side effects (stray `wlh0` joins the lab mesh, 02 peer flap, joinwatch/meshled) listed; exit discipline (reboot on every exit) added. |
| N-m6 retry semantics | **CLOSED** | FAIL final, INVALID-only retries, budget and Left-node start stated. |
| N-m7 `morse.sh` evidence form | **PARTIAL** | §19.3 still paraphrases `:1121-1133` ("whose `kill_wait`, `ip link set … down 2>/dev/null`, `iw dev … del 2>/dev/null` tolerate…") and §19.7 says the lines are "quoted … (archived in the scratch run dir)". I grepped every file under `scratchpad/core/runs/` for `morse_interface_cleanup` / `kill_wait`: no hit — nothing is archived, and nothing is quoted verbatim. Fix (one paste): put the 13 + 1 lines in a fenced block in §19.3, or save `morse.sh` lines 590–600 and 1115–1140 as `runs/morse-sh-2026-10-30.txt`. Not blocking: the orphan unit's rebuild assertion is the hardware test of the same fact. |

## 2. New findings — none MAJOR or BLOCKER

MINORs, one line each:
- **m1** The ordering probe's `fast.log` prints a 4-character prefix of the mesh key (`cfgkey=1234` / `prob`); a
  probe-only artefact, but it is a key fragment in a scratch log — extend the key canary to the scratch run dirs,
  and keep rule 2's in-process comparison free of any echo (no `set -x` in setkey; compare, never print).
- **m2** Rule 2's config comparison reads `interfaces[].config.key` through `jsonfilter` into a shell variable:
  state that it is compared with `[ "$a" = "$b" ]` only (no `echo`/`logger` path exists for it) so the "never logged"
  claim is checkable in the code review.
- **m3** The ordering probe: verified by hand — `fast.log` lines 43→45: the last sample before the reload is
  `up=true pend=false cfgkey=1234`, the first after it is `up=false pend=true cfgkey=prob`, no old `up=true` sample
  after the reload; 17 pending samples, not 33 (the odd lines are busybox `sleep: invalid number '0.1'` noise, so
  the "20 Hz" is really "as fast as ubus answers" — §19.1 already says so). The conclusion stands; fix the count.

## 3. Verdict

**APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 1 PARTIAL (N-m7, evidence form) + 3 new MINORs.** All round-2 MAJORs
are closed with the mechanisms I asked for and the sources/probes support them. Implementation may start; the
PARTIAL and the MINORs are text / canary items for the PR, not design changes.
