# #320 — busybox `< file 2>/dev/null` stderr noise: brace every redirect-read in the product tree

Status: v4, 2026-11-09. Round 1 (v1, two reviewers): APPROVE-WITH-CHANGES ×2 — lint heuristic unsound, PR split per
#290. Round 2 (v2 + code, two reviewers): APPROVE-WITH-CHANGES ×2 — CI step placement would skip the rest of the
prov-p1 job, lint missed `2> /dev/null` / `>/dev/null 2>&1` / `2>&-`, wrong rationale for excluding scripts/node.
Round 3 (v3 + code): APPROVE + APPROVE-WITH-CHANGES — the `/dev/null`-operand filter dropped whole lines, §2 copy
list regressed; both fixed here with the MINORs (comment lines skipped, three more A3 cases, known gaps listed).
Issue: #320. Parent: #202 A3.

## 1. Problem
busybox ash applies redirections left to right. In `cmd < "$F" 2>/dev/null`, when `$F` cannot be opened the
shell prints `<script>: line N: can't open <F>: no such file` to stderr *before* `2>/dev/null` takes effect; the
command is not run and `$?` is 1 (dash: 2, bash: 1 — every POSIX shell prints, the wording and rc differ; the node
runs busybox ash, the test runs busybox ash). Captured on WSL busybox 1.36.1 and on node 04 (image 1.5.14-wsl.22,
OpenWrt 24.10 busybox). The same happens with `2> /dev/null`, `2>>/dev/null`, `2>&-` and `>/dev/null 2>&1`: all are
later redirections.

Only the message is wrong. Every site already handles the failed read (`|| { wn=0; wl=0; }`, `|| echo 0`,
empty-string defaults from `$( )`), so rc and behaviour are unaffected. Where the line is visible: a manual or
harness `batman-config-save --on-join` (joinwatch's own call is `>/dev/null 2>&1`, so it never reaches logread),
`joinwatch status` / the joinwatch diagnosis when `/etc/halow-keyguard.blocked` is absent, and the other sites
only in their own corner cases (see the table).

## 2. Change
One rule, no exceptions: in the product tree (`feed/*/files`) a command with an input redirection that also has
`2>/dev/null` on the same simple command is written in the compound form, which makes the redirect failure
silent and is greppable (`; }` sits between `<` and `2>`):

    cmd < "$F" 2>/dev/null          ->   { cmd < "$F"; } 2>/dev/null

`{ list; }` runs in the current shell (busybox ash verified: `read` inside sets the variables for the caller; `||`
after the group fires on the same rc; `$( )` captures get the same string). The 22 sites (= every line the §6
lint finds on main, 2026-11-09), with the trigger that makes the file unreadable:

| file (feed/batman-provision/files unless noted) | line | file read | when it is missing |
|---|---|---|---|
| `usr/bin/batman-config-save` | 571 | `$RUNDIR/cfgsave-writes` | **routinely**: not created until the first real `--on-join` write of a boot (#202 A3) |
| `usr/bin/joinwatch` | 65 | `/etc/halow-keyguard.blocked` | **routinely**: exists only while keyguard blocks the radio |
| `feed/batman-payload-host/files/etc/init.d/batman-ots-firstload` | 84 | `/opt/batdata/log/firstload.log` | first firstload of a node (inside the single-quoted `setsid sh -c '…'` string; the brace form adds no quote) |
| `etc/uci-defaults/95-batman-storage` | 411, 417 | `autoboot.txt` (p7 / /boot) | card without one (pre-A/B, broken p7) |
| `etc/uci-defaults/95-batman-storage` | 219 | `${MBRBAK:-/nonexistent}` | Pi 3 only, when `tmpf` failed (the fallback is meant to be missing) |
| `etc/uci-defaults/95-batman-storage` | 713 | `$LOG/ota-trace.log` | only when otatrace.sh is absent (line 711 normally creates it) |
| `usr/lib/batman/payload-stop.sh` | 88 | `$PSTOP_RUN/…stop0` | only when the run dir is unusable (pstop_early writes it first) |
| `usr/bin/batman-config-save` | 193, 332 | `.txn`, `cfgsave-mntfail` | race: removed between the `-e/-f` test and the read |
| `usr/libexec/batman-addr-defer` | 73 | `addr-defer.start.pid` | race after `[ -s ]` |
| `usr/sbin/batman-faketime` | 25 | `$FILE` | race after `[ -f ]` |
| `usr/sbin/batman-slot` | 471 | `$f` | race after `[ -f ] && [ ! -L ] && [ -O ]` |
| `usr/lib/batman/platform-ab.sh` | 330 | `$dir/metadata` | race after `[ -f ]` |
| `etc/uci-defaults/96-batman-config-migrate` | 221 | `$TMP` | `mktemp` failed (TMP empty) |
| `usr/bin/batman-config-save` 237, `usr/bin/batman-autocommit` 80, `usr/sbin/batman-slot` 89, `usr/lib/batman/platform-ab.sh` 81, 96, 126 | | `/proc/<pid>/cmdline` | pid exited between `kill -0` / `-d` and the read |
| `usr/lib/batman/payload-stop.sh` | 36 | `/proc/<pid>/cmdline` | the pidfile's pid is dead or reused while another holder has the flock (no `kill -0` there; the lock test is the guard) |

The race / corner-case rows are converted for the same reason (same class, one rule, zero-exception lint) —
each is a one-line mechanical edit with the same safety argument. `payload-run:164` has the reversed order
`2>/dev/null </dev/null` (already silent); six `</dev/null >/dev/null 2>&1` lines read a file that cannot fail to open.

Not in this pair of PRs, recorded as #320 checklist items:
- `scripts/node/*` (~20 lines of the same class, e.g. prov-undo-lib-254.sh:174/179/190/209, ble-lib-254.sh:185/201/261,
  prov-base-254.sh:58/59, bt-uart-305.sh:40). These DO run on the node under busybox ash and put the same noise into
  harness logs; they are excluded only because #290 keeps harness changes in their own PRs. The sweep and the lint
  path extension (`scripts/node`) are one later harness PR.
- `scripts/dv/*`, `tests/*`: host side, bash, capture their own stderr.
- `usr/bin/halow-status:58` `njoin=$(wc -l < "$JL")` after `[ -f "$JL" ]` has no stderr discard at all — prints under
  the same race, by a different rule (nothing to brace); left as is, noted.

Copies: `deploy/provisioning/batman-config-save`, `deploy/provisioning/joinwatch`,
`deploy/provisioning/uci-defaults/95-batman-storage`, `deploy/provisioning/uci-defaults/96-batman-config-migrate`
are byte-identical copies of the feed files and are updated together (CI `provisioning-sync`, which caught the
96 copy when v2 had listed it as copy-less; v3 regressed that sentence, round 3 caught it). `payload-stop.sh`,
`batman-ots-firstload`, `batman-slot`, `platform-ab.sh`, `batman-autocommit`, `batman-addr-defer`,
`batman-faketime` have no deploy copy.

## 3. Ownership / contracts / lifecycle
No shared state is touched: no file, flag, format, exit code, parsed log line, uci key or timing changes. At every
site the value, rc and control flow on a missing file are identical before and after (verified by both reviewers
site by site under busybox ash, incl. `set -u` in batman-config-save; no file sets `set -e`). The one observable
difference is one fewer stderr line per event, and nothing parses that line (repo grep for "can't open": no
reader; no dv judge asserts on it). In the `{ tr … < f; } 2>/dev/null | grep -q …` pipelines the rc is grep's in
both forms and grep still runs on a missing file (verified under busybox ash: `grep ran rc=1`). REVIEW.md items 1–3 are replaced by this statement. Lifecycle: boot
(95, 96, firstload, slot), join (config-save, joinwatch), payload stop, OTA stage 2 (platform-ab, slot) — same
behaviour, one less line. Downgrade: the older image prints it again. Both boards: same shell, same files.

## 4. Assumptions and evidence
- busybox ash prints on a failed input redirection before `2>` applies; `{ }` and reversed order are silent:
  WSL 1.36.1 and node 04 `sh -c` output (#320).
- `{ read …; } 2>/dev/null` sets the variables in the current shell; `||` sees rc 1; `$({ …; } 2>/dev/null)`
  returns the same string; `[ "$({ wc -c < missing; } 2>/dev/null)" != 512 ]` takes the same branch: reviewer runs.
- The A3 block keeps its semantics: extracted from the product file, run under busybox ash — `$WRITES` missing →
  `wn=0 wl=0`, stderr empty; `25 90`, up=100 → rc 1 "write rate-limited (25 writes this boot)".
- shellcheck (CI: severity error) and `busybox ash -n` give identical results on the original and brace files
  (reviewer run; repeated in the PR).

## 5. Security
No new or changed input, path, privilege, secret or failure mode. Same files, same trust boundaries (#280 run dir,
/etc, /opt/batdata, p7 mount, /proc). Fail mode unchanged.

## 6. Test — `tests/prov-p1/cfgsave-stderr-quiet.sh <repo root>` (no root, needs busybox)
1. **Lint, zero exceptions, whole product tree** `feed/*/files`. A hit is a line matching
   `(^|[[:space:]()])<[[:space:]]*["'~$/A-Za-z_.][^;|&]*[[:space:]](2>>?[[:space:]]*/dev/null|2>&-|>[[:space:]]*/dev/null[[:space:]]+2>&1)`
   minus comment lines and minus lines whose ONLY `<` is a `/dev/null` operand (`grep -vE '^([^<]|<<)*<[[:space:]]*/dev/null([^<]|<<)*$'`,
   so a line that also carries a real read stays a hit): a `<` starting a word, an operand
   that can be a file, then on the same simple command (no `;`, `|`, `&` between) a stderr discard in any spelling
   (`2>/dev/null`, `2> /dev/null`, `2>>/dev/null`, `2>&-`, `>/dev/null 2>&1`). Quiet by construction: the brace form
   (`; }` intervenes), `<<`, `<&`, `<2>` kmsg priorities, a `<` glued to the previous character (sed/awk programs,
   `\<`), the reversed order, `/dev/null` operands. Self-test in the test: 10 noisy spellings hit (incl. a `/dev/null`
   operand next to a real read), 13 quiet forms do not (incl. a comment line) — each a negative control for one arm.
   Known gaps, none present in feed today (grep-verified): a digit-start operand (`< 1.txt`), an fd-numbered input
   (`3< f`, `0< f`), a quoted discard (`2>"/dev/null"`), `1>/dev/null 2>&1`, a `>` glued to the operand
   (`<"$F">/dev/null 2>&1`), a `\`-continued command; adding digits to the operand class would false-positive
   awk/arithmetic comparisons, so these stay documented. Known false positives a maintainer may meet: a `<` inside a
   quoted string followed by a blank, or an arithmetic `a < b`, on a line that also discards stderr — the FAIL message
   says to split the line; a `\`-continued command is scanned per line (accepted). The deploy copies are not scanned:
   `check-provisioning-sync.sh` keeps them identical. Expected: 22 hits on main (that run is the negative control,
   recorded in PR A), 0 after PR B. In daily-validation the stub runner keeps only `FAIL` lines, so the FAIL line
   carries the count and the first `file:line`; CI's direct run shows the full list.
2. **A3 block under busybox ash**: extract from the unique marker `# write-amplification guard (#202 A3)` to the
   next column-0 `fi` (FAIL unless 5–15 lines, last line `fi`, containing `read -r wn wl` — an indented or moved block
   fails loudly instead of running unrelated code; PR B adds the marker's purpose to the product comment); stubs `up(){ echo 100; }`, `err`, `umount(){ :; }`,
   `STAGE`/`MNT` = empty temp dirs, `mode=--on-join RDOK=1`, `set -u`. Cases: `$WRITES` missing → rc 0, stderr
   empty, `wn=0 wl=0`; `25 90` → rc 1 + "write rate-limited (25 writes this boot)"; `5 90` → rc 0, `wn=5 wl=90`;
   `20 50` → rc 1 (the threshold is `-ge 20`); `20 40` → rc 0 `wn=20 wl=40` (60 s window, not longer); `abc xyz` → rc 0,
   stderr empty, `wn=0 wl=0` (the `case` sanitisers). Mutants of the block that drop `|| { wn=0; wl=0; }`, the `exit`,
   the sanitisers, or change 20 / 60 / `-ge` are each caught by one of these (round-3 reviewer run).
3. **Negative control inside the test**: a mutant of the product file with the old line restored must produce a
   stderr containing `can't open` in case 2a and exactly one lint hit. When the product still carries the old line
   the mutant equals the product: case 2a itself FAILs with that stderr (noted in the output). When the mutant equals
   the product AND the lint is clean, the mutant pattern is stale (the A3 line was reworded) → FAIL, so the control
   cannot vanish silently.
4. Zero cases run = FAIL; no busybox = FAIL. Every FAIL line starts `FAIL cfgsave-stderr-quiet:`; last line
   `CFGSAVE-STDERR-QUIET cases=N fails=M`.

## 7. Delivery (#290: the harness lands first)
- **PR A (harness)** `harness/320-cfgsave-stderr-quiet`: this doc, the test, its line in
  `scripts/test-prov-p1-stubs.sh` (`stub 'fails=0$' cfgsave-stderr-quiet .`), its own LAST step in the ci.yml
  `prov-p1` job with `if: ${{ !cancelled() }}` (red on purpose on a pre-#320 product, `::error … expected red until
  fix/320-cfgsave-stderr lands`; as its own last step it never skips the loop-device / Go / claim-lock steps —
  the convention the job already states for the claim-lock and wireless-txn steps), and a
  `scripts/validation-known-failures.txt` entry (`prov-p1-stubs`, ERE `^FAIL (prov-p1-stubs: )?cfgsave-stderr-quiet: `
  — it matches all 3 FAIL lines the stub runner prints (2 from the test: lint, A3; plus the stub summary); #320; expires 2026-11-30 = estimate of
  PR B merge + 14 d). Verified: `kf_classify` → `known #320` today, `new (expired)` on 2026-12-01.
- **PR B (product)** `fix/320-cfgsave-stderr`: the 22 lines + 4 deploy copies, the marker note in the A3 comment, and
  the removal of A's known-failures entry (the own-entry exception of #290: once the product is in, a later
  cfgsave-stderr-quiet FAIL must be NEW, not masked until the expiry). Opened stacked on A; after A is
  squash-merged B is rebased onto main before the user merges it. CI on B runs A's test green; provisioning-sync
  checks the copies; both boards' sections in the body (bcm2710 not available — 2026-10-23 decision). Merging B
  closes #320 (the scripts/node sweep stays as its checklist line for the later harness PR).
