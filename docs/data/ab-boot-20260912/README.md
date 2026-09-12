# A/B boot test records — #133

Run 2026-09-11 / 2026-09-12. Bench node: **manet01 Pi 4**, EEPROM `build-timestamp`
2026-01-09, `capabilities=0x7f`, kernel 6.6.138, card = the GPT six-partition A/B card from
`scripts/build-gpt-ab-card.sh`.

## Provenance — read this before citing anything here

Two different kinds of record live in this directory, and they are not equally strong:

* **`*.log` — raw captured output.** Written directly by the tool that produced them, timestamp
  and command on line 1, never edited.
* **The matrix in this file — transcribed readings.** The failure-case matrix below was produced
  by driving the node by hand and reading `/proc/device-tree/chosen/bootloader/*` and
  `/proc/cmdline` after each boot. Those readings were transcribed into this table; the terminal
  session itself was not captured to a file. Treat the table as a faithful record of what was
  observed, not as machine-generated evidence.

There is a reason for the warning. The first scripted version of the destructive self-test
contained assertions that could not distinguish "passed" from "never ran" — the two destructive
cases both asserted `slot == A` while the node was *already* on A, with nothing confirming a
reboot had happened. A `16/16` from that version overstated what it had checked. It was caught
by an independent code review, the assertions now require `/proc/sys/kernel/random/boot_id` to
change, and `hw-mutation-no-reboot.log` is the evidence that the fix bites. The hardware
findings themselves were established by the manual readings below, before any of it was
scripted.

## Raw logs

| file | what it is | result |
|---|---|---|
| `ci-invariants-pass.log` | `tests/ab-card-invariants.sh` on a clean tree | 22 passed, 0 failed |
| `ci-mutation-bare-rootwait.log` | build script mutated to emit a bare `rootwait` | 16 passed, **6 failed** |
| `ci-mutation-gpt-index.log` | `[tryboot] boot_partition` forced back to the GPT index `3` | 20 passed, **2 failed** |
| `ci-mutation-zero-rootfs.log` | rootfs `dd` forced to `count=0` (empty root slots) | 20 passed, **2 failed** |
| `hw-destructive-pass.log` | `scripts/ab-selftest.sh <node> --destructive` | 18 passed, 0 failed |
| `hw-mutation-no-reboot.log` | the reboot command replaced with a no-op | 14 passed, **4 failed** |

The mutation logs matter more than the passing ones: a guard that cannot fail is decoration.
Each mutation reintroduces a defect this issue actually found, and each is caught.

## Failure-case matrix — transcribed readings (2026-09-11)

Columns are `batman_slot` from `/proc/cmdline`, and `partition` / `tryboot` from
`/proc/device-tree/chosen/bootloader/`.

| case | induced how | outcome | slot | part | tryboot |
|---|---|---|---|---|---|
| baseline slot A | power-on | boots A | A | 1 | 0 |
| tryboot switch | `vcmailbox 0x00038064 4 4 1` + reboot | boots B, 52 s | B | 2 | 1 |
| trial is one-shot | plain reboot | returns to A | A | 1 | 0 |
| commit B | `[all] boot_partition=2`, plain reboot | boots B | B | 2 | 0 |
| back to A | `[all] boot_partition=1`, plain reboot | boots A | A | 1 | 0 |
| `boot_partition=3` (GPT index) | `[tryboot] boot_partition=3` | tryboot entered, **switch silently did not happen** | A | 1 | 1 |
| bootB has no `start4.elf` | rename it | firmware falls back, 52 s | A | 1 | 1 |
| bootB has no `kernel8.img` | rename it | recovers, 52 s, **flag already consumed** | A | 1 | 0 |
| rootfs absent, bare `rootwait` | `root=PARTUUID=deadbeef…` | **dead hang >5 min, power cycle required** | — | — | — |
| rootfs absent, `panic=10` no `rootwait` | same root, cmdline changed | recovers 57 s — **but a healthy slot also fails to boot** | A | 1 | 0 |
| rootfs absent, `rootwait=20 panic=10` | same root, cmdline changed | recovers 77 s | A | 1 | 0 |
| rootB squashfs corrupt, `rootwait=20 panic=10` | zero first 1 MiB | recovers 62 s | A | 1 | 0 |
| healthy B, `rootwait=20 panic=10` | — | boots B normally, 52 s, no delay penalty | B | 2 | 1 |
| `autoboot.txt` truncated mid-write | simulate power cut during commit | boots partition 1 — **commit silently lost** | A | 1 | 0 |
| `autoboot.txt` absent | delete it | boots partition 1; the tryboot flag does nothing | A | 1 | 0 |
| committed B unbootable by firmware | commit B, rename `start4.elf` | falls back, 52 s, **`autoboot.txt` not repaired** | A | 1 | 0 |
| committed B broken at kernel level | set up, run aborted | **not observed** — inferred, see `storage-architecture.md` §B1 | — | — | — |

Analysis, and what each row means for #89, is in `docs/storage-architecture.md` §B1.

## Reproducing

```sh
./tests/ab-card-invariants.sh                          # no hardware, ~40 s
./scripts/ab-selftest.sh <node> --inspect-only         # no reboots
./scripts/ab-selftest.sh <node> --destructive          # 4 reboots, ~6 min, self-restoring
```
