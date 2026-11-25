# #255 PR D review — reviewer A (se608 driver core, fake chip, se-lab)

Code: worktree `C:/src/Batman-255d` (branch `feat/255-se608-core`, base 4eba26d), untracked files
`feed/batman-prov/src/se608/*`, `se608/fakechip/fakechip.go`, `cmd/se-lab/*`.
Design: `C:/src/Batman-255` branch `design/255-key-authority` (a15d825): `255-phase1-impl.md` §2.2, §5, §9;
`255-608b-config.md` §4, §7, §8.0–§8.2.
Scope I reviewed against: the agreed narrowed PR D (E0–E3 only; no lock or other irreversible command).

## What I verified and how

Primary source: cryptoauthlib `main`, fetched raw from GitHub on 2026-11-23 into the scratchpad (`scratchpad/cal/`).

| Claim in the code | Result | Evidence |
|---|---|---|
| CRC-16 poly 0x8005, init 0, LSB-first data bits, no final XOR, LE on the wire (`crc.go:5-24`) | ✅ identical algorithm | `lib/calib/calib_command.c:706-729` `atCRC`: `polynom = 0x8005u`, `shift_register = 0x01` … `crc_le[0] = crc_register & 0xFF`. CRC is computed over `&packet->txsize` (count byte onward) — `calib_command.c:736-754`; matches `appendCRC(p, 1)` (`packet.go:66`). |
| Test vectors `04 11→33 43`, `07 30 00 00 00→03 5D`, `07 02 80 00 00→09 AD` | ✅ | I compiled cryptoauthlib's own `atCRC` (copied verbatim) with gcc in WSL: `04 11 -> 33 43`, `07 30 00 00 00 -> 03 5d`, `07 02 80 00 00 -> 09 ad`, also `0b 12 00 05 01 01 02 03 04 -> fe f6`, `04 00 -> 03 40`. Independent of the Go code. |
| Packet = word 0x03, count (=7+data, counts itself and CRC), opcode, p1, p2 LE, data, CRC | ✅ | `atCalcCrc` LE `param2` (`ATCA_UINT16_HOST_TO_LE`), `calib_execution.c:353` word address prepended by `calib_execute_send`. |
| Opcodes Read 0x02, Write 0x12, Random 0x1B, Info 0x30; Lock 0x17, UpdateExtra 0x20 | ✅ | `calib_command.h:232-246`. |
| 32-byte flag 0x80, zone bits 0–1; config/OTP addr = block<<3\|word; data addr = slot<<3\|block<<8\|word | ✅ | `calib_command.h:329`; `calib_basic.c:214-247` `calib_get_addr`. |
| Info mode 0 = revision | ✅ | `calib_command.h:515` `INFO_MODE_REVISION 0x00`. |
| Wake: write to address 0x00, wait 1500 µs, read 4 bytes, expect `04 11 33 43` | ✅ with one divergence (MINOR-4) | `calib_basic.c:37-105` `calib_wakeup_i2c`: address set to 0, `atsend(iface, second_byte, NULL, 0)` → `hal_linux_i2c_userspace.c` `hal_i2c_send` does `ioctl(I2C_SLAVE, 0)` + `write` of one byte; `atca_cfgs.c:58` `.wake_delay = 1500`; `lib/hal/atca_hal.c:374-392` `expected_response = {0x04,0x11,0x33,0x43}`. Current cryptoauthlib sends **0x01** as the byte, not 0x00. |
| Idle = word 0x02, sleep = word 0x01 | ✅ | `calib_basic.c` `calib_idle` "`uint8_t command = 0x02`", `calib_sleep` "`command = 0x01`". |
| Poll by reading the count byte, then the remainder in a second read | ✅ (plus a reset write the driver omits, MINOR-5) | `calib_execution.c:378-467`: `read_length = 1` → `atreceive` → `read_length = rxdata[0]` → `atreceive(&rxdata[1], read_length-1)`. Before each receive it sends word address 0 (`atsend(..., word_address=0, NULL, 0)`, line 421). |
| Exec caps Info 5, Read 5, Write 45, Random 23 ms | ✅ and clock-divider-independent | `calib_execution.c` tables `device_execution_time_608_m0/_m1/_m2`: Info 5, Random 23, Read 5, Write 45 in **all three** — so the unknown blank ChipMode clock divider does not matter for these four commands. cryptoauthlib polls up to `ATCA_POLLING_MAX_TIME_MSEC` (much longer); the driver's cap (MaxExec+20 ms) is tighter but ≥ the library's expected time. |
| Status codes 00/01/03/05/07/08/0F/11/FF | ✅ | `calib_command.c:840-880` `isATCAError`. 0xEE (watchdog) is not in cryptoauthlib; ⚠️ datasheet-summary only, unverified here. |
| 4-byte config writes accepted; bytes 84-87 skipped | ✅ | `calib_write.c` `calib_write_bytes_zone`: 4-byte writes for every non-aligned word and for all of block 2, and "Skip trying to change UserExtra, Selector, LockValue, and LockConfig" for block 2 word 5 (= bytes 84-87 = driver's word 21). `calib_write_config_zone` writes 16..127 this way. |
| Bytes 0-15 not writable | ⚠️ inferred | cryptoauthlib never writes them (`calib_write_config_zone` starts at 16); the fake's status 0x0F for them is a guess (marked PROVISIONAL). Driver never addresses them, so no risk. |
| SlotConfig/KeyConfig stored little-endian | ✅ (convention) | matches cryptoauthlib config parsing conventions; image table checked by hand below. |
| Serial = bytes 0-3 + 8-12 | ✅ | `calib_read.c:139-145` `memcpy(&serial_number[0], &read_buf[0], 4); memcpy(&serial_number[4], &read_buf[8], 5)`. |
| Image table = config §4 + §8.1 | ✅ | I checked `image.go:9-28` and the hand-transcribed golden (`packet_test.go:97-139`) byte by byte against §4 (slots 0/1/2 2081/2082/2084 + 0073; 5, unused 8F9F+001C; 8 0F0F+003C; bytes 16=C0, 17 kept, 18=00, 19=00, 68-83=0, 88-89=FFFF, 90-91=0000, 92-95=0) and §8.1 (3 0F8F/003C, 4 2083/0073, 6 0F0F/003C). Counters 52-67 and 84-87 not written, as §4 says. |
| Revision `00 00 60 03` | ⚠️ not verifiable from cryptoauthlib source here; taken from config §4 / E1 gate. |
| I2C_SLAVE ioctl with address 0 accepted by i2c-dev | ✅ by precedent | cryptoauthlib's Linux HAL does exactly that (`ioctl(f_i2c, I2C_SLAVE, device_address >> 1)` with address set to 0). Kernel source not re-read. |

Build/tests (WSL Ubuntu-24.04, go1.26.4, `GOFLAGS=-mod=vendor GOTOOLCHAIN=local`):

```
VET-OK
ok  	batman-prov/se608	0.014s	coverage: 74.3% of statements
	batman-prov/se608/fakechip		coverage: 0.0% of statements
ok  	batman-prov/cmd/se-lab	0.213s	coverage: 82.8% of statements
/tmp/se-lab-revA: ELF 64-bit LSB executable, ARM aarch64, ... statically linked
```

CI already runs `go vet ./... && go test ./...` in `feed/batman-prov/src` (`.github/workflows/ci.yml:146`), so the
new tests are picked up.

### Author's mutation controls (`prd/mut.log`, `mut2.log`)

Meaningful: each mutant is applied in a /tmp copy and judged by `--- FAIL: <named test>`, not just rc. Count:
`mut.log` 12 KILLED + `mut2.log` 4 KILLED = **16 real kills**, not 19. Three lines in `mut.log` are not controls:
two "SURVIVED" were compile failures (`declared and not used: deadline` / `allowed`) and one `MUTANT-NOT-APPLIED`;
`mut2.log` redid those three correctly. The PR body should say 16.

### My own mutation probes (`scratchpad/revA/mut.log`, whole test suite per mutant)

```
SURVIVED no-tWHI            (wake read without the 1.5 ms wait)
SURVIVED wake-byte-01       (general-call payload 0x00 -> 0x55)
SURVIVED dataaddr-wrong     (DataAddr slot<<3 -> slot<<4)
KILLED   wake-accept-any    (TestStaleAwakeChip)
KILLED   wake-no-idle       (TestStaleAwakeChip)
SURVIVED one-big-seq        (wordsPerSeq 4 -> 100: 23 writes, ~1.5 s, one wake)
SURVIVED no-pollFirst
KILLED   status-not-checked
SURVIVED count-range        (count byte range check removed)
SURVIVED random-mode1
KILLED   info-mode
SURVIVED nofollow           (O_NOFOLLOW dropped from the lock open)
KILLED   lock-recheck-removed
KILLED   readback-skip
SURVIVED byte17-zero        (image built with byte17=0 instead of the chip's)
```

The safety-critical ones (opcode allow-list, lock-byte refusal, allow list, revision, read-back) are all killed. The
survivors are timing (only the rig can test), and the gaps listed in MINOR-1, -2, -7.

## Can anything here change a chip for good?

I traced every path that reaches `Bus.Write(Addr, …)`:

- `Session.Exec` (`dev.go:104-110`) refuses any opcode not in the unexported `allowedOps` (`packet.go:27`: Read,
  Write, Random, Info) **before** encoding or touching the bus. Opcodes come only from constants in the driver; no
  response byte feeds an opcode or a parameter. A crafted response can only produce an error or data that se-lab
  prints. `TestExecRefusesIrreversibleOps` covers Lock, UpdateExtra, GenKey, PrivWrite and others; killed by mutation.
- Other bus writes: wake pulse (address 0x00, one byte), idle (`0x02`) to 0x60. Neither is a command.
- Write is the only mutating command. Before the config lock every config byte it can address is rewritable, and the
  data/OTP zones refuse writes until the config is locked (E2 tests exactly that). se-lab gates both of its write
  paths on: allow list present and non-empty → chip lock → Info revision == `00 00 60 03` → serial on the list →
  byte 87 == 0x55 (anything else counts as locked, `dev.go:241`). `WriteConfigImage` re-reads and re-checks byte 87
  itself (`dev.go:266-272`). So the tool cannot write to a config-locked chip, and therefore never to a chip whose
  data zone it could change for good.
- Stale-awake chip (process killed mid-sequence): wake reads the stale buffer, sends idle, retries once; a chip still
  executing a previous command NACKs and the run fails with ErrNoResponse/ErrWake. Nothing is sent but idle.
  Interrupted write-image or power loss mid-write: the chip is unlocked, so rerunning write-image + compare repairs it.
- No-chip case (U3 empty, which is the HAT's current state): wake read NACKs → `ErrNoResponse`, exit 1. Safe.

No BLOCKER on irreversibility found.

## Findings

### MAJOR-1 — The narrowed scope is not written down in the design or the issue

Scenario: PR D merges as "PR D". The design still says PR D delivers more: impl §9 PR D row "`se-sign` 的憑證部分（先算憑證大小）";
impl §5 se-lab "要有：直通 nonce + 外部簽章、GenKey 各模式…UpdateExtra…AES"; impl §4.4 fake chip row "每槽的鎖、真的 P-256
金鑰、CheckMac 真的比對"; config §8.2 E15 "憑證大小在開發者電腦上先算（PR D 時）". H1 is scheduled "PR D 之後" and
needs the fuller fake chip. Without an edit, the next reader treats those as done, or they are lost (the 2026-10-28
H2 case: scope cut written only as "follow-up").
Evidence: `255-phase1-impl.md:229, 242, 325`; `255-608b-config.md` §8.2 E15 row; `git status` shows only the new
code, no doc change.
Fix: before the PR, either revise impl §5/§9/§4.4 (split "PR D core" vs. what remains and when), or write each
deferred item (cert-size CI ≤ 416, Sign/ECDH/CheckMac/GenKey/Nonce, UpdateExtra/AES/KDF/PrivWrite in se-lab, fake
chip per-slot locks + P-256 + CheckMac, `se-fail` seam) into the #255 checklist, and say in the PR body which.

### MINOR-1 — Byte 17 is never actually checked, and the image depends on the chip it is compared with

Scenario: config §4 says byte 17 "維持 E1 讀到的空白值，寫明". se-lab builds the image from the chip's *current*
byte 17 (`main.go:195` `se608.Image(true, cfg[17])`), so compare on byte 17 is a tautology, and `image_sha256`
differs per chip. A botched earlier write to byte 17 would be preserved and reported EQUAL. The fake's byte 17 is
0x00, so even the mutant "always 0" survives (`byte17-zero` above).
Fix: take the E1 value as a required flag (e.g. `-byte17 5A`) for write-image/compare, refuse if the chip's byte
differs from it before writing, and give the fake a non-zero byte 17.

### MINOR-2 — Watchdog budget per sequence has no negative control

`wordsPerSeq = 4` (`dev.go:261`) is the only thing keeping write-image under the 1.3 s watchdog; the fake has no
watchdog, so `wordsPerSeq = 100` passes every test. On the rig a too-long sequence fails safely (chip sleeps, the
next command NACKs), but the claim "far below the watchdog" is untested. Fix: the fake records wake time with the
injected clock and NACKs everything after 1.3 s; add a test that a long sequence fails and the shipped one passes.

### MINOR-3 — Data-zone address encoding is untested

`DataAddr` (`dev.go:206`) can be wrong without any test failing (`dataaddr-wrong` survived): the fake refuses every
pre-lock data write regardless of address. It matches `calib_get_addr` today, but later PRs build on it. Fix: a
fake test that locks the config (test knob) and checks that `DataAddr(8,1,2)` lands at slot 8 offset 40, plus a
packet vector for a data-zone Write.

### MINOR-4 — Wake byte differs from current cryptoauthlib; bus speed not checked

`dev.go:80` writes `0x00` after the general-call address; current cryptoauthlib writes `0x01` with the comment
"I2C general call should not interpreted as an addr write" (`calib_basic.c`, `calib_wakeup_i2c`). Per the I2C spec
a second byte of 0x00 after a general call is not allowed; 0x01 is the "hardware general call" form. It only matters
if some device on the bus ACKs the general call (DS3231 is not expected to; WM1302 HAT parts ⚠️ unknown). The wake
also only works at ≤ 100 kHz (address byte 0x00 = 8 bit times low ≈ 80 µs at 100 kHz, 20 µs at 400 kHz < tWLO 60 µs);
cryptoauthlib forces 100 kHz for the wake, i2c-dev cannot.
Fix: either switch to 0x01 or record why 0x00; whichever ships is what E0a must test. Have `se-lab info` print the
adapter's `clock-frequency` (from `/sys/bus/i2c/devices/i2c-1/of_node/clock-frequency`) and say "wake needs ≤ 100 kHz"
when it is higher. Not a safety issue: a failed wake is ErrNoResponse.

### MINOR-5 — No reset word before reading a response

cryptoauthlib sends word address 0x00 (reset the I/O-buffer pointer) before each receive (`calib_execution.c:415-421`);
the driver reads the count byte directly (`dev.go:123`). After a fresh command the pointer is at the start, so normal
use is fine; it matters for the stale-awake path, where the wake read may start mid-buffer. Mark it PROVISIONAL(E1)
next to the other wire-format assumptions, or add the reset write before the count read to match the reference.

### MINOR-6 — `random` is not gated, and mode 0 updates the EEPROM seed after the config lock

`random` runs on any chip with no allow list or revision check (`main.go:170-177`), using mode 0
(`RANDOM_SEED_UPDATE`, `calib_command.h:684`). Before the lock it is the fixed pattern; after the lock mode 0 may
write the seed to EEPROM. Not a security change, but config §8.0 says the tool acts only on listed chips and
"E0–E3 不留下永久改變". Fix: gate `random` like the writes (or at least on revision), or use mode 0x01 (no seed
update); either is fine for E2.

### MINOR-7 — Small untested protections

- `O_NOFOLLOW` on the lock file (`main.go:261`): drop it and every test passes. Add a test: symlink at the lock path
  → exit 3, target unchanged.
- Count-byte range (`dev.go:133`): no test with count 0x00 or 0xFF; without the check, count 0 would panic on
  `resp[0]` (`dev.go:137`). Add both to the fake (a knob for a raw response).
- tWHI / pollFirst can only be tested on the rig; say so in the PR's "not tested" section.

### MINOR-8 — E1 / §4 artefacts are not quite what the design asks for

- E1 says "版本不符就停", but `info`/`dump` exit 0 on any revision. Return exit 3 (after printing) when the revision
  is not `00 00 60 03`, so a scripted E1 stops.
- §4: the image is "產生並附在本文件" and recomputed by an independent implementation over **112 bytes (16–127)**.
  se-lab hashes only the 92 ImageWords bytes (`main.go:196-201`), and there is no offline command that prints the
  image. Add `se-lab image -byte17 XX` (no bus) that prints 16–127 and the hash, and define the hash input the same
  way as §4.
- Word 4 (bytes 16–19: I2C address, ChipMode) is written first (`ImageWords` order). ⚠️ Whether address/ChipMode
  take effect before the config lock is unverified. Writing them last, and refusing write-image if E1's blank bytes
  16/19 differ from the image (unless a flag says so), costs nothing.

### MINOR-9 — Lock file location

`/run/lock` is world-writable (sticky) on Raspberry Pi OS (⚠️ from memory, E0a can confirm). Any local user can
pre-create `batman-se608.lock` and hold a flock, or (with `fs.protected_regular`) make root's `O_CREAT` open fail.
Both fail closed (exit 3), so it is DoS only on a dev rig. Note it in the se-lab header; the helper's lock (impl
§2.2) is in a root-only directory, so this does not carry over. Also: on Pi OS `/dev/i2c-1` is usually group `i2c`
and the default user is in it, so the flock does not stop other tools (i2cdetect, i2cget) from talking to 0x60;
E0a should record that, as the config doc already says.

### MINOR-10 — Fake-chip fidelity notes (assumptions that could hide a driver bug)

- Wake: any write to address 0 wakes it, regardless of payload or of the tWHI wait (`fakechip.go:84-96`).
- Empty output buffer reads return 0xFF; the read pointer is never reset (real chip behaviour ⚠️ unknown).
- No watchdog (MINOR-2), no timing: `BusyPolls` counts reads, not time.
- Data/OTP writes before the config lock → 0x0F and config bytes 0-15/84-87 → 0x0F encode the hypotheses E2/E3 test;
  they are marked PROVISIONAL, which is right. Replace them with the E1–E3 captures.
- `Info` returns config bytes 4–7; on a real chip Info and bytes 4–7 may differ (E1 should record both).

### Nits

- `wordSleep` is defined but unused (`packet.go:12`); the scope says wake/idle/sleep. Either add `Dev.Sleep` or drop it.
- `cmd/se-lab/main.go` imports `x/sys/unix` without a build tag, so `go test ./...` fails on non-Linux hosts. CI is Linux; harmless.
- cryptoauthlib's self-test-failure wake constant `04 07 C4 40` (`atca_hal.c:377`) does not pass `atCRC` (I get `04 07 -> 40 c2`), so the driver prints raw bytes for that case rather than "self-test error". Fine; worth recording at E1 if it ever happens.

## Verdict

**APPROVE-WITH-CHANGES.**

No path in the driver, the fake or se-lab can send Lock, UpdateExtra or any other irreversible command, or write a
chip that is not listed, has the wrong revision, or has a locked config zone; each of those protections has a
mutation that kills a named test. The wire formats match cryptoauthlib's source wherever I could check them. The
condition is MAJOR-1: write the narrowed scope into the design or the #255 checklist before the PR. MINOR-1 (byte
17) and MINOR-8 (E1 exit code, §4 image hash) should be fixed before E1/E3 run on the rig, because they change what
the rig output proves. The rest can go in this PR or be listed in the checklist.

---

# Round 2 (after the author's fixes; handling table `prD-changes.md`)

What I re-read for this round:
- all of `se608/*.go`, now including `i2c_linux_test.go`;
- `se608/fakechip/fakechip.go` and `cmd/se-lab/*`;
- the design diff in `255-phase1-impl.md` (§4.4 fake-chip row, §5, §9 PR D1/D2 rows) and `255-608b-config.md` (E15);
- the author's `prd/mut3.log` and `mut4.log`, and the scripts that produced them.

## Re-verification

✅ Build and tests (WSL, go1.26.4, vendor), raw output (`scratchpad/revA/r2.log`):

```
VET-OK
ok  	batman-prov/se608	0.015s	coverage: 78.2% of statements
	batman-prov/se608/fakechip		coverage: 0.0% of statements
ok  	batman-prov/cmd/se-lab	0.309s	coverage: 83.6% of statements
ARM64-BUILD-OK
```

✅ **flock on a character device.** The author's `TestOpenI2CLock` uses a regular file. I added a throwaway test in a
/tmp copy that calls `OpenI2C("/dev/null")`, a real character device:

```
=== RUN   TestProbeCharDevFlock
    chardev_probe_test.go:9: /dev/stdin: se608: open /dev/stdin: too many levels of symbolic links
--- PASS: TestProbeCharDevFlock (0.00s)
```

- A second open gets `ErrBusy`. After `Close`, the device opens again.
- A path whose last part is a symlink (`/dev/stdin`) is refused with ELOOP.
- i2c-dev has no `.flock` hook of its own, so the kernel's generic flock applies, the same path /dev/null takes.
  ⚠️ This is inferred, not run on i2c-dev itself.

✅ **Author's mutation controls.**
- The scripts now run `go vet` first, so a mutant that does not compile is counted as NO-COMPILE, not as SURVIVED.
  A mutant only counts as killed when `--- FAIL` appears.
- `mut3.log` has 28 kills. One mutant survived there: `wordsPerSeq = 100` against the earlier test.
- `mut4.log` kills that same mutant with the fixed `TestWatchdogControl`. It also runs an identity mutant (4 → 4)
  that is expected to pass, which is a useful positive control.
- That makes **29 distinct mutants killed, not 30**.
- `mut3.log` has a stray `}` line (cosmetic).

### Round-1 findings: status

| R1 | Fixed? | Negative control |
|---|---|---|
| M1 scope not written | ✅ Partly. impl §9 D1/D2, §5, §4.4 and config E15 are updated. Some text is still stale: R2 MAJOR-1. | — (docs) |
| m1 byte 17 | ✅ Fixed in three places:<br>• `-byte17` is required for image, compare and write-image (`main.go:109-117`).<br>• write-image refuses a chip whose byte 17 differs (`main.go:181`).<br>• The fake's byte 17 is now 0x3B. | • My `byte17-check-any` mutant is killed (`TestRefusals/byte17_differs`).<br>• The author's `Image(true, byte17)` mutant is killed.<br>• `TestCompareDiffers` shows `differs byte=17 chip=3b image=00`. |
| m2 watchdog | ✅ The fake now has a watchdog, but its margin is weak (R2 MINOR-1). | `wordsPerSeq=100` is killed. 10, 19 and 20 survive. |
| m3 DataAddr | ✅ `TestDataAddr` checks the fake's slot buffers. The se-lab test checks the slot byte in the packet. | Killed (author). |
| m4 wake byte / bus speed | ✅ Marked PROVISIONAL(E0a) (`dev.go:73-75`). | Rig only. `no-tWHI` and `wake-byte` still survive, as expected. |
| m5 reset word | ✅ Marked PROVISIONAL(E1) (`packet.go:9-10`). | Rig only. |
| m6 random ungated | ✅ `random` now needs the allow list, the right revision and an unlocked config. | Allow list: killed. Unlocked-config gate: **no control** (R2 MINOR-2). |
| m7 untested protections | ✅ Tests added for O_NOFOLLOW, the count byte, RespLen, and any lock byte other than 0x55. | Killed (author). Character device: my probe above. |
| m8 revision stop / hash / image / word 4 | ✅ Fixed:<br>• A wrong revision now exits 3 after printing.<br>• The hash covers bytes 16-127.<br>• `image` needs no bus (`TestImageOffline` checks `opens == 0`).<br>• Word 4 is written last. | Killed (author). No control for `dump` on a wrong revision (nit). |
| m9 /run/lock | ✅ Replaced by a flock on the device itself. | `TestOpenI2CLock` and my char-device probe. |
| m10 fake fidelity | ✅ The assumptions are marked PROVISIONAL. | — |
| nits | ✅ `wordSleep` is removed, and se-lab now has `//go:build linux`. | — |

### What the fixes introduced

- **Writing only the words that differ, with word 4 last** (`dev.go:265-307`): ✅ correct.
  - The set of differing words comes from the config read at the start of the same call.
  - A second run sends no Write (`TestImageRewriteOnlyDiffers`). My `nodiff-filter` mutant is killed.
  - Because se-lab refuses a chip whose byte 17 differs from `-byte17`, word 4 can only differ at bytes 16, 18 and 19.
- **`-byte17` refusal**: ✅ It is checked after the allow list, revision and lock checks, and before any Write.
  - `compare` is read-only and not gated, so a wrong byte 17 shows up as a difference (exit 4). That is the right split.
- **Exit 4**: ✅ Both compare and the read-back after write-image use it, as the header says.
  - My `exit-differs-1` mutant is killed.
- **The fake's watchdog**: correct as a model, but see R2 MINOR-1.
  - Fidelity nit: after the watchdog fires, the fake ACKs a command and then drops it. A real chip that has fallen
    asleep would NACK the write. The driver returns ErrNoResponse in both cases.
- **Chip lock on the device**: ✅ in the code. The design text still describes a lock file (R2 MAJOR-1).
  - Fail-closed edge case: if the rig's `/dev/i2c-1` is ever a symlink (a udev alias), O_NOFOLLOW refuses it with
    ELOOP and se-lab exits 1.
  - The fix is to pass the real node with `-bus`. E0a already records the node; worth one line in the se-lab header.

## Round-2 findings

### MAJOR-1 — The design still gives a different chip-lock contract, and some rows still say "PR D"

Scenario:
- The PR 2 author implements §2.2 as written: the helper and `se-burn` take a lock file, while se-lab flocks the
  device.
- The ownership tables call all three "the chip lock", but they would not exclude each other.
- The same drift affects H1. H1 needs the `se-fail` seam and the fuller fake chip, which are now in D2, but it is
  still ordered "PR D 之後".

Evidence (branch `design/255-key-authority`, working tree):
- `255-phase1-impl.md:65`: "helper 常駐終生持有晶片鎖（root 專用執行目錄下的鎖檔，`flock` 獨占）".
- `255-608b-config.md:103`: "所有碰晶片的程式（helper 常駐、燒錄模式、實驗工具）先對 root 專用執行目錄下的一個鎖檔取得獨占鎖".
- These contradict `255-phase1-impl.md:325` (PR D1 row): "晶片鎖 = 對 `/dev/i2c-N` 本身 `flock`".
- `255-phase1-impl.md:191` and `:329`: H1 "PR D 之後".
- `255-phase1-impl.md:151`: "PR D 的 CI 以最大可能的值…建出憑證" (this work is now D2).
- `dev.go:36` still says "cmd/se-lab: flock on a lock file".

Fix (text only):
- Pick one chip-lock contract for every program that touches the chip, and write it in impl §2.2 and config §5.1.
  The device flock is the simpler choice: only a process that can open the bus can hold it, and no shared directory
  is needed.
- Move H1 (§4.2 heading and the §9 row) and the cert-size sentence (`:151`) to D2.
- Fix the comment at `dev.go:36`.

### MINOR-1 — The fake's watchdog only catches sequences of more than 20 writes

- The fake charges each write 65 ms against a 1300 ms limit.
- My mutants with `wordsPerSeq` = 10, 19 and 20 all **survive**; only 21 or more fails.
- So the control proves "an unbounded sequence fails", not the "far below the watchdog" margin the comment claims.
- ⚠️ From memory, not checked against the 608B datasheet: the ATECC parts' tWATCHDOG has a minimum well below 1.3 s
  (about 0.7 s on the 508A).
- The shipped value is fine: with the threshold set to 700 ms the suite still passes (the `wd-threshold-13` mutant
  survived), so the shipped chunks fit in 0.7 s.

Fix: set the fake's default `Watchdog` to the datasheet minimum, or to a stated conservative 700 ms, and cite the
source. Then `wordsPerSeq=10` fails and the margin is actually tested.

### MINOR-2 — No control for `random` refusing a config-locked chip

`prD-changes.md` says `random` needs "the allow list, revision, unlocked config". The mutant
`case cmd != "random" && se608.ConfigLocked(cfg):` survives, because `TestRefusals` has no "random, config locked"
case. Fix: add that case.

### Nits

- There is no test for `dump` on a wrong revision (it should print, then exit 3); the mutant that exempts `dump`
  survives. Add a "wrong revision, dump" case.
- Add `/dev/null` to `TestOpenI2CLock`, so the lock is also proven on a character device (my probe above shows it works).
- The PR body should say 29 mutants killed, plus one identity control.
- `random` still uses mode 0. That is fine now, because locked chips are refused.

## Round-2 verdict

**APPROVE-WITH-CHANGES.**

The code side is in good shape:
- Every round-1 code finding is fixed. Each fix has a negative control, or is marked PROVISIONAL for the rig.
- The new mechanisms are correct: the device flock, writing only the differing words with word 4 last, the
  `-byte17` refusal, exit 4, and the fake's watchdog.
- No path can send Lock, UpdateExtra or an OTP write, or write to a chip that is unlisted, has the wrong revision,
  or has a locked config.

The open MAJOR is design text that contradicts the code's chip-lock contract and orders H1 after the wrong PR. It is a
short doc edit plus one stale code comment. MINOR-1 is a one-line change to the fake; MINOR-2 is one test case.
