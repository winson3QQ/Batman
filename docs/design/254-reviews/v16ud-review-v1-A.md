# Review v1 — reviewer A — `docs/design/254-v16-ud.md` (draft v1, commit 7f58327)

Scope of this review: the whole document. Emphasis: whether each row's assertion and negative control holds against
the product source in this tree (`feed/` = wsl.36, `git diff b885a2c HEAD -- feed/` empty per the doc), and the
provclient fix. Read-only: no node, no ssh, nothing committed.

Method: every assertion was traced through `feed/batman-prov/src/node/{update,updwork,bulk,node}.go`,
`release/release.go`, `cmd/batman-provhelper/{update,status}.go`, `provstore/exec.go`, `feed/batman-provision/files/usr/sbin/batman-slot`,
`usr/bin/{batman-config-save,batman-autocommit,joinwatch}`, `tests/tools/provclient/{p3,main}.go`,
`tests/tools/peer/signrel.py`, `scripts/dv/data/p3-payloads.sh`, `scripts/build-ab-payload.sh`, and the archived run
`batman-validation/h5-p3-11081227/latest/prov-update-254.log`.

What the doc gets right (verified): §0.1-1 (update.check `{1: mf}` → `bytesArg(a, 2, 0)` → ESchema 20, `update.go:261`,
`node.go:178-182`; provd sends `{1: mf, 2: kid}`, `provd/update.go:40`, `server.go:652`; H0 is 130 hex = 65 B, so
`sha256(H0)` = `ownerID(signer)`, `updwork.go:177`); bulk.open `{1: 0}` only → ESchema (`bulk.go:41-51`); §0.1-3
(no `upd-write-mid`); §0.1-5 (UD8 / UD8c are refused by the first pass, no slot touched, `updwork.go:347-359`);
UD20 neg → `E_FORBIDDEN` with nonce consumption (`node.go` verifyOwnerOp, `proto.ArgsHash` strips 31); UD20b / UD20c
15 (`updwork.go:208-211`, `bulk.go:63-66`); the EBusy second arm of UD20c (`update.go:280-282`); UD8b (`updwork.go:215-218`,
tick deletion `:954-962`); UD2 phase 4 / 6 and UD4 6 + 18 (`updwork.go:888-903`; no aclog line is written by a B that
never reaches userspace). Those parts are not repeated below.

---

## BLOCKER

### B1. provclient cannot show the reason of any error reply — every `E_REJECTED{n}` assertion is unreadable
- **Scenario.** UD20b, UD20c (both arms), UD8b, UD10, UD10b assert `E_REJECTED{15}`; bulk.open's 16 / 21 are the A1 / A2
  diagnosis. The helper sends an error reply's reason at **key 1** of the result: `errBody` → `cbor.M(1, e.Why)`
  (`feed/batman-prov/src/node/node.go:75-81`; `failR` sets `Why`, `:71-73`; `EReject = 24`, `:53`). provclient reads it at
  **key 2** (`tests/tools/provclient/p3.go` `reasonOf` → `r.get(2)`, used by `resultLine` only when `code != 0`; the header
  comment even marks this "⚠️ design: … read here as key 2"). So the line is `RESULT update.prepare code=24` with no
  `reason=`. A judge that requires `reason=15` FAILs every one of these rows; a judge that accepts `code=24` alone passes
  any EReject — e.g. an arm refusal `24{13}` or a bulk.open `24{16}` would be read as "15".
- **Evidence.** above; `update.check` refusals are different (code 0, result `{1:false, 2:reason, 3:ram}`, `update.go:270`)
  and are read correctly.
- **Fix.** §3.1 adds: error replies' reason read from key 1 (keep key 2 only if a reviewer finds a verb that uses it —
  none in `node/`). Offline test against the real encoding (a vector produced by `node.errBody`, or the out-of-tree test of
  M7); device flip: one known refusal (UD20b) prints `reason=15` with the new binary and no `reason=` with the old one.
  This is the second provclient bug of the same class as §0.1-1; the doc should say the reality check missed it.

### B2. UD13 (b) and UD6 (b) cannot produce 17 as designed; UD13 (a) passes for the wrong reason (A9 is already answered by source: false)
- **Scenario.** The rows `uci set` without commit and expect `batman-config-save --check` to see it.
  `batman-config-save` reads **committed values only**: `UCIDIR=$(tmpd cfgsave-uci)`, `uget(){ uci -q -P "$UCIDIR" get … }`
  with the comment "a `uci set` not yet committed must not reach p5 … -P <empty dir> hides the pending delta"
  (`feed/batman-provision/files/usr/bin/batman-config-save:143-146`). So (b) answers `ok=true`, not 17; UD6 (b) reaches
  phase 3; UD13 (a) is `ok=true` because the value is invisible, not because of `SKIP_UNSAFE`. The "flip" of UD13 is
  then two non-discriminating calls.
- If the arms **commit** (the only way to be seen), two product writers enter that the design does not list:
  - joinwatch runs `batman-config-save --on-join` every tick (POLL 15 s) while the node is JOINED
    (`usr/bin/joinwatch:155-164`, `:36`). 04 is a member: a committed *safe* value (UD6 (b) "a new safe value") is
    saved to p5 within ~15 s → p5 fresh → the worker's precheck passes → phase 3. UD6 (b) is a race the product wins.
  - the helper's `PreSave` (`update.check` step 2) runs `--save` when `--check` says stale **only** in
    `wireless.default_radio0.ssid` (`cmd/batman-provhelper/status.go:64-85, 134-144`). A committed ssid with `'` is
    skipped by stage_overrides (`batman-config-save:466`) while p5 still has the old ssid line → `p5 stale:
    wireless.default_radio0.ssid` → PreSave saves → fresh → (a) `ok=true`. That is the real P3 mechanism for (a)
    (§3.3 F63) and it **writes p5**.
- **Fix.** (a) commit the `'` ssid and assert the mechanism (helper log `p5 stale only in keys P3 added: --save rc 0`, or
  joinwatch) plus `ok=true`; (b) commit an **unpersistable** value (`'`) on a non-exempt PRESERVE key → REJECTED →
  `unpersistable` → precheck rc 12 → 17 (`batman-slot:582`), not saveable by joinwatch, deterministic; UD6 (b) uses the
  same unpersistable value **after** the check (so the 17 comes from the worker's `batman-slot write`). Restore = set the
  original value + `uci commit` (a committed change cannot be `uci revert`ed), then p5 via `pr_restore`. Ownership: add
  `/etc/config/*` (harness) and p5 (PreSave, joinwatch, `pr_restore`) as written by more than one party during these arms.
  Lifecycle: a host crash after the commit leaves a committed unpersistable value (every later OTA refused 17; the AP
  SSID changes at the next wifi reload) — P9 must detect it and `pr_normalise` must clear it; add the row to §5.
  Choose the (b) key so that a reload of its service cannot break the node (not `network.*`), and say which.

### B3. UD4's "badpayload (exists)" cannot pass the app path; the generator contract (§3.3) is missing
- **Scenario.** `p3-payloads.sh badpayload` repacks with `tar -czf "$bp_out" -C "$t/p" .`
  (`scripts/dv/data/p3-payloads.sh:63`): members are `./`, `./SHA256SUMS`, … in readdir order. The worker requires the
  first member to be named exactly `SHA256SUMS`, then `metadata` (`readSmall`, `updwork.go:454-467`); the product builds
  `tar -C "$T" -czf "$OUT" SHA256SUMS metadata boot root.squashfs` (`scripts/build-ab-payload.sh:90`; P3 F27,
  `254-p3-impl.md:333`). signrel finds SHA256SUMS by `m.name == "SHA256SUMS"` (`tests/tools/peer/signrel.py:68`) and
  exits "payload has no SHA256SUMS member". UD4 (and UD5, which rides on UD4) never reach phase 3. The tool was built
  for the sysupgrade path (E-H13), which takes members by name.
- The same constraint binds every new generator (`malicious 1..4`, `mutate`, `swapy`), and the doc points to "§3.3" for
  them — there is no §3.3.
- **Fix.** Write §3.3: one shared repack function (explicit member list in V's order, no `./`, same `boot/` /
  `boot/overlays/` dir entries as V); acceptance per output = `tar -tzvf` listing identical to V's except the named delta
  (names, order, types), first two members `SHA256SUMS`, `metadata`; negative control: the acceptance run on a
  `tar -C dir .` repack of V must FAIL. Fix `badpayload` the same way (it is shared with E-H13: check that path still
  takes it).

---

## MAJOR

### M1. UD10: the doc reads P3 wrong; A.9's "3" is the requirement (after the re-check). Owner's provisional Q3 is wrong
- **Evidence.** P3 v7.13 §3.7.4 step 6: pending only in helper memory — "helper 重啟 = pending 消失,擁有者重新
  `update/check`,已寫好且 VERIFIED 為本次開機的槽仍可直接 apply" (`docs/design/254-p3-impl.md:396`); test list
  "helper 重啟後 phase 3 重建" (`:735`); "apply 前提看槽 … helper 重啟後 pending 與 VERIFIED 都在 → apply 可用"
  (`:929`). Code agrees: after a re-check the pending is back, the target is `verified=<X> <this boot>` → status row 4 →
  phase 3 (`updwork.go:879-882`), apply allowed (`:693-705`). 0 + 23 is the state *between* restart and re-check.
- **Fix.** UD10: restart → status 0 + 23 and `update-apply X` → 15 (as drafted) → **`update-check X` → status 3 with no
  worker and B's bootinfo unchanged** (the rebuild without a re-upload). Q3 answer: assert both; A.9 text gains the
  re-check step, it is not "simply wrong". UD10b becomes the discriminating pair: reboot → re-check → status 0 + 23 (the
  VERIFIED boot id is the old one, row 4 fails) and apply → 15. If the owner wants "apply accepted after re-check" proven,
  that belongs in the trial arm through `apply_guarded`.

### M2. UD7 "no pending" is wrong; UD20c's P ("status shows sha Y") is unobservable
- **Evidence.** UD7 runs the valid V first (`ok=true` → `u.pend = …`, `update.go:366`); refusals return before `:366`
  and never clear it → after the seven refusals the pending is V, not none. `update.status` reports a pending's sha only
  in rows 1–4 (`updwork.go:862-882`); with a pending, no window, no worker, no failure, not verified, it falls through to
  update-last (`:883-919`) and shows update-last's sha or nothing. And provclient's `fmtProgress` prints only phase /
  percent / fail_reason — never key 4 (sha) or key 5 (version) (`p3.go` fmtProgress).
- **Fix.** provclient prints `sha=<16 hex> version=` from keys 4 / 5 (not secret). UD7: assert "the refusals did not
  replace the pending": `bulk-open X` → ok, `bulk-close` (or drop the clause). UD20c P: after the owner's two 15s,
  `bulk-open Y` → ok (pending is Y), then `bulk-close`. UD20c second arm: status phase 1 with `sha=X` after the EBusy.

### M3. Every reason-11 arm is non-discriminating as written
- **Scenario.** UD7 `--bad-sig`, `--key other`, `--serial 0`, `--unparsable-version`; UD8 1–4; UD8c: all 11. A generator
  or signrel mistake gives the same 11 from an earlier check. Concrete: UD8 (4) "more members than SHA256SUMS lists + 4"
  can only be reached with repeated `boot/` / `boot/overlays/` **directory** entries (they `continue` before the
  repeat / listed checks, `updwork.go:524-534`); any extra regular member hits "not listed" (`:556-558`) or "repeats"
  first — still 11, still "PASS", count bound never exercised. The P controls (V passes; the generator's own acceptance)
  do not tell which check refused.
- **Fix.** Assert the helper's own why for each arm: `update.check: refused, reason 11 (<why>)` (`update.go:269`) and
  `update worker: <ver> refused, reason 11 (<why>)` (`updwork.go:279`), read with `logread` bracketed by a run marker;
  expected strings per arm in the table (e.g. "too many members", "members after root.squashfs", "data after the gzip
  stream", "member boot/… is not a regular file", "root.squashfs does not match SHA256SUMS", "E: payload is not {1: K
  65 B, 2: serial >= 1}", "S: does not verify", "version unparsable"). Missing line → FAIL.

### M4. `update-prepare` is an unguarded slot write; expected-refusal `update-apply` calls are outside the guard
- **Scenario.** prepare starts `batman-slot write` of the **inactive** slot; `begin_write` marks it BAD before the first
  byte (`batman-slot:468-475, 853`). If the node is unexpectedly on B (after UD1's commit, or §5 crash case (a)), a
  prepare overwrites A — the fallback slot. §4 inventories only `update-apply`. Separately UD10 / UD10b send
  `update-apply X` expecting 15: outside `apply_guarded` they trip the design's own new lint (1) pattern, and if the
  product ever accepted, the node reboots into a trial with no guard and no landing check.
- **Fix.** `prepare_guarded <boot8>` (active A, `is-trial` rc 1, boot id) + lint (1) pattern `update-prepare`; every
  `update-apply`, including expected refusals, through `apply_guarded`; rows in `slot-sites.tsv`; lint fixtures as §7-5.

### M5. UD9 (Q1): host timing can FAIL a correct product; the kill sub-arm leaves an orphan holding the lock; `write-hang` is the sounder choice
- **Evidence.**
  - Helper death closes the stdin pipe of `batman-slot write` — a normal EOF. If the kill / cut lands after the helper
    wrote the last rootfs byte while `dd … conv=fsync` still runs (`batman-slot:856`), the orphan finishes `write_slot`
    and B becomes VERIFIED, `bad=0`. The design asserts `bad=1` → FAIL, although "dd was running" held.
  - `clear_root` is also a `dd` child of `batman-slot write` (`batman-slot:717, 854`): the detector matches it too.
  - No `Pdeathsig` (`provstore/exec.go:93-96`, `Setpgid` only): after `kill -9` the orphan keeps the flock; the new
    helper's bootinfo gets rc 14 and retries after 60 s (`update.go:38, 205-209`); status shows 0 + 0 until then
    (cache empty, `updwork.go:876`), 0 + 22 only after the orphan exits. "status after the helper is back" needs a bounded
    poll; otherwise a spurious FAIL.
- **Judgement on Q1.** `write-hang` (`batman-slot:855`) parks the write **after** `begin_write` (BAD on disk, synced by
  `tboot_close`) and `clear_root`, before the stream. Reachable without a product change: a root-owned single-link
  `/tmp/batman-fault.write-hang` (`batman_opf`, `rundir.sh:45-52`); the harness already acts as root (sysrq, restore).
  It makes both sub-arms deterministic (no INVALID budget, no FAIL-on-late-cut). Conditions to write into the design:
  create it `umask 077`, check `ls -ln` = root, 1 link; remove it as soon as the `sleep 3600` child of `batman-slot write`
  is seen (it hangs every later `write` of the boot); kill sub-arm: after `kill -9` of the helper, kill the orphan's
  `sleep` → `dd` reads EOF → verify fails → rc 13 → BAD (deterministic), then poll status ≤ 120 s for 0 + 22; cut
  sub-arm: sysrq while parked. Ownership row ("harness, UD9 only"), tmp-trust allowlist, P9 "no fault file", lifecycle
  row "host crash while the flag exists" (gone at reboot; the restore reboots). It covers "after begin_write", not
  "mid-stream"; say so. If host timing is kept as an extra, add `/proc/<dd>/io` `rchar` < rootfs size and the
  `of=` / not-`if=/dev/zero` argv check to the P.

### M6. UD1's phase-4 sample is a race the harness can lose
- **Evidence.** A healthy trial commits after `NEED=3` × `POLL=10` s plus the mesh gate (`batman-autocommit:30-31, 622`).
  The harness must `pr_find`, re-place provclient (tmpfs, gone after the reboot) and poll; "phase never seen → FAIL".
- **Fix.** UD1 also writes the hold flag, samples phase 4, then `batman-autocommit release --wait` (`:160-185`) → 5.
  It also removes A7 as an unknown.

### M7. The provclient fix has no negative control on the real decoder; Q8
- **Evidence.** §7-1 tests provclient's encoder against itself; §7-2 needs a `_test.go` under `feed/` (owner: no).
- **Fix (no `feed/` change).** (1) Device flip, cheapest and on the real system: in E-UD1 or the refuse arm, the current
  provclient binary (tools SHA as shipped) → `update.check code=20` and helper log "missing arg 2"; the new one →
  `ok=true`. Same for `bulk-open` and for B1's reason key. (2) Optional offline: a test module under `tests/` with
  `replace batman-prov => ../../feed/batman-prov/src` — `node.New`, `Handle`, `SetUpdateSource`, `UpdateSys`, `UpdateFS`
  are exported, and `update.check` does not need a record (`node.go` handleQ dispatches it before `n.mu` / LoadOverlay).
  Also: E-UD1 is called read-only but an `update.check` is not (creates a pending; PreSave may `--save` p5,
  `status.go:134-144`): say so and snapshot first.

### M8. A1 (04's phone AP) is probably false and is on the critical path of 3½ of 4 arms
- **Evidence.** `254-p3-impl.md:486`: "剛認領節點被 keyguard 關著的 AP … 04 現在就是關著的". bulk.open → 16 when the AP
  is off (`bulk.go:72-74`); UD8b, UD20b, UD20c and every write / kill / trial row need a window.
- **Fix.** Q6 cannot stay "ask after E-UD1": write the branch now — how the AP is turned on (the product path is
  settings.set key 20, which changes AP credentials and p5; the passphrase goes on fd 3 and must not be printed), its
  restore, the extra duration, and what is INVALID if the owner says no.

---

## MINOR

1. **UD5.** The doc says A.9's "5" "cannot discriminate". It can, through a different mechanism: UD2's revert writes
   `$ST/bad-slot = slot=B version=V` (`batman-autocommit:253`), checked at `:400` only on non-tryboot boots, cleared on
   COMMITTED (`:622`). UD1 after UD2 with the same V is exactly "an old bad-slot does not cause a false result". Keep
   the 6 + 18 offset check and add: P = `bad-slot` holds `slot=B version=V` before UD1; UD1 reaches 5.
2. **§8 claims reason 1 is observed at `update.check` inside UD1's trial**, but UD1's steps have no check in the trial.
   Add it (precheck-node rc 10 → 1, `update.go:50-51`; PreSave skips in a trial, `status.go:135`).
3. **Q2 / signrel.** signrel refuses `--serial 0` (`signrel.py:375-376`, `ap.error("--serial must be >= 1")`). The UD7
   serial arm needs a specified signrel change (test-only option, selftest vector, node-side expectation "serial >= 1"
   why string). With that, Q2 = yes.
4. **UD7 text** says "seven update.check calls" and lists eight.
5. **UD-L vacuous step.** The refused `update.apply` of UD10 / UD10b stops at `validPending` (`updwork.go:693-698`)
   before any `batman-slot` call; nothing to judge. Require ≥ 1 judged UD-L step per arm, else FAIL.
6. **UD10 timing.** Right after the restart the status cache can be empty → 0 + 0 until the first tick's bootinfo
   (`updwork.go:876, 904-912`). Bounded poll for 23.
7. **Generator edge cases.** UD8 (3): Python's gzip in signrel (`tarfile.open(path, "r:gz")`, `signrel.py:66, 136`) may
   raise on trailing non-gzip bytes — sign the clean variant's SUMS / metadata and the final size, or prove it in the
   acceptance. UD8c: Go's gzip reader takes FEXTRA ≤ 65535 B and FNAME / FCOMMENT ≤ 512 B; bound the mutation so the
   compressed gap fits FEXTRA, and state it.
8. **tmp-trust lint.** New literals `/tmp/run/batman-provd-bulk/payload` (and `/tmp/batman-fault.write-hang` if M5) in
   `scripts/dv/*` are in scope of `scripts/check-tmp-trust.sh` (`git ls-files 'scripts/*.sh'` matches subdirs; allowlist
   line 13 covers only `/tmp/run/batman-dv`). §4 does not mention this lint; add the entries with reasons.
9. **`psk_sha`.** An 8-byte unsalted sha256 prefix of the AP passphrase (`main.go:48`, `fmtBulkOpen`) is an offline
   verifier for a human-chosen passphrase. Print the length only, or an HMAC under a per-run random key.
10. **Order inside the `write` arm** is not stated (UD10 needs UD20 pos; UD6 (b)'s committed value must be restored
    before UD20 pos). State it.
11. **Q4 / W.** The archive's `update.check code=20` cannot discriminate (the provclient bug gives the same 20 on wsl.36);
    `update.status code=20` (no args) can. Cite update.status, plus the source at the wsl.22 commit (`git show
    2ecf1cb:feed/batman-prov/src/node/node.go`: no `update.*` / `bulk.*` verbs) for the owner-op verbs, marked
    ⚠️ source-only. The archive stays valid for that narrower claim after the provclient fix.
12. **Dangling reference** "§3.3" (UD8 row) — see B3.

---

## Owner's provisional answers

| Q | Verdict |
|---|---|
| Q1 | `write-hang` is sounder (M5), with the listed conditions. Host timing as written can FAIL a correct product. |
| Q2 | Agree, once signrel can emit serial 0 (Minor 3). |
| Q3 | Disagree: assert 0 + 23 **and** phase 3 after the owner's re-check (M1); A.9 needs the re-check step, not a new number. |
| Q4 | Cite update.status from the archive + wsl.22 source; update.check's 20 is not evidence (Minor 11). |
| Q5 | Agree (uncovered), but fix §8's reason-1 claim (Minor 2). |
| Q6 | Must be decided in the design now (M8). |
| Q7 | Agree (one rule). |
| Q8 | Agree no `feed/` file; use the device flip and/or the out-of-tree module (M7). |

## Verdict: **REJECT** (revise and review the whole document again)

3 BLOCKER, 8 MAJOR, 12 MINOR. The blockers are fixable in the test tools and the row design without any product change,
but they change what UD4 / UD5 / UD6 / UD13 / UD20b / UD20c / UD8b / UD10 / UD10b assert or whether they can run at all.
