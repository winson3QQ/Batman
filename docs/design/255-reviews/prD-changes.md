# PR D1 code review → changes (branch feat/255-se608-core)

Round 1: Reviewer A (review-prD-A.md) = 0 / 1 / 10, APPROVE-WITH-CHANGES; Reviewer B (review-prD-B.md) = 0 / 1 / 7, APPROVE-WITH-CHANGES.
A verified the CRC by compiling cryptoauthlib's own atCRC (three vectors equal); both confirmed the packages cannot reach batman-provhelper / batman-provd (`go list -deps`).

| Finding | Handling |
|---|---|
| A-M1 narrowed scope not written down | impl §9 splits PR D1 (this) / PR D2 (rest, incl. cert-size CI); §5, §4.4 row and config E15 point to D2 |
| B-M1 chip lock in world-writable /run/lock | Lock = exclusive flock on the `/dev/i2c-N` device itself (`se608.OpenI2C`, O_NOFOLLOW); no lock file, no `-lockfile` flag; test: second open → ErrBusy, symlink refused |
| A-m1 / B-m2 byte 17 taken from the chip | `-byte17` (the E1 value) required for image / compare / write-image; write-image refuses a chip whose byte 17 differs; fake byte 17 = 0x3B |
| A-m2 / B-m2 no watchdog in the fake | Fake charges each command its max time + 20 ms margin, sleeps past 1.3 s; TestWatchdogControl (23 writes in one wake fail; chunked all-23 write passes) |
| A-m3 / B-m2 DataAddr, data-write slot untested | TestDataAddr (fake slot buffers); se-lab test checks the packet's slot address |
| A-m4 wake byte, bus speed | Marked PROVISIONAL(E0a); E0a records the bus speed and general-call ACKs |
| A-m5 reset word before receive | Marked PROVISIONAL(E1) |
| A-m6 / B-m5 `random` ungated | random needs the allow list, revision, unlocked config |
| A-m7 / B-m2 O_NOFOLLOW, count check, RespLen, lock byte untested | Tests added for each (mutants killed) |
| A-m8 / B-m6 revision stop, 92-byte hash, offline image, word 4 first | Any chip-reading command exits 3 on a wrong revision; hash over bytes 16-127; `se-lab image` (no bus); word 4 written last |
| B-m7 power loss mid write | Only differing words written, word 4 last; re-run rewrites what is still different |
| B-m3 Write accepts OTP | Driver refuses the OTP zone |
| B-m4 Random in the core allow-list | Kept for D1; PR D2 splits the product and se-lab lists (impl §9) |
| A-m9 i2c-tools not stopped by flock | Stated in OpenI2C; the rig runs nothing else on the bus |
| A-m10 fake fidelity | Assumptions marked PROVISIONAL; replaced by E1-E3 captures |
| B-m8 / A nit non-Linux build | `//go:build linux` on se-lab |
| B nit exit codes | compare differs = exit 4 |
| B nit `go list -deps` guard, `Provisional` consumer | PR D2 (impl §9) |
| A nit wordSleep unused | Removed |

Negative controls after the changes: 29 mutants, all killed (scratchpad prd/mut3.log, mut4.log; the second line of mut4 is the unmutated control). Round 2 added 3 more, all killed (mut5.log).

## Round 2

Reviewer A round 2 = 0 / 1 / 2, APPROVE-WITH-CHANGES (MAJOR = design text only). A confirmed flock works on a character device (/dev/null) and every round-1 code finding is fixed. The count of real kills was 29 plus one identity control, not 30.

| Finding | Handling |
|---|---|
| A2-M1: the lock contract in the docs was still a lock file; H1, cert size and the dev.go comment still pointed at PR D | impl §2.2 and config §5.1 now say: exclusive flock on the opened `/dev/i2c-N`, no lock file. H1 (§4.2, §9) comes after PR D2, and the cert-size CI moves to PR D2. dev.go comment fixed |
| A2-m1: the fake watchdog only caught more than 20 writes | Default lowered to 700 ms. Mutant wordsPerSeq = 11 killed |
| A2-m2: random on a locked chip untested | Test case added. Mutant killed |
| A2 nits | Test for `dump` on a wrong revision (mutant killed); /dev/null added to TestOpenI2CLock |

Reviewer B round 2 = 0 / 0 / 4 + 1 nit, APPROVE. A flock on a character device was also checked from another process (`flock -n /dev/null`).

| Finding | Handling |
|---|---|
| B2-m1: two lock contracts; the flock covers the whole bus | One contract (impl §2.2, config §5.1). It blocks only programs that flock; whether the helper holds it for life is decided in PR 2 |
| B2-m2: E0a row not updated | Config §8.2 E0a records the bus speed and any general-call ACKs |
| B2-m3: refusals tested on only one command | TestRefusals rows: data-write on a locked chip; wrong revision for data-write / random / compare. Mutants killed (mut6.log) |
| B2-m4: image hash rule | Config §4 defines the hash as SHA-256 over bytes 16-127, with unwritten bytes counted as 0x00 |
| B2 nit: `written=yes` | `written_words=N` (0 on an equal chip, tested) |
