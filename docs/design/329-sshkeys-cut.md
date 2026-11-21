# #329 (v1.6): `ssh_keys.set` must stay consistent across a power loss

Status: design v5, APPROVED (round 5: A APPROVE, B APPROVE-WITH-CHANGES, MINORs only; folded in).
- v4 review: both APPROVE-WITH-CHANGES, with one shared MAJOR (the DV negative control), fixed in §8.
- v3 review: A = APPROVE-WITH-CHANGES with 1 MAJOR (the app mapping), now fixed in §3.4; B =
  APPROVE-WITH-CHANGES, MINORs only.
- v1 review: A = REJECT, B = APPROVE-WITH-CHANGES.
- v2 review: both APPROVE-WITH-CHANGES.
- The v2 MAJORs all concern the other slot (rollback). The user moved that mechanism out of scope on
  2026-11-21 (§3.2).
- Every finding is mapped in §10.

Reproduction: #329 issuecomment-7059208023 (04, wsl.33, unit `scripts/dv/prov-sshkeys-cut-254.sh`).

## 1. Problem (reproduced)

`sshKeys` (`feed/batman-prov/src/node/node.go:839-880`) today:

1. `cur = AuthorizedKeys()`. That is main.go:381-396: the lines starting `ssh-`/`ecdsa-`/`sk-`, each
   `TrimSpace`d. Operator lines = `cur − rec.SSHKeysAdded`; `out = operator + new` (node.go:853-867).
2. `commit(SSHKeysAdded = new)`: p5 through `--prov-only` (synced), then the overlay record (txn.go:18-48).
3. `SetAuthorizedKeys(out)`: WriteFile `.prov` + rename, no fsync (main.go:398-403).
4. `Save()` = `batman-config-save --save`:
   - copies authorized_keys into p5 `identity/dropbear/` (:445-447, :595-599);
   - runs a global `sync` (:607);
   - exits rc 0 or 6 (:562, :615-617);
   - an rc != 0 is only logged (node.go:877).

A power loss between step 2 and the end of step 4 leaves the record at `new` and the durable file at `old`.
On 04 this gave `rec=B file=A`, and A could log in. `ssh_keys.set []` (「移除 app 加入的全部 SSH 金鑰」) then
treats A as an operator key and keeps it. **A key the owner revoked stays valid, and the app can no longer
remove it.**

Other triggers reach the same end state (found by the review):
- **`--save` fails** with rc 1 (lock busy :248-265, mount :376-378). The record is `new`, the p5 copy is
  `old`, and a fresh slot (96-batman-config-migrate:176-179) brings `old` back untracked.
- **A line with trailing spaces.** The regex allows them (node.go:752, comment part `[ -~]{0,40}`). The app
  strips only CR (dev_pages.dart:69-72). The record stores the raw line (node.go:870), but
  `AuthorizedKeys()` trims it (main.go:391), so the next op no longer matches it and the key is untracked.
- **Rollback or downgrade to the other slot**: out of scope, §3.2.

## 2. Invariant

**I:** at every instant, every app-added key line in a durable copy of the active authorized_keys is in the
durable record's `SSHKeysAdded`. There are two durable copies:
1. the active overlay file, once synced;
2. p5 `identity/dropbear/authorized_keys`.

The durable record is the p5 record. `--boot` and `resolve()` rebuild the overlay record from p5 when p5 is
newer (boot.go:165-168, wtxn.go:274-283). The overlay record is the source only in two cases, the
overlay-newer case and the p5-corrupt case (boot.go:170-173, 219-230), and both re-persist it to p5.

Extra entries in the record that appear in no file are harmless. The list is used only to decide which file
lines are not operator lines.

Keys are compared on the canonical line: `strings.TrimSpace`, the form `AuthorizedKeys()` returns.

## 3. Design

### 3.1 `sshKeys`

`rec` is already p5's record when that is newer: `ownerOpVerb` calls `resolve()` before the verb
(node.go:792-799).

```
lines = [TrimSpace(l) for l in request]           # validated as today, after the trim
old   = {TrimSpace(k) for k in rec.SSHKeysAdded}   # also matches records written before this change
cur   = AuthorizedKeys(); ops = cur − old
step 1  if old ⊄ lines:                            # decided on the RECORD, never on cur
          SetAuthorizedKeys(ops + (cur ∩ old ∩ lines))
          persisted(saveRetry()) else -> EApply     # record untouched
step 2  commit(SSHKeysAdded = lines)
step 3  SetAuthorizedKeys(ops + lines)
          persisted(saveRetry()) else -> EApply     # app: "result unknown, may be partly applied, resend"
```

- **`persisted(rc)` means rc ∈ {0, 6}.**
  - config-save returns either rc only after the identity files are renamed into p5 and `sync`ed
    (:595-607, :615-617). The limits of that guarantee are in §3.3.
  - rc 6 means only that a uci value could not be saved. halow-setkey already treats it as PARTIAL
    (halow-setkey:187).
  - `setPassword` maps rc 6 to EStorage (lock_test.go:86). Keys differ: the one thing this op must make
    durable is the file, and rc 6 does not affect it.
  - Any other rc means the file is not known to be persisted: 1, 124, 143, and so on. A TERM after the `mv`
    gives 143 (:140, :598), so the file may have been written anyway.
- **`saveRetry()`** (node.go:477-484) retries once on the busy-lock line.
- **`SetAuthorizedKeys` now fsyncs the tmp file before the rename.** No directory fsync is added, so a write
  failure always leaves the old file (B5-3). A cut before the save's `sync` then
  leaves either the old file or the new one, never an empty file that locks out operator keys.

Why I holds. Assume I holds before the op, so every durable copy's app part ⊆ old.

| cut / failure | durable copies (app part) | record | I |
|---|---|---|---|
| before step 1's save persisted | ⊆ old (`ops+keep` or the old file) | old | ✓ |
| step 1's save not persisted → EApply | ⊆ old | old | ✓; a resend repeats step 1 (decided on the record) |
| step 1 persisted, before step 2 | ⊆ old ∩ lines | old | ✓ |
| inside step 2 (p5 new, overlay record old) | ⊆ old ∩ lines | new; the next boot or resolve rebuilds the overlay | ✓ |
| step 2 done, step 3 not persisted → EApply | ⊆ lines | new | ✓; new keys may be missing, none is untracked |
| step 3 persisted | lines | new | ✓ |

If step 1 is skipped (old ⊆ lines), every durable app part is ⊆ old ⊆ lines from the start.

Every other config-save mode writes the p5 copy as a snapshot of the active overlay, under the same lock:
- the modes: `--on-join`, `--if-healthy`, saveAfterCommit, upgradeSave (status.go:121-143), halow-setkey;
- the stage at :551 is taken after the lock at :248.

The snapshot is therefore always `ops+keep` or `ops+lines`, and both are ⊆ the record. One exception: when
RDOK=0, config-save skips the lock (:248), so a snapshot staged before step 1 can land in p5 after it.
§3.3 lists this case.

### 3.2 Out of scope (user decision 2026-11-21): the other slot's overlay

On a rollback or downgrade boot, the other slot's overlay still holds its old authorized_keys. The record is
rebuilt from p5:
- at boot: boot.go:158-168;
- at runtime by `resolve()` (wtxn.go:274-283), called from node.go:792, txn.go:33, and wtxn.go:297 and :438.

A key revoked on the newer slot then stays valid and untracked on the old one. This gap already exists
today, needs no power loss, and §3.1 does not make it worse.

v2 proposed dropping the stale keys at `--boot`. The round-2 review showed that is not enough:
- **It runs after dropbear.** dropbear starts at S19 and the helper at S89 (batman-prov-lock:4-5,
  batman-provhelper.init:4), so the key gets a root window on every rollback boot.
- **`resolve()` bypasses it.** It rebuilds the record at runtime without dropping anything, and erases the
  trigger.
- **A failed overlay record write leaves untracked keys** (txn.go:47-50). That slot's file then holds app
  keys its own record never listed.

A real fix needs a step before dropbear (for example, adopting the p5 copy as 96 does) and a change to
`resolve()`. It also does nothing for the first fixed release, because the other slot still holds a pre-fix
image then. The user decided: not in v1.6, which runs on the bench only, with no field node. It is recorded
as an open checklist item in #329 with this analysis.

### 3.3 Not covered (stated, with reason)

- **Record recreated empty** (boot.go:179/188/203/210, cases 7 and 9: the overlay record and the p5 record
  are both gone).
  - Without the record, app keys cannot be told from operator keys, so this is log-only:
    `record recreated: N key line(s) in authorized_keys, origin unknown`.
  - The operator removes the keys by hand and runs `--save`.
  - The PR body says "log only", not "handled".
- **Nodes already broken by the old order** (`rec=B file=A`): same remedy. On the bench, 04 was restored by
  its snapshot (COMPARE diffs=0), and no other node ran the cut.
- **RDOK=0** (no run dir, batman-config-save:113; an abnormal boot).
  - config-save then skips its lock (:248).
  - A concurrent `--on-join` can rename a pre-step-1 snapshot into p5 after this op, so p5 holds a revoked key.
  - Accepted: the state is abnormal, and fixing it means changing config-save's lock rules for every mode.
- **rc 0 does not fully prove the p5 copy.**
  - `stage_overrides` ignores a failing `cp -a` (:447), and the status of the `mv -f` loop is not checked
    (:596-599). On ENOSPC or EIO on p5, the old copy stays.
  - Accepted: an I/O failure on p5 also breaks every other persisted value. The §4 contract is worded to
    match.
- **Lines this code already drops** (unchanged from today).
  - `AuthorizedKeys()` returns only `ssh-`/`ecdsa-`/`sk-` lines. Every rewrite therefore drops comments and
    option-prefixed lines (`restrict`, `from=`, `command=`).
  - An operator line identical to an app line is removed on revoke. The app warns about this
    (dev_pages.dart:89-91).
  - A replace now rewrites the file twice instead of once.
- **A hand revocation of an app key does not last.** The operator deletes app key A by hand, but the record
  still lists A. A later app op that resends the full set (A included) brings A back, the same as today. The
  remedy is to revoke through the app, that is, `ssh_keys.set` without A.
- **Availability.** For an owner who uses only app keys, a failure after step 1 leaves no app key. This is
  fail-secure, and the app path still reaches the node.

### 3.4 App

The app never sees the helper's code 21. provd maps hEApply and hEState to E_REJECTED with no detail
(provd/session.go:592-593), and hESchema maps to the same code (:595-597). A code-21 match would never
fire, and a match on E_REJECTED alone would tell a rejected key line to "resend". So (v4, A3-1):

- **New reason code 25** (219-protocol.cddl reason-code list): "ssh_keys: not known to be persisted —
  may be partly applied; the same set may be sent again".
- **Node.** The constant is `ReasonSSHUnpersisted = 25`. It shares its number with the helper error code
  `EInput = 25` (node.go:54), but they are different namespaces; a CDDL comment says so. These failures return
  `failR(EApply, ReasonSSHUnpersisted, …)`:
  - every failure after step 1's write was attempted: the step-1 save not persisted, a step-2 commit failure
    (EStorage or EState, whose "the record changed; retry" text, txn.go:36, becomes "unknown, resend"; a
    resend re-resolves), a step-3 write or fsync failure, and a step-3 save not persisted;
  - when step 1 was skipped, every failure after the commit: a step-3 write, fsync or save failure.

  `mapHelperR` (session.go:925-935) sends these as `E_REJECTED{2: 25}`. Other failures keep their code:
  - the failures before any write: ESchema, and EApply from the read (node.go:855);
  - a failed step-1 write: plain EApply, because the atomic rename leaves the file unchanged;
  - when step 1 was skipped, a commit failure: EStorage or EState, as today.

  Go test: each of these failures gets the code listed, including both commit cases (step 1 ran / skipped).
- **App.**
  - `reason_text` (owner.rs:739) gets case 25: `結果不明 — 可能只套用了一部分，可以再送一次同一組（會整組取代）`.
  - The line keeps the `[REQ_FAIL]` prefix.
  - The reply is answered (`OwnerKind::Answer`, owner.rs:1115-1119), so the session stays alive. Dart calls
    `_unclearReply` only for unclear/notSent/ended (owner_console.dart:451-460).
  - An older app shows the generic 「節點拒絕了 原因 25」. That is acceptable: no code was ever deployed to the
    field.
- **Tests.**
  - provd: helper `EApply{1:25}` → `E_REJECTED{2:25}`, and helper `EInput{1:x}` stays distinct on the wire.
  - Rust: reason 25 → the line.
  - Dart: that reply → the line, and the session stays usable.
  - Negative control: the provd and Rust tests fail on today's code (no reason 25), and the v3 code-21 match
    would have failed the provd round-trip.

The app timeout is 15 s (owner_console.dart:412). Two saves, each with up to 10 s of lock wait (:249), can
exceed it under contention. The existing "unknown, resend" line then shows, and a resend is idempotent.

## 4. Ownership / contracts

| resource | writer | readers |
|---|---|---|
| record `SSHKeysAdded` (p5 + overlay) | provhelper `commit`; `--boot` rebuild or recreate (boot.go); `resolve()` (wtxn.go:274-283) | provhelper |
| active overlay `/etc/dropbear/authorized_keys` | provhelper `SetAuthorizedKeys` writes the app lines only; the operator or lab edit their own lines by hand (kept, within §3.3's limits) | dropbear, every config-save mode |
| p5 `identity/dropbear/authorized_keys` | batman-config-save (every mode): a snapshot of the active file, under the lock | 96 on a fresh slot |

Ops run one at a time: `n.mu` covers dispatch (node.go:237-239). An unfinished .txn is finished before
`ssh_keys.set` (node.go:269-272).

New contract, the `--save` rc:
- 0 or 6: the save reported the identity (authorized_keys included) persisted and synced. Limits in §3.3.
- any other rc: not known, so fail closed (EApply). Returning success would claim a revocation that the p5
  copy can still undo.

## 5. Lifecycle

| path | today | after | test |
|---|---|---|---|
| first set / add only | 1 commit + 1 save | same (step 1 skipped) | go |
| replace / revoke | record new, file new | same end state, 2 saves | go + DV pre-step |
| power loss inside the op | rec B / file A | I holds | go (each cut point); DV POST (negative control), CUT1 on 04 |
| `--save` rc 1, then a resend whose step 3 also fails | p5 stale, key untracked | I holds | go (A-1); DV FAILPOST (negative control), FAIL1 |
| `--save` rc 6 | success, logged | success | go; DV RC6 |
| fresh slot (96) after the op | old keys come back | p5 copy ⊆ record | DV judges I on the p5 copy |
| rollback / downgrade slot | old file, key untracked | unchanged: out of scope (§3.2), on the #329 checklist | — |
| line with trailing spaces | untracked | canonical, tracked | go |
| record lost and recreated | untracked | logged, not fixed (§3.3) | go: the log line |
| upgrade: old records holding untrimmed lines | — | matched after the trim | go |
| downgrade to an older helper | — | the record schema is unchanged and holds ≤ 8 lines; trimmed lines also match there | — (no format change) |
| crash loop of provhelper | — | I holds on disk; each step leaves a consistent state | go cut tests |
| network loss mid-op | reply lost | resend is idempotent | go: resend |
| config-save lock held by another mode | rc 1, only logged | saveRetry, then EApply | go |
| platforms | ekh-bcm2711 bench only (v1.6) | same | DV on 04 |

## 6. Assumptions and evidence

- Record decode limit of 8 lines: provstore.go:218-220. ✓
- `--save` reaches the `sync` before every rc 0 or 6 (:607, :615-617). Every early exit is rc != 0 (:154,
  158, 209, 222, 265, 289, 378, 433, 592). ✓ Both reviewers read this.
- The p5 copy is written one file at a time by rename, then synced (:595-607). ✓ Limits in §3.3.
- 96 copies only on a fresh slot, and only when `-s` holds (96:3-4, 176-180). ✓
  `SetAuthorizedKeys([])` writes "\n", so an empty set does reach p5. ✓
- Boot rebuilds the record from p5 when p5 is newer (boot.go:165-168). ✓ Overlay → p5 when the overlay is
  newer or p5 is corrupt (boot.go:170-173, 219-230). ✓
- `ownerOpVerb` resolves before the verb (node.go:792-799). ✓ Dispatch is serial (node.go:237-239). ✓
- `sync(2)` also flushes the f2fs overlay (Linux semantics). ⚠️ Not probed directly.
  - After a POST reboot on the fix (the step-3 save), the file may legitimately be `ops+keep` or `ops+lines`. The DV judges only I.
  - Evidence that discriminates: after POST on the fix, no `old − lines` key is in the file while the record is `new`.
  - This is indirect: time and checkpoints can also flush.
- rc 6 counted as persisted has precedent beyond halow-setkey: the `SaveTxn` callers accept rc 6
  (node.go:1259, :1309). ✓

## 7. Security

- **Asset:** root login on the node. The bug lets a revoked app key keep root.
- **Actors:**
  - Holder of a revoked phone key: fixed here, except on a rollback slot (§3.2, out of scope by decision).
  - Remote attacker: no new input.
  - Local unprivileged process: the `.prov` tmp file sits in root-only `/etc/dropbear` with mode 0600, so
    there is no TOCTOU or symlink path.
  - Compromised mesh peer: no path to this verb.
  - Our own mistakes: the review found them (§10).
- **Attack-surface delta:** none (same verb, same body).
  - The node now accepts surrounding whitespace (spaces, tab, U+00A0, U+0085) and stores the canonical line.
    The regex runs on the trimmed line and anchors on `^ssh-ed25519 `. An inner tab is still rejected by
    `[ -~]`.
  - `len ≤ 256` and the `\r\n` check stay on the raw input (node.go:848), so any `\n` (a trailing one
    included) is still rejected.
  - Test: a line with surrounding spaces is stored trimmed, and a line ending in `\n` is rejected.
  - The new reason 25 is output only.
- **Failure mode:** fail closed when `--save` is not persisted.
- **Negative tests:** the go cut, A-1 and B-M1 tests and the DV POST and FAILPOST arms fail on today's code and
  pass after the fix.

## 8. Tests

**Go (`node_test.go`).**
- **Setup.** The fake Sys models durability per copy: the overlay file (synced or not) and the p5 copy.
  `Save()` is scripted per call as {rc, persisted?}: rc 0, rc 6, rc 1 persisted, rc 1 not persisted, and
  rc 143 persisted.
- **Cut points.** Cut after the step-1 write, after the step-1 save, after the commit, after the step-3
  write, and after the step-3 save. After each cut, assert I on every copy. Then `ssh_keys.set []` must leave
  no app key anywhere.
- **A-1.** The step-1 save returns rc 1, not persisted → EApply. A resend's step-3 save then returns rc 1,
  not persisted → assert I on p5. This fails on v1 and on today's code.
- **B-M1.** The p5 copy differs from the overlay (A was removed by hand, no save). Send `new = []` with the
  step-3 save not persisted. This fails on today's code and on the v1 condition.
- **rc 6** → OK, with the p5 copy asserted. This is a guard against fail-closed being too strict, not a
  negative control.
- **Trimming.** A trailing-space line is tracked and can be revoked. A record holding an untrimmed line is
  still matched.
- **Record recreated** → the log line is present (boot_test).
- **Negative control on today's order** (no step 1): the cut "after the commit, before the save" fails
  (rec new, durable file old). The cuts tied to step 1 do not exist on today's order. The A-1 and B-M1 cases
  fail on today's code, where the save rc is ignored.
- **App.** `cargo test` for the EApply text, and a Dart test that the session stays usable.

**DV** (`scripts/dv/prov-sshkeys-cut-254.sh`, a harness PR under #290).
- **Judgement.** The unit checks I itself: the app lines in the active file and in the p5 copy must be ⊆ the
  record. It reads the p5 copy through a read-only mount, as prov-overlay-wipe-254.sh:21 does.
- **Hook.** The hook identifies the save by state, not by call count; `saveRetry` or another caller's
  `--save` would shift a count.
  - Just before the op, the unit reads G0, the p5 record's generation (the durable one, after any resolve).
  - Per call, the hook reads the overlay `prov.meta` generation G. G = G0 means a pre-commit save (step 1 on the
    fix; today has none). G = G0+1 means a post-commit save (step 3 on the fix; today's only save).
  - The hook acts only when its parent is batman-provhelper: `readlink /proc/$PPID/exe` = `/usr/bin/batman-provhelper`.
    `comm` is truncated to 15 characters, so it is not used. `Save()` execs the hook directly, with no shell between
    (main.go:81-89, :143).
  - The hook logs the caller, G0, and G read from both the overlay and the p5 `prov.meta` on every call.
  - It is one-shot: armed once and removed after it acts. A second trigger makes the arm INVALID.
  - The arm is also INVALID when any other p5 writer ran between the op and the judgement (A5-1). The unit counts
    batman-config-save runs in logread, and the judgement reads p5 right after the reply.
  - The arm is INVALID when the save it targets never happened, when the parent is wrong, or when G is
    neither G0 nor G0+1. A rare case gets the same treatment: the overlay record write failed after p5
    committed (txn.go:47-50), which leaves G = G0 at step 3.
  - A hook that exits 1 must not print the busy text (node.go:474), so `saveRetry` does not retry it.
- **p5 read.** The DV reads p5 with `mount -o ro`, which replays the ext4 journal, as batman-config-save:383
  does. It does not use `ro,noload`, which can show a pre-replay p5 after an unclean reboot.
- **Arms** (`ARM=`), each with its expected result on wsl.33 (today) and after the fix:

| arm | what the hook does | wsl.33 | fix |
|---|---|---|---|
| `POST` (negative control) | sysrq at the first post-commit save | FAIL: rec B, p5 copy A (the overlay file may be A or B, depending on f2fs: the FAIL comes from p5) | PASS |
| `FAILPOST` (negative control) | the first post-commit save exits 1 without saving; then the unit judges I on p5 | FAIL: the op answers OK, p5 holds A, record B | PASS: reason 25, I holds; a resend completes |
| `CUT1` | sysrq at the pre-commit save (step 1) | INVALID: today has no step 1 | PASS |
| `FAIL1` | the pre-commit save exits 1 (→ reason 25); then a resend whose post-commit save exits 1; I judged on p5 | INVALID | PASS |
| `RC6` (guard, not a negative control) | the real save runs, then the hook exits 6; p5 judged | PASS | PASS |

  An INVALID never counts as a PASS. The PR reports the wsl.33 row as the negative control.

**Also:** `go test ./...` on the feed, the app tests, and the full prov DV list.

## 9. Triage / rework

v1.6 class A. The scope of #255 (608B identity, claim protection) does not include ssh_keys or
authorized_keys; I checked the issue body. So this is a full fix for §3.1.

PR split:
- product fix + go + app tests in one PR;
- the DV unit in a separate harness PR under #290.

## 10. Review findings → changes

**v1 → v2**
- A-1 BLOCKER / B-M1: step 1 decided on the record (§3.1).
- A-2 / B-M2: `persisted()` + `saveRetry` (§3.1).
- A-3: canonical TrimSpace (§2, §3.1).
- A-4: other slot. v2 added §3.2; v3 moves it out of scope.
- A-5 / B-M4: §8.
- A-6 / B-M3: §3.3.
- A-7: §2.
- A-8 / B-m1: §3.1, §4.
- A-9 / B-m2: §3.3.
- A-10 / B-m5: §3.4.
- A-11: §8.
- B-m3: withdrawn by B in round 2, because `ownerOpVerb` already resolves.
- B-m4: §3.3.
- B-m6: the fsync in §3.1.
- B-m7: §6.

**v2 → v3**
- A2-1 / B2-2 (`resolve()` rebuild), A2-2 / B2-1 (drop after dropbear), B2-3 (failed overlay record write):
  the whole rollback mechanism is out of scope by user decision (§3.2) and goes on the #329 checklist.
- A2-3 / B2-m1 (RDOK=0): §3.3.
- A2-4 (rc 0 vs the p5 copy): §3.3, and the §4 contract reworded.
- A2-5 / B2-m3 (DropKeys rules): dropped with §3.2.
- A2-6 (downgrade wording): §3.2.
- A2-7: citations fixed, the fsync stated in §3.1, the redundant guard removed.
- B2-m2 (app): §3.4, Rust `error_text`, session kept alive.
- B2-m4: §8 DV arms.
- B2-m5: the §8 B-M1 case.
- B2-m6: §3.3, and the PR body.

**v3 → v4**
- A3-1 MAJOR (the app never sees code 21; E_REJECTED is shared with ESchema): new reason 25, node
  `failR`, provd `mapHelperR`, app `reason_text`, plus a provd round-trip test (§3.4).
- A3-2: Dart test drives the provd-mapped reply (§3.4).
- A3-3 / B3-3: §7 reworded; length and `\r\n` checks stay on the raw input.
- A3-4: DV p5 read with `-o ro` (§8).
- A3-5: txn.go:33 is also a `resolve()` caller (§3.2 list).
- B3-1: §6 CUT2 wording.
- B3-2: DV hook keyed on the generation, not the call count (§8).
- B3-4: hand revocation (§3.3).
- B3-5: Go negative-control wording (§8).
- B3 §3.4 "code 21 keeps the session alive" was correct about the session but missed the provd mapping;
  superseded by A3-1.

**v4 → v5**
- A4-1 / B4-1 MAJOR (a generation-keyed hook loses the wsl.33 negative control): new POST and FAILPOST arms
  keyed on the first post-commit save; per-arm expected results on wsl.33 (§8).
- A4-2: the reason-25 list covers every failure after step 1's write, or after the commit when step 1 was
  skipped (§3.4).
- A4-3 / B4-m1: G0 is read from p5; the hook checks the parent and logs G0 and G (§8).
- A4-4: `ReasonSSHUnpersisted`, a CDDL comment, and a provd distinctness test (§3.4).
- B4-m2: `\n` dropped from the §7 list, plus a test.
- B4-m3: the commit-failure mapping is stated, with a Go test (§3.4).

**v5 round-5 MINORs (folded in, no new round needed)**
- A5-1: a p5 writer between the op and the judgement makes the arm INVALID (§8).
- A5-2: the POST FAIL comes from p5 (§8 table).
- A5-3, B5-1: the hook logs both meta generations and checks the parent through `/proc/$PPID/exe` (§8).
- B5-2: the hook is one-shot (§8).
- B5-3: no directory fsync (§3.1).
