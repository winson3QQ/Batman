# Review of 254-wireless-txn.md v14 (§19) — reviewer A, round 3 (confirmation), 2026-10-30

Read: §19 v14 whole (lines 470–714), the N1 probe raw file
`scratchpad/core/runs/race-preproprobe2541030195215/fast.log`, and the sources already read in rounds 1–2. No node
access, nothing else written.

## 1. Round-2 findings

| | status | reason |
|---|---|---|
| N1 netifd ordering assumption | **CLOSED** | Probe verified from the raw file: the last sample before the reload is `up=true pend=false` with the OLD key prefix; the very next sample is `up=false pend=true` with the NEW key in the same sample; no sample with the old `up=true` follows the reload; `up=true` returns with the new key. Rule 2 additionally compares netifd's reported `mesh_id` / `key` / `channel` in-process, so the read-back no longer depends on the ordering at all, and the stub has the "status stays old for 1 s" mutant. Two count corrections, see minors. |
| N2 dead-module status | **CLOSED** | §8 premise now "rc 3, or rc 2 when netifd is not settled"; both fail-closed. |
| N3 chanfix skip-on-unsettled | **CLOSED** | per-try settle wait ≤ 30 s under the lock, an unsettled try not counted, 5 min total deadline, shell case "pending 20 s → exactly one reassert after it". |
| N4 boot Finish rc 2, no retry timer | **CLOSED** | stated in §19.5 as pre-existing; bounded retry on the checklist; rc 2 text names the exit. |
| N5 rule 2 predicate | **CLOSED** | written down (staged `uci -q get wireless.$RADIO.disabled` ≠ 1 after the release step, probed); hand-off = disabled and not in the mark; the channel path keeps rc 3 on a blocked / hand-off radio. |
| N6 E2/E3 edges, write-mode orphan | **CLOSED** | no candidate pid → E3 + log; `(deleted)` refused; `.` escaped; the orphan unit's arm 2 records whether netifd's own setup cleans a splist orphan, and the join case is stated "not self-healing" until it does. |
| N7 §19.5 sentence | **CLOSED** | corrected (`satisfied()` short-circuits before the setkey); netifd-up in `satisfied()` on the checklist. |
| N8 orphan unit exit discipline | **CLOSED** | reboot on every exit, kill by recorded pid + del + conf removal before it; side effects and the on-air statement in the header. |
| N9 window criterion | **CLOSED** | ≥ 3 consecutive 1 Hz `pending=true` samples during the join AND the join's `read-back: netifd up after n s` with n ≥ 3; FAIL final, INVALID-only retries. |

## 2. New findings
No BLOCKER, no MAJOR. Minors (one line each):
- §19.1 probe numbers: the raw file has **17** `pend=true` samples, not 33, and 340 lines includes the probe's own
  `sleep: invalid number` lines — the real sample count is ≈ 170 over ~17 s (≈ 10 Hz). The conclusion is unchanged.
- The probe log keeps a 4-character prefix of each key (`cfgkey=1234…` / `cfgkey=prob…`, lab / probe keys, scratch
  dir); fine for a scratch probe, and the §19.6 canary rule already covers the DV units — just do not copy the
  probe's field into a unit.
- §19.2 rule 1 still says chanfix "skips the try when not settled"; §19.5 now says it waits ≤ 30 s per try — align
  the rule-1 sentence with §19.5.

## 3. Verdict
**APPROVE.** The design states ownership (netifd; setkey's single guarded exception), every contract (rc 0/2/3,
status fields and their missing/malformed cases, the kill target's identity), the lifecycle paths with their tests,
and marks the remaining assumptions ⚠️ with the unit that will decide them. Every round-1 and round-2 finding is
closed with evidence or an honest statement. Implementation can start per §19.6; the three minors are text fixes
for the same commit.
