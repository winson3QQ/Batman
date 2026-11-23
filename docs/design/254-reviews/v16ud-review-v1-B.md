# Review v1 (reviewer B) — `docs/design/254-v16-ud.md` draft v1 (7f58327)

Scope: the whole design, read against the source at 7f58327 (`git diff b885a2c HEAD -- feed/` empty, so `feed/` = wsl.36),
the harness at `test/254-v16-group4`, the wsl.36 payload in `~/out` (read-only), and the archived wsl.22 run. No node,
phone or device was touched. Emphasis given: lifecycle (host death, power loss, helper / provd restarts), restore to
the base state, slot guards and lints, security as a compromised uid-471 provd and a local unprivileged process,
honesty of durations and side effects.

## What I verified and agree with

- §0.1-1 provclient bug: `p3.go:155-162` sends `{1: manifest}` only; `update.go:254-263` requires key 2; `bulk-open`
  sends `{1: 0}` (`p3.go:421`) while `bulk.go:48-51` requires key 2. Correct.
- §0.1-5 UD8 / UD8c are refused in the first pass, no slot touched (`updwork.go:349-359`, `:499-611`). Correct.
- BAD is durable before the first rootfs byte: `begin_write` → `invalidate_slot` writes cmdline + BATMAN-BAD and `sync`s,
  `tboot_close` syncs + umounts (`batman-slot:406-411, 462, 468-473`). A sysrq after `dd` started leaves `bad=1`.
- §0.1-6 code fact: pending is memory only (`update.go:366`), so after a restart status is 0 + 23 (`updwork.go:913`).
  But see MAJOR-5: that is not the whole requirement.
- wsl.36 payload: `metadata` has `release=1.5.14-wsl.36+b885a2c.fw302c80b.bench`, 365 tar members, 361 SHA256SUMS
  lines, size 127,292,688 B (read from `~/out/1.5.14-wsl.36…bench/ekh-bcm2711/`).
- Hold-commit is still reverted at the deadline (`batman-autocommit:209-213, 242-247, 586-589`).

## Findings

### BLOCKER-1 — `update-last` (p6) is neither snapshotted nor restored: every write / kill / trial arm leaves the bench node in a changed, user-visible state that the restore compare cannot see

Scenario. `update.prepare` writes `/opt/batdata/state/update-last` before the worker starts (`updwork.go:229-232`);
`update.apply` rewrites it (`:720-757`). The harness snapshot / restore covers only `STATEFILES`
(`scripts/node/prov-base-254.sh:36`: lock-status … autocommit.timeout — **no `update-last`**), restored at `:273-275`,
compared via `state_record` (`:100-104`). `grep -rn update-last scripts/ tests/` finds nothing but a p3-units text row.
After the write arm the last prepare is UD10b (sha X = sha of V's SHA256SUMS, from A, `apply_boot_id` empty). `pr_end
wrote-b` then rewrites B with V by sysupgrade, and `write_slot` records `BATMAN-VERIFIED = <sha256(SHA256SUMS)> <boot>`
(`batman-slot:732-733`) — the **same X**. From then on, on A committed: `act == FromSlot`, `bad=0`, verified prefix = X
→ `update.status` = **0 + 23** "new version written but not activated, please update again" (`updwork.go:913-914`)
permanently, for the app and every later unit. The kill arm ends the same way. The trial arm ends at row 8 (0, but with
`sha` / `to_version` set).
Consequences: (a) the bench base state drifts after this PR's first device run, undetected (`diffs=0`); (b) the design's
own UD7 assertion "no pending (`update.status` phase 0, **no sha**)" FAILs on any run after a write arm (the sha comes
from update-last, `updwork.go:886-887`); (c) an owner looking at 04 in the app sees a stale "re-update" prompt.
Evidence: above; §2 lists `update-last` as "the helper; unit via update.status only" — the harness never owns its
restore.
Fix: add `update-last` to `STATEFILES` (bring `scripts/node/prov-base-254.sh` into the scope list), so snap records
"absent" and overlay-restore deletes it; assert in `pr_end` that `update.status` after the restore equals the
pre-snapshot answer (read it in `pr_begin`). Negative control (offline, `PROV_BASE_TEST_ROOT`): a tree with an
`update-last` created after `snap` → compare must report a DIFF; without the STATEFILES change it reports `diffs=0`.

### MAJOR-1 — UD4 / UD5 cannot reach phase 3: the "existing" `badpayload` repacks with `tar -C . `, which the worker refuses

Scenario. `p3-payloads.sh:57`: `tar -czf "$bp_out" -C "$t/p" .` → members named `./`, `./SHA256SUMS`, … in readdir
order. The worker requires member 1 named exactly `SHA256SUMS`, member 2 `metadata` (`updwork.go:484-496, 509`), and
directory members only `boot/` / `boot/overlays/` (`:548`). The real payload is built in that exact order without
`./` (`scripts/build-ab-payload.sh:88-90`; confirmed on the wsl.36 tar). So UD4's prepare ends in phase 0 + 11 in the
first pass, UD4's P ("phase 3 before apply") FAILs, and UD5 (which is defined as UD4's answer) goes with it. The design
says "`p3-payloads.sh badpayload` of V (exists)" — an unverified premise.
The same trap applies to every new generator (`malicious 1..4`, `mutate`, `swapy`): any `tar` call that does not
reproduce `SHA256SUMS metadata boot root.squashfs` order and names will be refused by the first member check — and
because the expected answer of UD8 / UD8c **is** 11, such a generator bug PASSes silently (see MAJOR-2).
Fix: generators repack with the exact `build-ab-payload.sh` order (`tar -C d -czf out SHA256SUMS metadata boot
root.squashfs`, plus the named deviation), and their acceptance compares `tar -tvf out` against `tar -tvf V` (names,
order, types) and must show exactly the one intended difference. Negative control: the current `badpayload` output must
FAIL that acceptance.

### MAJOR-2 — every refusal row's reason is 11, so the rows do not say which rule fired; a broken generator or manifest PASSes

Scenario. UD7 has four arms answering 11 (`--bad-sig`, `--key other`, `--serial 0`, `--unparsable-version`); UD8 has four
and UD8c one, all 11 (`updwork.go:471`, every `bad(...)`). The per-row "discrimination" offered is "differs from V
only in the named point". For UD7 that holds if the manifest really is V's plus one option (the flip). For UD8 /
UD8c it does not: a generator defect (MAJOR-1's `./` names, a wrong gzip trailer, a mutant whose length is off so the
size check in `work` at `:313-315` answers **15** instead…) gives 11 for a different rule. UD8 (4) in particular: V has
exactly `len(list)+4` members (361 + 4 = 365); adding an unlisted *file* is refused first by "not listed" (`:575-577`),
not by the count rule (`:543-546`) the row names; only extra *directory* members (`boot/overlays/` repeated) reach the
count rule.
Evidence: the helper logs the reason text for every refusal: `update.check: refused, reason %d (%s)` (`update.go:269`),
`update worker: %s refused, reason %d (%s)` (`updwork.go:291`).
Fix: each refusal sub-row also asserts its own `why` text from `logread` (between a `logger` mark and the answer, as
`lg_mark` / `lg_log` do), e.g. UD8 (1) "is not a regular file", (2) "members after root.squashfs", (3) "data after the
gzip stream", (4) "too many members", UD8c "root.squashfs does not match SHA256SUMS", UD7 serial "serial". No line / a
different text → FAIL. The why strings contain no secrets.

### MAJOR-3 — UD7 `--serial 0` cannot be produced: signrel refuses it, and §3 lists no signrel change

`tests/tools/peer/signrel.py:375-376`: `if a.serial < 1: ap.error("--serial must be >= 1")`. The owner's Q2 answer
("`--serial 0` accepted") rests on an arm the tool cannot build. Fix: add a deliberately named option (e.g.
`--unsafe-serial 0`) to §3 with its own selftest, or drop the serial arm and say so. Also: the row text says "seven
update.check calls" and then lists eight kinds.

### MAJOR-4 — UD20c's P ("status shows sha Y") and UD7's "no pending" are unobservable through `update.status`

Scenario. Without a window, worker or failure, `update.status` shows a pending's sha only when the target is verified
for it in this boot (`updwork.go:860-879`); otherwise it falls to update-last or to `progress(0,0,0,nil,"")`. After
UD20c's swap (no window), status is "0, no sha" whether the pending is X, Y or gone — the P cannot pass. UD7's
"no pending" is the same answer with or without a pending (and the P arm itself **creates** a pending V, so "no
pending" is false anyway). A presence/absence check that cannot differ is not a test.
Fix: UD20c P = after the swap, the owner's `bulk-open Y` succeeds (proves pending = Y of this owner), then `bulk-close`,
then the refusal arms (`bulk-open X` → 15, `update-prepare X` → 15); during the second arm (window open) status phase 1
does show the pending sha, which is observable. UD7: replace "no pending" with "the refusals did not replace the P's
pending": `bulk-open V` still succeeds after the eight refusals, then `bulk-close`.

### MAJOR-5 — UD10 (Q3): neither "3" nor "0 + 23" alone is the requirement; P3 v7.13 specifies "pending lost, owner re-checks, phase 3 again, apply usable without re-upload"

Evidence. `254-p3-impl.md:396` (v7.13, r1 A-m2): "只在記憶體:helper 重啟 = pending 消失,擁有者重新 `update/check`,已寫好且
VERIFIED 為本次開機的槽仍可直接 apply"; `:929`: "helper 重啟後(記憶體清空)pending 與 VERIFIED 都在 → apply 可用"; `:735`:
"helper 重啟後 phase 3 重建". `:424` and `:872`: 23 when the pending has **expired**. The code does what v7.13 says:
a fresh `update.check` recreates the pending; row 4 (`updwork.go:878-879`) then answers 3; `update.apply` checks the
slot, not memory (`:695-711`). So A.9's "3" is the state *after the re-check*, and "0 + 23" is the state between the
restart and the re-check. The design asserts only the latter plus `apply → 15`, which misses the requirement that
matters in the field (an app whose helper restarted can finish without a 127 MB re-upload).
Also: right after a restart the bootinfo cache is empty; until the tick fills it (`updwork.go:943-946`) status falls
to `st(0, 0)` (`:913` needs `haveSI`). A single status read can FAIL spuriously.
Fix: UD10 = restart → poll status until 0 + 23 (bounded, e.g. 60 s; a final 0 without reason = FAIL) → owner
`update.check V` → status 3 with no upload → `update-apply` of a *different* sha → 15 (guarded, MAJOR-6). The positive
"apply usable after restart" fits naturally into UD1: do UD10's restart + re-check inside UD1 before its apply, so the
trial that follows is the proof. UD10b keeps 0 + 23 (verified belongs to the old boot, `:878`) plus a re-check that
stays 0 + 23 and an apply → 15.

### MAJOR-6 — the slot-writing and arming verbs are not all guarded or linted; the guards conflict with the design's own probes

1. `update-prepare` writes the *other* slot (`updwork.go:228-229, 345`; `batman-slot write`). If the node is
   unexpectedly on B (UD1 committed B and `back_to_a` failed, an earlier step mis-landed), the next prepare writes
   **A** — in UD4's case a panicking rootfs, VERIFIED and bootable by firmware fallback (`254-p3-impl.md:425`), a latent
   brick that `pr_brewrite` (B only) never repairs. Nothing in §4 checks the state before a prepare, and lint (1)'s
   regex (`test-slot-guard-254.sh:458-460`) does not know `update-prepare`. Fix: `prepare_guarded` (boot / A / trial 1,
   same shape as `apply_guarded`), lint (1) pattern `update-prepare`, lint (2) pins.
2. UD10 / UD10b send `update-apply X` expecting 15. With the new lint pattern these are FAILs unless allowlisted, and
   an allowlisted unguarded apply is exactly the case where a product bug (accepting it) arms and reboots 04 mid-arm.
   Fix: those probes also go through `apply_guarded`; the expected answer is checked after.
3. `apply_guarded` "prints a node-side command that runs provclient … update-apply". `update-apply` is an owner-op: it
   needs `pr_pc`'s SIGN round-trip (`prov-254.sh:808-833`), whose command line is `envs provclient node $*` plus
   `PRE`/`POST`. A guard that wraps provclient needs a new `pr_pc` form (e.g. `GUARD=<cond>`: `if cond; then provclient …;
   else echo WRONG-STATE …; fi`). State it, and state that a lost answer after the guard is "outcome unknown" (the
   product reboots 2 s after replying, `updwork.go:758-760`).
4. `slot-sites.tsv` (lint 3) needs the sysrq row and every new `text` line containing the word `reboot`.

### MAJOR-7 — the abort / exit restore path does not know B was written: an abort after any prepare ends in NEEDS-PERSON

`PR_WROTE_B` is set only inside `pr_ota_b` (`prov-254.sh:371`) or by `pr_end wrote-b` at the very end (`:588`). The app
path never calls `pr_ota_b`. `pr_abort` (`:575-584`, also reached from the EXIT trap `:732-738`) calls `pr_restore`,
whose compare ignores the `protB` DIFF only when `PR_WROTE_B = 1` (`:494`); `begin_write` deleted `slot-B.protected`
(`batman-slot:479`), so the compare FAILs → "S0 not restored" → NEEDS-PERSON, and the brewrite (`:580`) is skipped.
In the trial arm, an abort while on B **committed** (UD1 after commit) hits `pr_restore_cycle`'s "not on A committed"
(`:465-466`): NEEDS-PERSON again.
Fix: set `PR_WROTE_B=1` immediately before the first `update-prepare` of an arm (the worker may reach `begin_write`);
in the abort path, `back_to_a` when on B committed (it already handles B committed, `:395-405`). Offline test with the
stubbed `pr_*`: an abort after a stub prepare must call `pr_brewrite`.

### MAJOR-8 — host death mid-arm: the design relies on P9 checks that do not exist and skips the undo journal

1. §2 "Shell fault files: P9 checks none exist" and §5 "(d) … P9 reports `bad=1`" are false: `scripts/node/prov-p9-254.sh`
   checks the dirty flag, `bad-slot` (autocommit's file), wbox stamps, leases, binds — **not** BATMAN-BAD, not
   `/tmp/batman-fault.*`, not the hold flag, not `update-last`. The "offline: P9 stub with `bad=1` B" proof tests a
   check that is not there.
2. The harness has an undo journal executed by the dead-man (`prov-lease-254.sh:17-21`; `prov-undo-lib-254.sh`
   actions incl. `uci-revert <pkg>`, segment 1 removes shell faults). The design registers nothing. Concretely after a
   host death: UD13 / UD6's staged `uci set` stays in `/tmp/.uci` until a reboot; any `uci commit` of that package by
   the product commits the harness value, and a staged change on `wireless.default_radio0.ssid` (a P3-new key,
   `status.go:65`) is **saved into p5** by the next `update.check`'s PreSave (`update.go:308`; `status.go:134-144`).
   Q6's AP change and Q1's fault file have the same gap.
3. The dead-man fires only after the arm's whole budget + 5 s (`pr_begin <secs>`): with a 2-h trial budget the node
   carries the staged state for up to 2 h with nobody watching.
Fix: `undo-add uci-revert wireless` / `<pkg>` **before** each `uci set` (the journal requires registration first);
the same for the hold flag (rm-file under the allowed paths, or a new closed-list action) and the AP; add P9 lines
for BATMAN-BAD on the non-active slot (`batman-slot bootinfo`), `/tmp/batman-fault.*`, a stale hold flag and
`update-last` ≠ snapshot; or drop the claims. Lifecycle row "host crash" then gets a device-free offline proof:
stubbed dead-man + journal replay.

### MAJOR-9 — UD9 (Q1): the host-timed cut is not "mid-write" as described; with `kill -9` the product leaves an orphan writer; my judgement on `write-hang`

1. "`update.status` percent ≥ 50" carries no position: `workPct` is set to 50 once, when the second pass starts
   (`updwork.go:366-368`), and never again. It is 50 from before `begin_write` to the end of `write_slot`.
2. The premise "the way prov-base-254 row 32 already does" is wrong: row 32 is timed **on the node** (a node-side loop
   on `pidof dd`, `slot-sites.tsv:97`), not from the host.
3. `dd of=$TROOT bs=1M conv=fsync` (`batman-slot:856`) writes into the page cache and fsyncs at the end: most of the
   117 MB may be "written" in a few seconds (bounded by the helper's gunzip + sha256 on a Pi 4 without ARMv8 crypto),
   then `dd` sits in fsync. A host poll over ssh (≈ 1 s per round) can land anywhere in that window; "dd was running" does
   not mean "half the rootfs reached the card".
4. `kill -9` of the helper does not stop the write: `ExecSplit` uses `Setpgid` and no `Pdeathsig`
   (`provstore/exec.go:93`); the orphan `batman-slot write` reads EOF on its stdin pipe, `dd` exits 0 short, `write_slot`
   verifies, fails, invalidates (`batman-slot:760-771`) — holding the slot flock throughout. Until it exits, the new
   helper's bootinfo gets rc 14, the cache stays empty and status is `0` (no reason, `updwork.go:913-917`), not 22. The
   assertion must poll (bounded by the orphan's life) and the kill sub-arm should also assert the lock is freed after the
   orphan ends (UD-L for a SIGKILLed parent: the claim at `batman-slot:101-104`).
5. Q1 judgement: `write-hang` (`batman-slot:855`, honoured only as a root-owned single-link `/tmp/batman-fault.write-hang`,
   `:92-97`) parks **after** `begin_write` + `clear_root` and **before** the stream: a deterministic point, but "nothing
   streamed", not "mid-write". For the **sysrq** sub-arm it is sound (tmpfs flag gone with the reboot). For the **kill**
   sub-arm it is harmful: the orphan is `sleep 3600` holding fd 9 (the helper's 600 s timeout died with the helper), so
   the slot lock is held for an hour — blocking the next sub-arm, autocommit and `pr_brewrite`. It is also a new
   `/tmp` path for the tmp-trust lint and must be in the undo journal.
   Recommended instead (no product seam, mid-write, deterministic enough): a node-side watcher started in the same ssh
   command as the prepare, as root: find the `dd` whose parent is a uid-0 `batman-slot write` (cmdline from `/proc`),
   poll `/proc/<dd>/fdinfo/1` `pos:` every 20 ms, fire (helper pid from `ubus call service list`, `/proc/<pid>/exe =
   /usr/bin/batman-provhelper`, uid 0; or `sysrq b`) when `pos ≥ SQ_BYTES/2`, and print the pos before / after.
   `dd` already past the end or not found within the window → INVALID "cut missed". Use `write-hang` only as the
   fallback for the sysrq sub-arm.

### MINOR-1 — durations and reboots are undercounted

`pr_brewrite` = sysupgrade trial + `back_to_a` = 2 reboots plus a 127 MB scp (`prov-254.sh:503-512, 352-393`). Count:
refuse 1; write: UD10b + restore + 2 = 4; kill: sysrq + restore + 2 = 4; trial: (UD2 apply, revert) + (UD4 apply,
panic) + (UD1 apply, `back_to_a`) + restore + 2 = 9. Total 18, not ~15. Also say plainly that UD4 is the first
device run of a panicking trial (A8, E-H13 never run): if `panic=10` (`batman-slot:51`) or the tryboot fallback does not
bring 04 back, a person power-cycles 04, and UD1 does not run that day.

### MINOR-2 — §6 "no port, no listener" is false

Every `bulk.open` makes provd bind its HTTP listener on the phone AP for the window (≤ 900 s, `bulk.go:13`) and kill
every member session (`provd/http.go:264-276`, `httpKillMembers`). The control is that the bearer (key 6) is never
printed or known to anyone. State this side effect (UD8 ×4, UD8b, UD8c, UD20, UD20c, UD6, UD9 ×2, UD2, UD4, UD1 each
open one), and add it to the attack-surface delta.

### MINOR-3 — `sysrq b` is a hard reset, not a power loss

The SD card keeps power and finishes its own writes; only the page cache is lost. Call it that, and state the side effect
on the committed slot's overlay and p6 (journal replay). A real power cut is not covered.

### MINOR-4 — Q4: the archive is valid only in part

`update.status` takes no argument, so its `code=20` on wsl.22 is an unambiguous "verb missing". `update.check` code 20
is ambiguous (missing key 2 vs unknown verb, `node.go:178-182` vs `:308`). `bulk.*`, `update.prepare`, `update.apply`
were never called on wsl.22. Better W, no rebuild: the archive's `update.status` line plus source:
`git show 2ecf1cb:feed/batman-prov/src/node/node.go | grep -c 'update\.\|bulk\.'` = 0 (checked). The archive lives in an
untracked local directory (`C:/Users/yello/batman-validation/h5-p3-11081227`): copy the log into the PR evidence with its
sha256. Re-running W after the provclient fix would not change the code (unknown verb), so there is nothing to gain.

### MINOR-5 — Q8 contradicts the scope ("nothing under `feed/` changes")

A `_test.go` under `feed/` is a file under `feed/`. The same black-box proof fits outside: a test module under
`tests/tools/provclient/` with `replace batman-prov => ../../../feed/batman-prov/src`, driving `node.New`
(`node.go:169`) with its own fakes. Recommend that, not Q8's exception.

### MINOR-6 — tmp-trust lint and root reads of a 471-writable file

`check-tmp-trust.sh` scans `scripts/*.sh` as a git pathspec, which includes `scripts/dv/` (the allowlist already has
`scripts/dv/…` rows, `tmp-trust-allowlist.txt:139-142`). The new literal `/tmp/run/batman-provd-bulk/payload`, any
`/tmp/.uci` check and the Q1 fault file need entries with reasons. Root must never `open()` the upload (a FIFO planted by
a compromised provd hangs `wc` / `sha256sum`): `stat` / `ls -ln` as root only, content reads as 471 under `timeout`.
Before UD13's `uci set`, assert `/tmp/.uci` is root's 0700 non-symlink dir (the helper's own rule, `status.go:90-94`).

### MINOR-7 — UD13 (b) and UD6 (b) do not discriminate "unsafe" from "stale"

Both stale and unpersistable values give `die_c 12` → 17 (`batman-slot:570-576`). UD13 (b) must assert the
"forbidden characters" / "unpersistable" text (helper log, MAJOR-2 mechanism). The UD13 / UD6 key must not be
`wireless.default_radio0.ssid` (`p3NewPreserve`, auto-saved by PreSave into p5).

### MINOR-8 — UD1 phase-4 sample race; A.9 UD5 literal

UD1 has no hold: autocommit may commit before `pr_find` returns. A missing phase-4 sample must be INVALID with the
COMMITTED timestamp vs the first status sample, not FAIL. A.9's own UD5 ("an old bad-slot does not cause a false 6 →
5") is exactly UD1's B-committed sample after UD2 wrote `bad-slot` (`batman-autocommit:253`): keep it as a second UD5
assertion with "bad-slot present before UD1's apply" as its P.

### MINOR-9 — identifying processes as root against a compromised uid-471 peer

`pidof batman-provhelper` / `pidof dd` match names a 471 process can choose. Take the helper pid from procd and check
`/proc/<pid>/exe` and uid 0; take `dd` only as a child of a uid-0 `batman-slot write`. Otherwise the kill arm can be
steered to the wrong pid (the result is a FAIL, not a false PASS, but it costs an unattributed run).

### MINOR-10 — attribution of harness-tool failures

A dead WSL signer (`sig=ERR`, `prov-254.sh:827`) or a stale `provclient-arm64` in `$TOOLS` without the §3.1 fix makes
the first `update.check` answer code ≠ 0 / 20 → today a FAIL. Make the unit print the provclient build (or pin its sha
in the unit) and turn a tool failure into INVALID with that evidence.

### MINOR-11 — A3 should be "free ≥ payload at each check", and concurrent writers should be excluded

The tmpfs is fixed at 252,619,530 B (`batman-provd.init:20`) and `update.check` compares the *capacity* left with the
payload (`update.go:340-343`); the wsl.36 payload is 127,292,688 B, so one fits and two do not. Ownership: the real
provd (its PUT handler writes the same `payload` name with `O_TRUNC`, `provd/http.go:546`) and any app session on 04
(pending / window / the helper-wide 10 s rate) are second writers; state why they cannot act (bearer never known; no
BLE / HTTP session at `pr_begin`, checked) instead of "No resource has two writers".

## Owner's provisional answers

- Q1: host-timed as specified is not sound (MAJOR-9). Use a node-side watcher on dd's position; `write-hang` only for
  the sysrq sub-arm as a fallback, never for the kill sub-arm.
- Q2: not producible with signrel today (MAJOR-3).
- Q3: assert both — 0 + 23 after the restart, then 3 after a re-check without re-upload, apply usable (MAJOR-5). A.9's
  "3" is not "simply wrong"; the design's "contradiction" reading is.
- Q4: cite the archive's `update.status` line plus the wsl.22 source (MINOR-4); no rebuild.
- Q5: agree, but word it as "not reachable black-box on wsl.36" (pending is memory-only; any fault that leaves a `.txn`
  restarts the helper and drops the pending) rather than "not covered".
- Q6: if the AP is brought up, register an undo action first (MAJOR-8), not only the overlay restore.
- Q7: agree (one rule).
- Q8: no; use a test module outside `feed/` (MINOR-5).

## Verdict

**REJECT** — revise and re-review the whole document. BLOCKER-1 (base state not restored and not detected) and
MAJOR-1/3/4/5 (rows that cannot run or cannot fail as designed) must be fixed in the design before implementation;
MAJOR-6/7/8/9 are lifecycle and guard gaps that would otherwise surface as NEEDS-PERSON on the device.

Counts: 1 BLOCKER, 9 MAJOR, 11 MINOR.
