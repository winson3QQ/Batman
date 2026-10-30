# Review of 254-wireless-txn.md v13 (§19 revised) — reviewer B, round 2 (2026-10-30)

Scope: the whole design re-read (§1–§18 unchanged since round 1; §19 lines 470–657 new). Same rules as round 1.
Read-only; no node access. Evidence base as in `wtxn-review-v12-B.md` (sources, captures, probes) plus the author's
read-only probes reported for v13 (phy map, busybox `pgrep -f` anchoring and the `ash` self-match, `/proc/<pid>/exe`,
mesh11sd). ⚠️ still not on disk here: netifd `wireless.c`, `/lib/netifd/wireless/morse.sh` (`:594`, `:1121-1133`
are cited from the author's read on 04).

## 1. Disposition of my v12 findings

| v12 | status | reason |
|---|---|---|
| B-M1 settle fail-open | **CLOSED** | Rule 1: gate after the lock, before any uci / mark write, rc 2 on deadline / unreadable status, every write mode incl. `--forget-mesh`; helper mapping verified against `node.go:1157-1160` (join rc 2 → RemoveTxn + EApply), `wtxn.go:329-331` (Finish rc 2 → `.txn` kept + backoff), `node.go:1212-1217` (leave → EApply 21); chanfix sources the gate and skips. Residual stated in N-m2 (a netifd that never settles). |
| B-M2 orphan fidelity + rebuild unproven | **CLOSED** (one MINOR left, N-m5) | Orphan rebuilt as the real one (`wlh0`, phy from `phy80211`, splist written as `morse.sh:594`), INVALID if it does not exist, rebuild asserted on hardware (`--mesh … --channel 40` → rc 0, `up=true pending=false`, `meshjoin_radio_up`, 02 neighbour ≤ 180 s), side effects listed, conf 0700 + removed. The rebuild assertion does prove the post-escalation `wifi reload`: the state it starts from (uci `disabled=1` + mark + placeholder, stale splist, no netdev, no s1g) is exactly what E2/E3 leave behind. |
| B-M3 PASS without window | **PARTIAL** → N-M1 | An INVALID rule exists, but its criterion does not discriminate on the fixed code (see N-M1). The forced-window arm was not taken. |
| B-m1 mechanism / read-back order / stub | CLOSED | §19.1 now states the OLD netdev; rule 2 checks netifd first; stub keeps the old netdev while pending. |
| B-m2 `retry_setup_failed` | CLOSED | rule 2 + case (f). |
| B-m3 guard `pending=false`, hand-made netdevs, lifecycle rows | CLOSED | §19.3 orphan definition, ownership paragraph, crash / netifd-restart rows. |
| B-m4 exe + Uid, TERM/KILL, no `sh -c` | CLOSED | §19.3 E2 + case (g); the `ash` self-match was reproduced on 04. One TOCTOU gap left: N-m3. |
| B-m5 budgets / client timeout | CLOSED | §19.4: 180 / 165 s, timeout = "unknown, re-read info", `pr_pc` ≥ 240 s via harness PR. |
| B-m6 `info.net` `unfinished` | CLOSED (P2 checklist) | as recorded in §19.4 / §19.7. |
| B-m7 chanfix copy | CLOSED | `/usr/lib/batman/wireless-settle.sh` sourced by both. Skip semantics: N-m1. |
| B-m8 §6 / §8 text | CLOSED | §19.5 "updates elsewhere" (the §6 line itself still reads "both within 2 s" — the pointer is enough). |

## 2. New findings

### N-M1 (MAJOR) — the black-box unit's INVALID criterion is satisfied on every run of the fixed code, so it never fires.
§19.6: INVALID unless the sampler shows netifd `pending=true` "in the sample before the join's setkey returned, or
at the forget's start". With rule 2 the join's setkey *always* waits through its own reload (`pending=true` for ≥ 2–4 s,
`wl.log` 87–88 even on the run that did not open the window would show `pending=true` while the join waited), so the
first clause is true on every run; the second can never be true (the forget cannot start while the join's setkey
holds the lock and waits). The rule therefore degenerates to "always PASS", which is the B-M3 situation again with an
INVALID label that never appears. The discriminating fact on 04 was the *length* of netifd's teardown+setup after the
B-trial-rollback reboot (3 s teardown + setup, 4/5) versus the idle boot (≤ 1–2 s, repro 3).
Fix: define the window by duration, measured on the fixed code: INVALID unless the sampler shows the morse radio
`pending=true` for ≥ 3 consecutive 1 Hz samples during the join (the condition under which the shipped setkey returned
rc 0 ≥ 2 s before `up=true`, i.e. the leave's forget would have landed inside the setup), and the join's setkey log
line (add one: `read-back: netifd up after <n> s`) reports n ≥ 3. Keep "a FAIL ends the unit; only INVALID retries"
(N-m6). Add the cheap forced-window arm (leave right after a `wifi reload` on a loaded node) so the unit does not
depend on the unexplained slow-teardown boot.

### N-M2 (MAJOR) — rule 2's "radio blocked / switched off by hand → uci-only read-back, as today" silently changes the `--channel` rc contract that §8, §16.5 and §17.3 rely on.
Today the channel path (`halow-setkey:241-266`) can only verify through `morse_cli` on a mesh netdev; with the radio
off it ends rc 3 "unverified" (the §8 premise "setkey with the radio off returns rc 3", `radiooff.sh`; the helper always
passes the channel on a restore, `SetKeyNoPersist` with the snapshot's `ch`, `main.go:146-159`), and `finish()`
converts rc 3 + hand-off + `uciIs` into "applied, not verified on the air" (`wtxn.go:324-328`; §16.5; test of §17.3
"hand-disabled radio with setkey rc 3 and uci NOT at the previous state is a failure"). Rule 2 as written ("the
read-back is uci-only as today") would make that case rc 0 — "applied" for a channel the radio never accepted (morse
can write its default back when it rejects one, `99-batman-chanfix:4-9`; that is why the channel path verifies at
all). The §16.5 branch becomes dead code, the §8 premise test flips, and §15.4's principle (uci alone cannot tell
"applied" from "applied but not verified") is breached for the channel. Scenario: join refused? no — the pre-check
(`node.go:1116-1118`) refuses a join on a hand-off radio, but a Finish restore of a snapshot with a channel onto a radio
the operator switched off *during* the change (§16.5's own case) now reports rc 0 and the record says the previous
channel is live when uci may hold morse's rewrite. Also `--mesh-id alone` with a real key on an enabled radio is not
"blocked" — the scope rule must be computed, not listed.
Fix: define the scope by the committed uci after the release step: morse radio `disabled` absent → rule 2 (netifd
`up=true pending=false`, then CENTRE_KHZ with `--channel`); `disabled=1` (blocked or hand-off) → non-channel path:
uci-only rc 0 as today; **channel path: rc 3 "unverified (radio down)" as today**, so §16.5 / §8 / §17.3 stay true.
State it in §16.5 and §8. Shell case (e) then covers `--ap` alone and `--mesh-id` alone with the placeholder; add
`--channel` on a disabled radio → rc 3, uci unchanged by the revert step? (today's code reverts the channel only when
uci no longer holds it, `:254-260` — unchanged).

### N-m1 (MINOR) — chanfix "skip this try" must count as a try, or the loop can spin.
`99-batman-chanfix:63-79` increments `a` only after a reassert; a skipped try that does not increment keeps the
`while [ "$a" -lt 6 ]` loop alive for as long as netifd is pending (a wedged first-boot setup → forever, holding
nothing but burning a `sleep 8` loop and the gate's 30 s poll under the lock each round). Fix: `a=$((a+1))` on skip
too, plus a total deadline (e.g. 10 min) for the whole loop; log the skip.

### N-m2 (MINOR) — a netifd that never settles: state the exit and surface it.
With rule 1, a radio whose setup script hangs (driver wedged; the §16.1 D-state class) is `pending=true` forever:
every setkey is rc 2, a committed leave never forgets (`Left` in p5, the network key still on the air), joins are
refused, Finish attempts back off to 30 min. Fail-closed is right (v12's reload would not have helped either), but the
operator has no signal except EApply 21 / EState 22 texts, and the boot Finish is not re-run by any timer (only by a
verb or the next boot — pre-existing, §4.3 "the backoff starts" reads as if it retried). Fix: `halow-status` prints
netifd's `pending` and how long (from the gate's log line), the rc 2 text says "if this persists, reboot the node"
(the known exit; `.txn` is finished at boot), and §4.3 says plainly that a failed Finish is retried on the next verb
or boot, not by a timer.

### N-m3 (MINOR) — E2/E3 TOCTOU: re-read netifd's status before KILL and before `iw dev del`, not only `exe`.
§19.3 re-checks `exe` before `kill -KILL` (pid reuse). The residual it names (an operator's `wifi up` between the
status read and the kill) is exactly the case where `exe` matches again (netifd's fresh s1g on `wlh0`) and the
`iw dev del` would delete netifd's new netdev under a running setup — two writers. Cheap closure: before KILL and
before `iw dev del`, re-read `ubus … status` and require the morse radio still `up=false disabled=true pending=false`;
if not, stop the escalation (rc 3, "netifd took the radio back"). Shell case (d) variant: status flips to pending
between TERM and KILL → no KILL, no del.

### N-m4 (MINOR) — shell cases (c)(g): what the stubs can and cannot model.
`kill` is an ash builtin: a `$ST/bin/kill` stub is never called, so "recording kill" needs the product to invoke
`/bin/kill` (or `busybox kill`) explicitly — say so, or assert the effect instead: the fake s1g must be a real
process whose `/proc/<pid>/exe` is the product's expected path. A script cannot be that (its `exe` is the
interpreter); use a copy of `/bin/sleep` installed as `$ST/bin/wpa_supplicant_s1g`, run with argv `… -i wlh0`, and
sed-patch the test copy's exe path and the `Uid: 0` check to the test uid (the stubs run non-root). The KILL branch
(a process ignoring TERM) cannot be modelled this way without root; mark it "covered by the root `prov_test` run or
not covered". The decoy (g) then = a `sleep` with the right argv but the wrong path / a different name.

### N-m5 (MINOR) — the orphan unit's rebuild key must come from the node, never from the harness.
§19.6 restores with "`--mesh <lab key> --mesh-id openmanet1 --channel 40`". The probes (`race-node.sh`,
`orphan-node.sh`) carry the lab key literally; a harness unit must not (lab key = private repo, F14/#13). Fix: the
unit reads the committed key/mesh id/channel from uci on the node into a root-only 0600 file in the run dir BEFORE the
teardown, restores from it (`--mesh -` on stdin), removes it; the key canary (`prov-netjoin-254:40`) covers the host
run dir of this unit as §19.6 says. Also list under side effects that the stray `wlh0` really joins the lab mesh (02
sees 04 peer, leave, peer again within ~2 min) and that joinwatch / meshled will log KEY PLACEHOLDER / DARK during it.

### N-m6 (MINOR) — black-box unit retry semantics.
"Retries up to 3 times" must apply to INVALID only; a FAIL (code 21/22, orphan present) ends the unit — otherwise a
retry can mask a real failure as "INVALID then PASS". Budget: 3 × (OTA B + back_to_a + join/leave) ≈ 25–30 min —
say it, and say the second and third tries start from a left (claimed) node, which `net.apply` re-joins (clears
`Left`, `node.go:1137`).

### N-m7 (MINOR) — evidence form for the two `morse.sh` citations.
`morse.sh:594` (splist write) and `:1121-1133` (cleanup tolerant of a missing name) are "read on 04"; the file is not in
either repo. Per the evidence rule, quote the 13 + 1 lines in §19.3 (or archive the probe output next to the repro
logs) so the next reviewer can check them without node access.

## 3. Attack walk (real use) — checked and sound in v13

- **Settle gate rc 2, boot Finish**: `BootFinish` → `waitRadioUp` ≤ 120 s (network case only) → setkey gate ≤ 30 s
  → rc 2 → `.txn` kept, backoff, retried on the next saving verb or boot. A forget at boot never meets a pending
  radio (uci `disabled=1`). No lockout: a verb after the backoff runs a fresh attempt.
- **Leave, forget rc 2**: record committed `Left`; EApply 21 "retry"; the first retry runs a real Finish at once
  (`finishFails` is 0 — the leave's own ForgetMesh failure does not call `noteFinish`), later retries within the
  backoff get EState at once; one attempt per backoff. A retry storm cannot lock the node out of leaving; it can only
  delay the forget to the next settled attempt. The key stays on the air meanwhile — stated in rule 3; the
  never-settling case is N-m2.
- **Two owners / two phones**: serialised by the helper mutex and the setkey lock; the second verb sees a settled
  radio or waits ≤ 30 s.
- **Rule 2 for `--ap` alone**: the AP radio is `radio0`; the gate and the read-back look at the morse radio only, and
  `wifi reload` on an unchanged radio1 does not make it pending (case (i)).
- **Orphan definition** (mesh point on the morse phy while netifd reports down+disabled+not pending) is the right
  invariant: with `disabled=1` committed netifd will not start a setup on its own, so anything on that phy is not
  netifd's. The phy mapping by `device` symlink = `wireless.<radio>.path` was probed; unresolvable → rc 3 (closed).
- **E2 exe/Uid/TERM-KILL**: an argv impostor is ignored; pid reuse by a non-s1g is caught by the `exe` re-check;
  reuse by netifd's own fresh s1g is the N-m3 residual. Secrets: the log carries names/pids; the ubus blob (holds the
  key in `config`) is never logged.
- **`/var/state` not edited**: correct choice — editing netifd's state file behind it would be a second writer; the
  stale entry is tolerated by the cleanup (⚠️ per the author's read, N-m7) and the orphan unit's rebuild assertion
  is the hardware proof; if that assertion fails, the design already says the escalation must clear the entry.
- **Downgrade**: an older image's setkey behaves as today; nothing in `.txn` / p5 / uci changed format. Upgrade with
  an orphan: cleared by the reboot. Pi 3: n/a (owner decision).
- **Shell cases (a)(b)(d)(e)(f)(h)(i)** are modellable with the stubs described (asynchronous `pending` needs the
  `wifi` stub to spawn a timer that flips `pending`/`up` — say so); (c)(g) per N-m4.

## 4. Verdict

**APPROVE-WITH-CHANGES — 0 BLOCKER / 2 MAJOR / 7 MINOR.** The fix itself (rule 1 fail-closed, rule 3 escalation
with the exe/Uid guard, the faithful orphan unit with the hardware rebuild assertion) is sound and closes B-M1/B-M2.
Before implementation: N-M1 (an INVALID criterion that can actually fire: window = pending duration ≥ 3 samples, plus
a forced-window arm) and N-M2 (rule 2's scope computed from committed uci; the channel path keeps rc 3 on a radio
that will not come up, so §8 / §16.5 / §17.3 stay true). The MINORs are one-line contract and test-mechanics fixes;
N-m3 is the only one that touches the two-writers invariant and is cheap to close.
