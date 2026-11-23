# PR D (se608 core + fakechip + se-lab) code review: reviewer B

Scope: untracked files in `C:/src/Batman-255d` (branch `feat/255-se608-core`, base `4eba26d`):
`feed/batman-prov/src/se608/{doc,crc,packet,dev,image,i2c_linux}.go` + tests, `se608/fakechip/fakechip.go`,
`cmd/se-lab/{main,main_test}.go`. Focus: integration, packaging, project rules, se-lab as a rig tool, tests. Chip
protocol details are reviewer A's. Agreed deferrals (Sign, ECDH, CheckMac, GenKey, burn flow, se-sign / cert-size
CI, helper wiring, prov_test fault seam, fakechip P-256 / CheckMac / per-slot locks) are not findings.

Nothing under review was modified; all experiments ran on copies in WSL `/tmp`. No hardware, node or network touched.

## Evidence summary

### ✅ Verified (raw output)

**CI-equivalent run** (WSL Ubuntu-24.04, go1.26.4, `GOFLAGS=-mod=vendor GOTOOLCHAIN=local`, private GOCACHE):

```
== gofmt         (se608 cmd/se-lab)            -> no output, rc=0
== vet  ./...                                    rc=0
== test ./...    all 18 packages ok (se608 0.005s, cmd/se-lab 0.198s, provstore 118s ...), rc=0
se608:   17 tests PASS   (TestCRCVectors ... TestIdleAfterEverySequence)
se-lab:   6 tests PASS   (TestWriteImageThenCompare ... TestUsage)
```

Root + `-tags prov_test` step (ci.yml:148-156 equivalent, as root):

```
ok batman-prov/cmd/se-lab 0.194s   ok batman-prov/se608 0.003s   (all 17 test packages ok)
rc=0 skips=0 passes=501
```

**Packaging.** `feed/batman-prov/Makefile:21` `GO_PKG_BUILD_PKG:=batman-prov/cmd/batman-provhelper batman-prov/cmd/batman-provd`.
Dependency closure:

```
batman-provhelper: 0      (go list -deps | grep -c 'se608\|fakechip')
batman-provd: 0
batman-provhelper prov_test: 0
batman-provd prov_test: 0
importers of se608: batman-prov/cmd/se-lab, batman-prov/se608, batman-prov/se608/fakechip
```

So se608, fakechip and se-lab cannot reach either shipped binary today. `Build/Prepare` copies `./src/.` into the
build dir (sources only, nothing installed). Static arm64 build works:
`ELF 64-bit LSB executable, ARM aarch64, statically linked` (2.9 MB); armv7 also builds.

**Lints / harness.** No lint, allowlist, path table or manifest enumerates Go packages under `feed/batman-prov/src`
(grep of `.github/workflows`, `scripts/`, `tests/`). `payload-manifest-sync`, `provisioning-sync`, `ab-shared-change`,
`hardening-env-sync` have path filters that do not match the new files. `check-tmp-trust.sh` PAT (line 23) does not
match `/run/lock/...` (see MAJOR-1 for why that is a gap, not a pass). leak-canary deny-list: 0 hits on the new
files; no `PRIVATE-DO-NOT-PUBLISH`. No harness file needs changing, so #290 (harness-first) is not triggered; the new
tests run in CI automatically through `go test ./...`.

**Re-runnability after an interrupted write-image** (my fault-injection test on a copy: the bus fails every command
packet after the k-th, then write-image is run again, then compare):

```
k=6  first rc=1 (config block 1: ... send Read: bus gone)          rerun rc=0 equal=true compare rc=0 equal=true
k=7  first rc=1 (config block 2: ...)                               rerun rc=0 equal=true compare rc=0 equal=true
k=10 first rc=1 (config word 5 (bytes 20-23): ... send Write ...)   rerun rc=0 equal=true compare rc=0 equal=true
k=20 first rc=1 (config word 19 (bytes 76-79): ...)                 rerun rc=0 equal=true compare rc=0 equal=true
```

**Existing mutation controls** (`scratchpad/prd/mut.log`, `mut2.log`): the script counts a kill only when the named
test prints `--- FAIL:` (a build failure is reported as SURVIVED and redone in mut2), so the kills are real. All 16
listed mutants are killed after mut2.

### ⚠️ Not verified / inferred

- gitleaks not available locally; not run. The new files hold no key-like strings (only short serial bytes).
- Everything about real chip timing, EEPROM torn writes and the wake pulse on the real bus: no chip (E0a/E1 will).
- Raspberry Pi OS sysctls (`protected_regular` etc.) assumed equal to Debian/Ubuntu defaults; checked on WSL
  Ubuntu 24.04 only (`fs.protected_regular = 2`, `fs.protected_symlinks = 1`, `/run/lock` = `drwxrwxrwt root root`).

## Findings

### MAJOR-1: the chip lock lives in world-writable `/run/lock`; any local user (or our own non-root run) can lock se-lab out

Scenario A (our own mistake, the likely one). On Raspberry Pi OS the first user is in group `i2c` and
`/dev/i2c-1` is `root:i2c 0660`, so `se-lab info` works without sudo. That run creates
`/run/lock/batman-se608.lock` owned by the developer, mode 0600 (`main.go` `lockChip`, `O_CREAT ... 0o600`). The next
`sudo se-lab write-image` fails: with `fs.protected_regular` set, root's `O_CREAT` open of another user's file in a
sticky world-writable dir is EACCES. It stays that way until reboot or a manual `rm`.

Scenario B (local unprivileged process). Any uid can create the file first, or create a 0666 one and hold `flock`
on it, and deny every later se-lab run.

Evidence (WSL, built se-lab, `-bus /nonexistent` so only the lock path is exercised; exit 1 = got past the lock):

```
user runs first:  se-lab: se608: open /nonexistent: ...   user-rc=1   -> -rw------- yello yello .../lk
then root:        se-lab: refused: chip lock /tmp/rvbstk/lk: permission denied   root-rc=3
A (user pre-creates 0666): se-lab: refused: chip lock .../lockA: permission denied   rc=3
B (user holds flock):      se-lab: refused: chip lock .../lockB: permission denied   rc=3
C (symlink to /root file): refused rc=3; target unchanged (secret, -rw-r--r-- root)
```

(Tested in a 1777 dir under `/tmp` with the same mode as `/run/lock`.)

Integrity is not at risk: the open is `O_NOFOLLOW`, there is no `O_TRUNC`, nothing is written, and it fails closed.
So the impact is availability on the rig only. It is MAJOR because:

- it breaks a written project rule. `docs/design/REVIEW.md` §5 Privilege says root code that opens a path in a
  world-writable dir "is a finding". `check-tmp-trust.sh` lists `/var/lock` as untrusted, and on Debian `/var/lock`
  is a symlink to `/run/lock`, so the lint passes only because of how the path is spelled;
- it contradicts the design. `255-phase1-impl.md` §2.2 line 65 puts the chip lock in "a lock file under the
  root-only run dir". Yet `lockChip`'s comment says the helper and se-burn will share this lock later. If PR 2 copies
  `lockChip` and its default path, C8's single chip owner gets a lock any uid can take.

Fix (either one; about 5 lines):

- (a) Recommended: `flock` the opened `/dev/i2c-N` fd itself. There is no path to plant, every process that can
  reach the bus locks the same inode, and the helper in PR 2 can do the same. Or:
- (b) Require `geteuid()==0` for every command and lock `/run/batman-se608.lock` (`/run` is root 0755). Keep
  `O_NOFOLLOW` and add an `fstat` check for owner 0, a regular file and nlink 1.

Then state the lock path as a contract in the design (one row: who takes it, se-lab / helper / se-burn).
Negative control: a test that pre-creates the lock as a foreign-owned file or a symlink and asserts the outcome.
Today nothing tests this: the mutants that drop `O_NOFOLLOW` or change 0600 to 0666 both SURVIVE (see MINOR-2).

### MINOR-2: mutation gaps; survivors found with the same kill rule as `mut.sh`

My run (`scratchpad/rvb-mut.sh`; KILLED = some `--- FAIL:` line):

```
SURVIVED main.go:   Image(true, cfg[17]) -> Image(true, 0)
SURVIVED main.go:   drop O_NOFOLLOW
SURVIVED main.go:   lock mode 0o600 -> 0o666
SURVIVED main.go:   DataAddr(slot,0,0) -> DataAddr(0,0,0)
SURVIVED dev.go:    chunk := words[i:min(i+wordsPerSeq,...)] -> words[i:]   (all 23 writes in one wake)
SURVIVED dev.go:    count-byte bounds check -> if false
SURVIVED dev.go:    case len(data) != c.RespLen -> case false
SURVIVED dev.go:    ConfigLocked: != 0x55 -> == 0x00
KILLED   main.go:   Image(true,..) -> Image(false,..); drop -allow check; skip read-back; unlock no-op;
                    info rc; compare=DIFFERENT rc
KILLED   dev.go:    s.done check;  image.go: byte16 / bytes 88-89 / byte19 changes (TestVariantImageGolden)
```

What each survivor means, and the test that would kill it:

1. **byte 17 preserve** (design §4 row 17, "keep E1's blank value"). fakechip `Blank()` sets byte 17 = 0x00, which
   is also what `Image(true, 0)` writes, so a regression that overwrites the chip's byte 17 goes unseen. Fix: give
   `Blank()` (or the test) a non-zero placeholder such as 0x5A, and assert byte 17 is unchanged after write-image.
2. **Lock-file hardening**: see MAJOR-1.
3. **Watchdog chunking**: fakechip has no watchdog, so "a sequence stays under 1.3 s" (`wordsPerSeq`) is not
   tested. Fix: let fakechip count command-execution time per wake (each Write = 45 ms, from the driver's caps or a
   knob) and drop to asleep past 1.3 s; then assert write-image passes, and that the `words[i:]` mutant fails.
4. **Count-byte bounds**: this check is the only thing stopping a panic on a count byte of 0. Demonstrated: with the
   check removed, a bus returning 0x00 gives
   `panic: runtime error: index out of range [0] with length 0`; with the check, `ErrComm: count byte 0`. Add that
   case (count 0, 1, 2, 3, 76, 0xFF) to the suite.
5. **RespLen check**: with it removed, a 4-byte answer to a 32-byte Read is accepted, and ReadConfig silently leaves
   28 zero bytes. Add a fakechip knob (wrong-length response with a valid CRC) and assert ErrComm.
6. **ConfigLocked fail-safe** ("anything but 0x55 counts as locked", `dev.go` comment): add byte 87 = 0x33 and
   assert both the driver and se-lab refuse.
7. **data-write slot** is not checked (the fake refuses every data write before the lock). Assert the address on
   the wire through `recBus`.

Also, in `TestUsage` the empty-allow-list case does not assert `r.opens == 0`, unlike its siblings.

All other tests are real black-box or fault-injecting tests. Refusal tests check the opcode log and that the config
is unchanged; compare has a negative control (blank chip gives DIFFERENT). No test passes on an empty result: the
dump checks 8 lines, info checks exact values.

### MINOR-3: the "no irreversible byte" guarantee is se-lab's, not the driver's, and `Write` accepts the OTP zone

`doc.go` says "Nothing here can lock a zone or a slot, or write a byte that cannot be written again". `Session.Write`
/ `sizeFlag` accept `ZoneOTP`, and data-zone writes after the data lock. Whether those are reversible depends on
OTP mode and slot config, which the driver does not check. The guarantee holds for se-lab only because it refuses
any chip whose config zone is locked (`main.go` refusal switch). Fix: either limit `Write` to
`ZoneConfig`/`ZoneData` in PR D and refuse `ZoneOTP`, or narrow the doc claim to "se-lab, on a chip whose config
zone is unlocked". Chip semantics: reviewer A.

### MINOR-4: Random in the core allow-list contradicts impl §2.2; the global allow-list will need restructuring in PR 2

`255-phase1-impl.md` §2.2 line 67 says the product driver does not implement Random; it is se-lab-only. Here
`OpRandom` is in `se608.allowedOps` and `Session.Random` is exported from the core package that PR 2 links into the
helper. `allowedOps` is also a package global. Design §5 needs se-lab builds with GenKey, UpdateExtra, PrivWrite
and (later) Lock, while the helper must never send them, so a single global list cannot serve both. PR 2 will have
to undo this structure. Cheap now: make the op set a field of `Dev` (or a build-tagged file), with the product set
not including Random, and list it in the PR body as a known PR 2 item.

### MINOR-5: `random`, `info` and `dump` act on chips not on the sacrificial list

§8.0 says se-lab acts only on chips on the list. info/dump are read-only, and that is defensible: you need the
serial to build the list. But `random` (Random mode 0) is ungated. On a config-locked chip, mode 0 updates the EEPROM
seed (reviewer A to confirm). Fix: gate `random` behind `-allow` like the writes, or refuse it on a locked config
zone, and say in the usage text that info/dump are the read-only exception.

### MINOR-6: E1 / E4 image artefacts are not defined by the tool

E1's pass column says "generate and attach the image". §4 (line 68) requires an independent re-computation of the
112-byte image (bytes 16-127) before E4. se-lab prints only `image_sha256`, computed over the ImageWords bytes
(92 bytes: it excludes 52-67 and 84-87), and only inside write-image/compare, which touch the bus. Nothing defines
that hash scope for the independent implementation to match. Fix: add a bus-free `se-lab image BYTE17` that prints
the image hex and the hash, and write the hash scope into config §4 / §8.1.

### MINOR-7: power loss in the middle of write-image is re-runnable except when it tears word 4

Re-run after an interrupted write-image is verified (k=6/7/10/20 above), and the flock dies with the process.
Inferred, not verified (no chip): a torn EEPROM write of word 4 (bytes 16-19: I2C address and ChipMode) could move
the chip off 0x60. se-lab has a fixed `Addr` and no `-addr` flag, so it could not reach the chip to rewrite it.
Fix options:

- write only the words whose current value differs from the image (fewer EEPROM writes, and word 4 is probably
  unchanged on a blank SSHDA part);
- write word 4 last;
- add a read-only `-addr` for recovery.

Also note in the E3 run sheet: "power loss during E3 → re-run write-image".

### MINOR-8: cmd/se-lab does not build off Linux

```
GOOS=darwin go vet ./cmd/se-lab  ->  vet: cmd/se-lab/main.go:60:20: undefined: se608.OpenI2C
```

CI is Linux only, so nothing breaks. A developer running `go vet ./...` / `go test ./...` on a non-Linux host gets a
build error. `unix.Flock` is also missing on Windows. Fix: `//go:build linux` on `main.go` and `main_test.go`.

### NIT

- Exit 1 covers both "compare differs" and "bus failure". Stdout tells them apart (`compare=DIFFERENT`). A separate
  code (e.g. 4) would make rig scripts simpler.
- `Provisional = true` has no consumer yet (planned in PR 2's CI, impl line 69). Put it in the PR 2 checklist so it
  is not lost.
- The release gate in design §2.8 (shipped image has no se backend, fakechip or se-lab) is PR 2's. A cheap
  invariant test could land now: `go list -deps` of the helper and provd under every tag combination never contains
  `se608/fakechip` or `cmd/se-lab`.

## Design conformance (beyond the agreed deferrals)

- Conforms: tests carry no build tag (PR D row); se-lab is not packaged (§5, config §8.0); the sacrificial list is
  required for writes, with a revision `00 00 60 03` stop (§8.0, E1); no lock command in the build (§5, E3);
  E0-E3 leave nothing permanent (write-image can be rewritten, verified on the fake).
- Contradicts: the chip lock location (MAJOR-1, §2.2) and Random in the core (MINOR-4, §2.2 line 67).
- PR 2 will have to undo: the global `allowedOps` (MINOR-4); the lock path, if not fixed now (MAJOR-1).

## Verdict

**APPROVE-WITH-CHANGES.** Fix MAJOR-1 (lock location, plus a negative test) before merge. Add the MINOR-2 survivor
tests (at least byte 17, count byte, RespLen, ConfigLocked fail-safe, the lock-file tests). Settle MINOR-3, 4, 5 and
6 in code or in the PR body / PR 2 checklist. Packaging isolation and CI are clean (vet/test rc=0; root prov_test run
501 PASS / 0 SKIP).

---

# Round 2 (after the author's fixes; prD-changes.md)

I re-reviewed all the changed code: `se608/*` including the new `i2c_linux_test.go`, `fakechip`, and `cmd/se-lab`.
I also checked the design edits: impl §5, the §4.4 fake-chip row, the §9 PR D1/D2 rows, and config E15. As before,
I did not modify any code and touched no hardware; experiments ran on copies in WSL `/tmp`.

## ✅ CI-equivalent re-run

```
gofmt -l se608 cmd/se-lab          -> (none) rc=0
go vet ./...                        rc=0
go test ./...                       all packages ok, rc=0 (se608 + se-lab: 31 tests PASS, 0 FAIL/SKIP)
root, -tags prov_test, -count=1 -v  rc=0 skips=0 passes=517
go list -deps (provhelper, provd) x (no tag, prov_test): se608 count 0 / 0 / 0 / 0
GOOS=windows go vet ./se608/... ./cmd/se-lab/  rc=0
GOOS=darwin  go vet ./se608/...                rc=0
GOOS=darwin  go vet ./...  fails only in provstore/health/sock (Linux-only syscalls that were already there), not in the new code
static arm64 build of se-lab: ok
```

## Round-1 findings: are they fixed, and is there a negative control?

| R1 | Fixed? | Negative control (evidence) |
|---|---|---|
| MAJOR-1 lock in /run/lock | ✅ No lock file and no `-lockfile` flag. `OpenI2C` takes `O_NOFOLLOW` plus `flock(LOCK_EX\|LOCK_NB)` on the device fd; EWOULDBLOCK becomes `ErrBusy`, which se-lab maps to exit 3 | Author's mutants on LOCK_EX\|LOCK_NB and O_NOFOLLOW: KILLED. My mutant on the EWOULDBLOCK mapping: KILLED. On a **character device**, which the regular-file unit test does not cover: second `OpenI2C("/dev/null")` in the same process → `ErrBusy`; with `flock -n /dev/null sleep 3` in another process → `ErrBusy` |
| m2.1 byte 17 | ✅ `-byte17` is required; write-image refuses on a mismatch; the fake's byte 17 is 0x3B | Mutants on `Image(true, byte17)` and the byte17-differs case: KILLED |
| m2.3 watchdog | ✅ The fake charges each command its max time + 20 ms and sleeps past 1.3 s | `wordsPerSeq=100`: KILLED. My mutants: no `spent` reset on wake, and zero charge, both KILLED |
| m2.4 count byte | ✅ `TestZeroCountByte` | KILLED |
| m2.5 RespLen | ✅ `TestRespLenMismatch` | KILLED |
| m2.6 lock byte ≠ 0x55 | ✅ `TestConfigLockedAnyNon55`, plus a se-lab 0xAA case | KILLED |
| m2.7 data-write slot | ✅ Packet asserted (slot 9); `TestDataAddr` | KILLED |
| m3 OTP | ✅ `Write` refuses `ZoneOTP` before the bus | KILLED |
| m4 Random in core | ⚠️ Kept for D1 and moved to the §9 PR D2 row (split of product and se-lab lists); `doc.go` says so | Acceptable as a recorded deferral |
| m5 random ungated | ✅ random needs the allow list, a 608B revision and an unlocked config | Allow-list mutant: KILLED. Locked-config case: see R2-MINOR-3 |
| m6 image artefact | ✅ `se-lab -byte17 HH image` (no bus); SHA over bytes 16-127 | KILLED (`TestImageOffline`, which also checks `opens == 0`) |
| m7 power loss / word 4 | ✅ Only differing words are written, word 4 last; re-run writes nothing when equal | `writeOrder` and the differing-only check: KILLED (author and mine) |
| m8 non-Linux | ✅ `//go:build linux` on se-lab and on `i2c_linux_test.go` | windows / darwin vet rc=0 for the new packages |
| nit exit codes | ✅ compare differs = 4 | KILLED |
| nit `go list -deps` guard, `Provisional` consumer | ⚠️ Moved to the §9 PR D2 row | Recorded deferral |

On the author's mutation logs: `mut3.log` has one SURVIVED (`wordsPerSeq=100`), which `mut4.log` fixes (KILLED). The
second `mut4` line is an identity "mutant" (4 → 4) that is expected to survive: a sanity check, not a gap. The kill
rule is still "the named test prints `--- FAIL`", so a build failure never counts as a kill.

## What the fixes introduce

- **flock on a char device.** It works: the VFS flock is per open file description; see the `/dev/null` evidence
  above. Who can hold it: anyone who can open `/dev/i2c-N`. On the rig that is root and group `i2c`. Those are the
  same principals who can already drive the bus directly, so the lock gives a local user no new power. A uid outside
  `i2c` can no longer plant or hold anything (with the R1 lock file it could). Tools that do not flock (i2c-tools,
  kernel drivers) are not excluded; that is stated in `OpenI2C`, and E0a covers what else is on the bus. One
  semantic change is not written down: this is a **bus** lock, not a chip lock (see R2-MINOR-1).
- **Differing-only writes, word 4 last.** Correct, and covered by `TestImageRewriteOnlyDiffers`. The R1
  fault-injection re-run still holds by construction: a re-run reads the chip and rewrites what still differs.
- **`-byte17` refusal.** Checked after revision, allow list and lock. compare with a wrong `-byte17` reports
  `differs byte=17` (exit 4), which is tested.
- **The watchdog model** is a cost model (worst-case charge per command), not wall-clock time. This is the right
  kind of control for "a sequence must fit". With the current costs a 20-write sequence (exactly 1.3 s) would pass,
  so only `wordsPerSeq` at 21 or more is caught; that is fine for a 4-word design.
- **Exit 4** is distinct and documented in the usage text.

## Round 2 findings

### R2-MINOR-1: two lock contracts for one resource; impl §2.2 not updated, plus a stale comment

- impl §2.2 line 65 still says the helper's chip lock is "a lock file under the root-only run dir". The new §9
  PR D1 row and the code say "the chip lock = flock on `/dev/i2c-N`".
- `se608/dev.go:36` still says "cmd/se-lab: flock on a lock file".

Today only se-lab runs, and only on the rig, so nothing breaks. But PR 2 will meet two different contracts. The
device flock locks the whole bus, not the chip. If the helper holds it for life, as §2.2 says, then any later
bus user that respects flock (for example `batpower` if it ever adopts the lock) would be locked out of the RTC /
other devices on the same bus.

Fix: one sentence in §2.2 choosing the contract, with that consequence stated. For example: "chip lock = flock on
the bus device; other bus users (batpower) never flock it". Also fix the `dev.go:36` comment.

### R2-MINOR-2: E0a row does not record what the change table says it does

`prD-changes.md` says for A-m4: "E0a records the bus speed and general-call ACKs". The config doc E0a row (line 198)
is unchanged; the only place this appears is a code comment (`dev.go:74-75`). Fix: add "record the adapter speed
(`/sys/.../i2c-1/...` or the dtparam) and whether anything ACKs the general call" to the E0a row.

### R2-MINOR-3: the refusal checks are tested on one command each

My mutants, each of which exempts a single command (kill rule: some `--- FAIL`):

```
SURVIVED  case se608.ConfigLocked(cfg)  -> case cmd == "write-image" && se608.ConfigLocked(cfg)
SURVIVED  if rev != Rev608B             -> if cmd != "data-write" && rev != Rev608B
SURVIVED  if rev != Rev608B             -> if cmd != "compare"    && rev != Rev608B
SURVIVED  if rev != Rev608B             -> if cmd != "random"     && rev != Rev608B
KILLED    case !allowed[sn]             -> case cmd != "random" && !allowed[sn]
```

The checks are single, shared code today, so this is a guard against a future refactor, not a live bug. One case
matters for E2, though. On a chip whose config zone is locked but whose data zone is open, a `data-write` that
slipped past the locked-config check would really write slot data: the fake accepts it, see `TestDataAddr`. Fix: add
`TestRefusals` rows for `data-write` and `random` on a config-locked chip, and for `compare` / `data-write` /
`random` on a wrong revision.

### R2-MINOR-4: the image hash convention for the bytes the image does not write is not in the design

`printImage` and `image_sha256` cover bytes 16-127, with 52-67 (counters, "不碰") and 84-87 ("不寫") as 0x00. §4 /
§8.1 do not say this. The independent re-computation before E4 (§4, line 68) has to use the same convention, or the
two hashes will never match. Fix: one line in §4 or §8.1: "the image and its SHA-256 treat bytes 52-67 and 84-87
as 0x00".

### NIT

- write-image prints `written=yes` even when no word differed and nothing was sent. `written_words=N` would make
  the E3 record exact; it would also show that a re-run after a power loss wrote only the remainder.

## Round 2 verdict

**APPROVE.** No BLOCKER or MAJOR is open. R1 MAJOR-1 is fixed, with real negative controls, including on a character
device. Every R1 MINOR is either fixed with a killed mutant, or deferred to PR D2 and written in §9. R2-MINOR-1, 2
and 4 are one-line document fixes plus a stale comment. R2-MINOR-3 is a few extra table rows. I recommend doing all
of them before merge, but none blocks it.
