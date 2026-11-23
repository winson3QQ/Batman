# Review v6 (reviewer B) — `docs/design/254-v16-ud.md` at 4e3adea

I read the whole document again. I looked first at what v6 changed: the cut sub-arm's p3 handling, the host flow for
the cut, the UD4 `.enc.z` rule, the node-side encode of `ssid-restore`, the rewritten §7.1, the P9 `pupdate254`
gating, and the `test-ud-recover-254.sh` design.

I checked the §7.1 block line by line against:
- `prov-254.sh` (`:23` `set -u`, `:46-47` resets, `:181-246`, `:311-351`, `:395-405`, `:460-602`);
- `ble-lib-254.sh` (`:8-14`, `:106-111`, `:170-181`, `:297-326`, `:336-362`);
- `prov-lease-254.sh` (`:29`, `:38-80`, `:97-104`);
- `prov-undo-lib-254.sh` (`:150-262`);
- `prov-base-254.sh` (`:145, 157, 332-336`);
- `prov-p9-254.sh` (`:71`).

Read-only: no node, no ssh. The mesh-id history is not a finding.

## v5 findings: fixed in source terms?

| Finding | State | Checked |
|---|---|---|
| **B M1-1 / A M1-1** `PR_WROTE_B` reset by source | **Fixed.** It is set inside the `-c` string after `.`. `PR_V`, `PR_BASE` and `PR_S0_STATE` are not in the reset list (`prov-254.sh:46`), so they come from the environment. | `:46, 494-496` |
| **B M1-2 / A M1-2** node on B | **Fixed in order:** step 0c (`back_to_a` in its own shell with a new run) comes before any replay. A held trial is "wait for the revert". See MINOR-1 for one residual case. `back_to_a` is safe to call from a fresh shell: `PR_AB_MT=""` is initialised at source (`:312`) under `set -u`, and `pr_find` uses `PR_DEADLINE`, which the step sets. | `:312, 395-405, 226-246` |
| **A M1-3** failed step 1 leaves the lease | **Fixed:** `r=$?; pl release` unconditionally. `cmd_release` cancels the deadman and drops the lease (`ble-lib-254.sh:336-342`). | — |
| **B M1-3 / A M1-4** host death without a reboot | **Fixed.** Step 0b reads the lease, the dead-man log and the staging dir, then waits until expiry + 60 s. A fired dead-man removes the lease (`ble-lib-254.sh:362`). The "tryboot not cleared" case → clear by hand, then ble-recover (`:178-181`). See MINOR-2 for the `rm -rf`. | `ble-lib-254.sh:297-311, 350-362` |
| **A M1-5** dead-man count | **Fixed:** `PR_DM_BASE` comes from the current count for `run=@DEAD@`, so `pr_release` judges only new lines. | `prov-254.sh:569-572` |
| **A M1-6** stale host lock | **Fixed** (step 0a defers to `pr_lock`'s own message). | `:181-188` |
| **B M1-4** P9 prints the block for any run | **Fixed:** only for a `pupdate254…` flag; the generic line otherwise; fixture. See MINOR-4 on validation. | `prov-p9-254.sh:71` |
| **B M1-5** `pidof`; final evidence | **Fixed:** the watcher is found by its pidfile and cmdline. Step 3 is read-only: status (phase 0, no reason, no sha; on 04 that is row 5 of the restored S0 `update-last`) and `NO-WATCHER`. It removes its keys and `$PCD` (`pr_keys_drop`). | `prov-254.sh:865` |
| **B m1** host waits for a cut that never came | **Fixed:** the host polls the p6 log; `MISS` → INVALID with no `pr_find`; only a lost connection after `PRE-B` counts as "cut sent". | `:226-246` |
| A m1 p3 read failure | Fixed. A non-integer or empty p3 → `MISS`, tested before any arithmetic. | — |
| A m2 node-side encode | Fixed in design; see MINOR-5 for one detail | `prov-254.sh:62-63` |
| A m3 `.enc.z` | Fixed (INVALID "record not readable") | — |

Nothing in v6 breaks the rows, guards, lints, ownership, the `update-last` restore or the watcher design. The new
privileged steps in §7.1 act only on root-only paths:
- `/tmp/run/batman-dv` is root 0700 (`prov-254.sh:194, 697`; `/tmp/run` is root 0755 from procd). No unprivileged
  process or uid 471 can plant `bt/<run>` or the `ud9.pid` file there.
- The `rm -rf` targets a name built from the dirty flag, which lives on p6 state and is root-only.

So I find no TOCTOU or symlink exposure to a lower-privileged party. The points below are about correctness and
operator safety.

## Findings

### MINOR-1 — step 0c uses `pr_acquire`, whose replay can fail on B before `back_to_a` runs

Step 0c is `pr_acquire 3600; r=$?; [ $r = 0 ] && { back_to_a; … }`. `pr_acquire` also replays every other run's
journal and FAILs if anything stays left (`prov-254.sh:209-214`). A `slot:A` line of the dead run (`rm-hold`, or
`ssid-restore`) is LEFT on B (`prov-undo-lib-254.sh:241-242`), so `r ≠ 0` and `back_to_a` never runs.

With v6's registrations this needs an unusual history: an `undo-done` lost after landing, then a host death on B
committed. Yet it is exactly the case 0c exists for.

Fix: in step 0c, use `pr_stage && pl acquire 3600` (lease without replay) before `back_to_a`. After its reboot,
`pr_find` → `pr_acquire` replays on A, where the lines apply. Add the stub case "B committed + a pending `slot:A` line"
to `test-ud-recover-254.sh`; the stub's `undo-pending` must report the line.

### MINOR-2 — the manual `rm -rf` of the dead run's staging dir is redundant, and it is unsafe while that run's dead-man is still pending

- `cmd_acquire` already runs `gc_rundirs` (`ble-lib-254.sh:309, 317-326`). That removes `$BT/<run>` only when the run
  has no lease of this boot and no live dead-man record, and it prints the listing first. Step 0c's or step 1's acquire
  under a new run id therefore clears `$BT/@DEAD@` before step 2 needs it.
- A person who runs the manual `rm -rf` while the dead run's dead-man is still sleeping removes the scripts that the
  dead-man calls when it fires. Its segment 1 runs `sh "$DIR/prov-wbox-254.sh" unbind-all` (`prov-undo-lib-254.sh`
  useg1); the dead-man was started as `sh $BT/<run>/prov-lease-254.sh dm-fire` (`ble-lib-254.sh:148`). The undo is
  then half-done.
- The block's first bullet says "wait", but the `rm` line does not depend on it.

Fix: drop the manual `rm` and rely on `gc_rundirs`, with step 2's `pr_stage` FAIL text as the signal. Or gate the `rm`
in the same ssh command on "no `lease-prov` naming @DEAD@ in this boot and no live `$ST/dm*` record for it".

### MINOR-3 — the watcher kill is prose, not a command

Every other step is a copy-paste command, but "kill its group: pgid from … ud9.pid, checked against … cmdline" is
left for the person to improvise as root. Give the exact one-liner:
- read the pid from the pidfile;
- require `/proc/<pid>/stat` field 5 = pid (it is its own group leader);
- require `/proc/<pid>/cmdline` to contain `ud9-watch-254.sh`;
- then `kill -TERM -- -<pid>`, and re-check.

The pidfile is on tmpfs, so after a reboot it and the watcher are both gone; say "same boot only".

### MINOR-4 — P9 must validate the whole run id before substituting it into commands

The gate is "the run id starts with `pupdate254`". The value goes into an `ssh '… rm -rf /tmp/run/batman-dv/bt/@DEAD@'`
line and into `RUN=@DEAD@`. The dirty flag is root-only, but a substitution into a root `rm -rf` must not rest on that
alone. Accept only the full form that `prov-254.sh` generates: `pupdate254` followed by 10 digits. Anything else → the
generic line.

Also state who fills `@NODE@`. P9 runs on the node and does not know which address the host uses. The host side
(`dv-preflight`) should fill it, or the block should use the bench name.

### MINOR-5 — the node-side encode must not include uci's trailing newline

`uci -q get … | hexdump -v -e '1/1 "%02x"'` encodes the `0a` that `uci get` prints. The round trip against
`$(uci -q get …)` (newline stripped) would then always be `RT=bad`, and UD13 / UD6 (b) would be INVALID on every run.
Encode `printf %s "$v" | hexdump …` with `v=$(uci -q get …)`, and add a stub case to the offline test.

### MINOR-6 — `test-ud-recover-254.sh`: the stubs decide what the test can catch

The negative control (the v5 block fails asserts 2–4) is good. Add the cases the stub must model, because the real
node-side scripts do not run in the dry run:
- B committed with a pending `slot:A` line (MINOR-1);
- a live `lease-prov` of @DEAD@ in this boot (step 0b's "wait" path: no later step may acquire);
- a dirty flag `pupdate254x/../..` → the generic line (MINOR-4).

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 0 MAJOR, 6 MINOR.

Every v5 finding of both reviewers is fixed in source terms. The §7.1 block now matches the library's real behaviour:
- the resets at source and `set -u`;
- the lease and dead-man rules;
- the staging dir;
- the dead-man count;
- the order of `back_to_a`, replay, restore, rewrite and finish.

The remaining items are small robustness and clarity fixes to that printed procedure and its offline test. They can be
made during implementation without another full design round, provided `test-ud-recover-254.sh` includes the MINOR-6
cases.
