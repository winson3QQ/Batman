# Review B — `254-v16-group1.md` v3 (2026-11-21)

Reviewer B, round 3. I reviewed the whole v3 document again, not only §10, against the worktree `C:/src/Batman-g1`
(HEAD `4b61b3c`). Read-only; no node touched.

**Verdict: APPROVE-WITH-CHANGES.** No BLOCKER and no MAJOR remains. Eight MINORs are below. They are fixes to text,
tests or small implementation points, and none needs another design round. Fold them into the implementation and
the PR.

## v2 findings — checked

| v2 | v3 | Check |
|---|---|---|
| B-M1 (forget rc 3 not retried) | ✅ rc 3 retried; leave row; test (e') | matches §19.2 recovery (`254-wireless-txn.md:561-566`); the rc 3 bound (lock 90 + settle 30 + read-back 60 s; forget 30 + 10 s) matches `halow-setkey:38-41` |
| B-M2 (dry dir lifecycle, harness `RDF`) | ✅ lock, emptied each run, no fallback to real names, `RDF` + comments in §7 | see MINOR-2 for the one gap |
| B m1–m9 | ✅ as §10 says | `set -u` confirmed (`batman-slot:38`); the `tryboot flag is` wording fixed; Pi 3 rows added; non-dry regression units listed; reproduction approved and claimed only with its log |
| A-M2 / B m4 (cause classes) | ✅ typed cause table; unknown = not retried; every 300 s class excluded | `ForgetMesh` / `SetKeyNoPersist` both return `SetkeyError{RC}` (`main.go:154-157,180-186`), so the rc is available for typing |

## MINOR

1. **§2 Security / test (g): the actor that does reach Finish is missing.** v3 says "a verb from a session that is
   not authenticated is refused before any Finish".
   - That is true for an anonymous session, but it is not the case that matters. `network/update` is allowed for
     `RoleMember` (`provd/session.go:82`), is forwarded as `net.apply` (`:87`), and reaches `finishGated` before its
     chain is verified (`node.go:268-272`). 254-wireless-txn §15.5 (`:259-262`) states this on purpose.
   - So a member-role peer, or a compromised member node, CAN trigger a Finish during the retry window. It stays
     rate-limited by the verb backoff (`wtxn.go:394-401`). Because a failed retry does not raise that backoff, the
     property is unchanged: at most one verb Finish per verb backoff, plus at most 8 retries.
   - Fix: reword the remote / BLE line, and make test (g) "an invalid-chain `network/update` from a member session
     during the retry window causes at most one Finish per verb backoff, and no extra one because of the retry". As
     written, (g) checks the anonymous case, which passes trivially and so tests nothing.
2. **§3: lock liveness ignores the dry watchdog.**
   - The dry watchdog is a separate subshell (`( revert_watchdog ) & WDPID=$!`, `batman-autocommit:428-432`). Harness
     units kill only the main pid after a timeout (`prov-ac-flap-254.sh:32`, `prov-autocommit-p3-254.sh:28`,
     `chain1-254.sh:320`: `kill $p`).
   - A main killed before its deadline leaves the watchdog alive, so v3's row "A dry run killed midway: the next one
     takes the stale lock over and empties the directory" is not what happens. The next run takes over because the
     main pid is gone, and runs `rm -rf` on the directory under a live watchdog.
   - That watchdog then writes `decided` into the new run's directory at its deadline. The new watchdog waits on a
     claim with a live owner (`:207-216`), and the old watchdog's `held()` reads the new run's markers.
   - Fix: record `WDPID` in the lock too, and take over only when both pids are gone. Alternatively, signal the old
     watchdog before emptying the directory.
   - Also close the gap between `mkdir` and the pid write: a reader in between sees no pid and takes over. Write the
     pid to a temp file inside the new lock dir and rename it, or treat "lock without a pid, younger than N s" as
     alive.
   - Test: kill the main mid-run, start the next dry run at once, and check that the two never share a file.
3. **§3 `:583` can be settled now.** DRY exits at `batman-autocommit:572` (`DRYRUN decision: COMMIT … exit 0`), before
   the claim (`:575`) and `batman-slot commit` / `rm ota-armed.mesh` (`:582-583`). Replace "to be checked in
   implementation" with that evidence.
4. **§1 `BATMAN_LIB` is a test seam that production honours.**
   - Only root runs `batman-slot`, so this is no privilege gain, and the helper's `cleanEnv` strips it
     (`main.go:76`).
   - It is still an environment variable that chooses which code a root tool sources during an OTA: in the stage-2
     env, and in an operator shell where it may be left set.
   - Fix: honour it only for a root-owned directory that is not group- or world-writable (the #280 rule), or only
     under an explicit test flag. Test: a non-root-owned `BATMAN_LIB` makes arm take the "library missing" path.
5. **§1 "Library missing → arm dies" on Pi 3 contradicts "Pi 3 keeps today's parse exactly."** Today a Pi 3 arm does
   not need the lib. Either source and check it only when `layout = pi4`, or state the Pi 3 change (Pi 3 is
   unsupported, so one line is enough).
6. **§2 retry timing must use a monotonic clock.** Boot can step the wall clock: sysfixtime, NTP, and
   `batman-faketime` on bench. `realSys.Now` is `time.Now()` (`main.go:449`), which carries a monotonic reading, so
   `Sub` / `time.Timer` are safe. Comparing stored wall times, or calling `.Round(0)` / `.UTC()`, is not. Add a
   unit test in which the fake clock steps backwards by hours between tries, and the next try still runs after 60 s.
7. **§2 cause table, edges.** State explicitly that an rc outside {2, 3, 124} is "unknown → not retried". That
   includes rc 1 and signal deaths such as 143 / 137. Tie test (e)'s "unknown cause" to one of these.
8. **§2 mutex hold.** "≤ 70 s" for the save is an estimate (`batman-config-save` waits ≤ 10 s for a live txn at `:209`,
   then writes p5). The hard bound is the 300 s Exec deadline, and rc 124 is not retried. Write "typically ≤ 70 s,
   bounded by 300 s (rc 124, not retried)".

## Re-walk of the field paths (nothing new found)

- **Slow boot, rc 2 / rc 3.** Retried, bounded at 8. A committed leave that did not forget is now retried, which
  closes the fail-open.
- **OTA while a retry is pending.** Postponed by `otaBusy()` / `IsTrial()`. `.txn` still blocks a normal OTA
  (`batman-slot:543-554`).
- **SIGTERM / respawn / power loss.** As in the table. An abandoned setkey makes the next start's try return rc 2,
  which is now retried.
- **Same-version OTA bench → bench (§1 device step).** Allowed as a reinstall (`release/release.go:399-401`).
- **Dry runs back to back.** Each starts from an empty directory under the lock. MINOR-2 is the one gap.
- **Pi 3.** Unsupported (P-U14) and layout-gated. MINOR-5.

## Security (per actor)

- **Remote / BLE peer, member-role peer, compromised provd.** No new input. The Finish rate limit is unchanged
  (MINOR-1 corrects the text and the test).
- **Local unprivileged process.** It cannot reach the run dir, `.txn`, the slot flock or `/dev/vcio`. The
  `/dev/vcio` mode is still to be captured read-only (§8 step 1: `ls -l /dev/vcio`).
- **Our own mistakes.** The bounded retries and the dry-run isolation both reduce silent harness / node drift.
  MINOR-2 and MINOR-4 close the remaining seams.
