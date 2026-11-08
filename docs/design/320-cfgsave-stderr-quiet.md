# #320 — busybox `< file 2>/dev/null` stderr noise: brace every redirect-read in the product tree

Status: v2, 2026-11-09 (v1 reviewed by two independent reviewers: APPROVE-WITH-CHANGES ×2; the two MAJORs —
lint heuristic unsound, PR split per #290 — are resolved here; the MINORs are folded in). Issue: #320. Parent: #202 A3.

## 1. Problem
busybox ash applies redirections left to right. In `cmd < "$F" 2>/dev/null`, when `$F` cannot be opened the
shell prints `<script>: line N: can't open <F>: no such file` to stderr *before* `2>/dev/null` takes effect; the
command is not run and `$?` is 1 (dash: 2, bash: 1 — every POSIX shell prints, the wording and rc differ; the node
runs busybox ash, the test runs busybox ash). Captured on WSL busybox 1.36.1 and on node 04 (1.5.14-wsl.22).

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
| `usr/bin/batman-config-save` 237, `usr/bin/batman-autocommit` 80, `usr/sbin/batman-slot` 89, `usr/lib/batman/payload-stop.sh` 36, `usr/lib/batman/platform-ab.sh` 81, 96, 126 | | `/proc/<pid>/cmdline` | pid exited between `kill -0` / `-d` and the read |

The race / corner-case rows are converted for the same reason (same class, one rule, zero-exception lint) —
each is a one-line mechanical edit with the same safety argument. Not in scope: harness scripts
(`scripts/node/*`, `scripts/dv/*`, `tests/*`; #290 one validation set, host side runs bash and captures stderr
itself) — recorded in #320. `payload-run:164` has the reversed order `2>/dev/null </dev/null` (already silent).

Copies: `deploy/provisioning/batman-config-save`, `deploy/provisioning/joinwatch`,
`deploy/provisioning/uci-defaults/95-batman-storage`, `deploy/provisioning/uci-defaults/96-batman-config-migrate`
are byte-identical copies of the feed files and are updated together (CI `provisioning-sync`, which caught the
96 copy when v2 had listed it as copy-less). `payload-stop.sh`, `batman-ots-firstload`, `batman-slot`,
`platform-ab.sh`, `batman-autocommit`, `batman-addr-defer`, `batman-faketime` have no deploy copy.

## 3. Ownership / contracts / lifecycle
No shared state is touched: no file, flag, format, exit code, parsed log line, uci key or timing changes. At every
site the value, rc and control flow on a missing file are identical before and after (verified by both reviewers
site by site under busybox ash, incl. `set -u` in batman-config-save; no file sets `set -e`). The one observable
difference is one fewer stderr line per event, and nothing parses that line (repo grep for "can't open": no
reader; no dv judge asserts on it). REVIEW.md items 1–3 are replaced by this statement. Lifecycle: boot
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
1. **Lint, zero exceptions, whole product tree** `feed/*/files`: a line matching
   `(^|[^<])<[[:space:]]*["$/A-Za-z_.][^;|&]*[[:space:]]2>/dev/null` (an input redirect, not `<<`, whose operand starts with a quote,
   `$`, `/`, letter or `.`, followed on the same simple command — no `;`, `|`, `&` in between — by `2>/dev/null`)
   is a hit. Not matched by construction: the brace form (`; }` intervenes), `<<` here-docs, `<&` dups,
   `echo "<2>…" > /dev/kmsg 2>/dev/null` (digit operand), the reversed order. Self-test in the test: the old form is
   a hit, each quiet form is not. The deploy copies are not scanned: `check-provisioning-sync.sh` keeps them identical.
   Expected: 22 hits on main (that run is the negative control, recorded in the PR), 0 after the product PR.
2. **A3 block under busybox ash**: extract from the unique marker `# write-amplification guard (#202 A3)` to the
   next `^fi$` (FAIL if empty or without `read -r wn wl`); stubs `up(){ echo 100; }`, `err`, `umount(){ :; }`,
   `STAGE`/`MNT` = empty temp dirs, `mode=--on-join RDOK=1`, `set -u`. Cases: `$WRITES` missing → rc 0, stderr
   empty, `wn=0 wl=0`; `25 90` → rc 1 + "write rate-limited (25 writes this boot)"; `5 90` → rc 0, `wn=5 wl=90`.
3. **Negative control inside the test**: a mutant of the product file with the old line restored must produce a
   stderr containing `can't open` in case 2a and exactly one lint hit. When the product still carries the old line
   the mutant equals the product: case 2a itself FAILs with that stderr (noted in the output).
4. Zero cases run = FAIL; no busybox = FAIL. Every FAIL line starts `FAIL cfgsave-stderr-quiet:`; last line
   `CFGSAVE-STDERR-QUIET cases=N fails=M`.

## 7. Delivery (#290: the harness lands first)
- **PR A (harness)** `harness/320-cfgsave-stderr-quiet`: this doc, the test, its line in
  `scripts/test-prov-p1-stubs.sh` (`stub 'fails=0$' cfgsave-stderr-quiet .`), its ci.yml step in the P1 stub job
  (red on purpose on a pre-#320 product, `::error … expected red until fix/320-cfgsave-stderr lands`), and a
  `scripts/validation-known-failures.txt` entry (`prov-p1-stubs`, ERE
  `^FAIL (prov-p1-stubs: )?cfgsave-stderr-quiet: `, #320, expires 2026-11-30 = estimate of PR B merge + 14 d).
- **PR B (product)** `fix/320-cfgsave-stderr`, stacked on A: the 22 lines + 3 deploy copies. CI on B runs A's test
  green; the 4 deploy copies are checked by provisioning-sync; both boards' sections in the body (bcm2710 not available — 2026-10-23 decision).
