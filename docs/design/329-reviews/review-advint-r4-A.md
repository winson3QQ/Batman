# Review r4-A — `docs/design/329-adv-interval.md` v4 (70f0f68)

Reviewer A, round 4, independent. Whole document reviewed, not only the v3→v4 diff.
No device, phone or node was touched (no ssh, no adb). Nothing was modified except this file.

**Verdict: APPROVE** — 0 BLOCKER, 0 MAJOR, 6 MINOR (text / harness-PR notes; none needs another design round).

---

## 1. What was checked, and how

### Verified against source or captured output

| Claim in the design | Evidence I read |
|---|---|
| Kernel default adv interval is 0x0800 for both min and max | `linux-6.6.138/net/bluetooth/hci_core.c:2470-2471` |
| Only writers of `le_adv_{min,max}_interval`: default, mgmt TLV, debugfs | `hci_core.c:2470-2471`, `mgmt_config.c:253,256`, `hci_debugfs.c:1011,1041` (grep of the whole tree; no other writer) |
| TLV 0x000a / 0x000b set the two fields | `mgmt_config.c:253-256`; TLV table `:82-113` |
| Instance with interval 0 falls back to the hdev default | `mgmt.c:8929-8935`; `hci_sync.c:1900-1929` |
| bluetoothd sends the keys once per adapter registration | `bluez-5.72/src/adapter.c:4869-4896` (`load_defaults`), only call site `adapter.c:9383`; `load_le_defaults` at `:4733` sends 0x000a/0x000b only when non-zero |
| No keys → nothing sent (old image behaviour unchanged) | `adapter.c:4874-4876` returns when `num_entries == 0` |
| Accepted range 0x0020–0x4000, out-of-range value is dropped with a warning | `src/main.c:570-579`, warnings at `:459`, `:465` |
| provd's advertisement registers with interval 0 (takes default) | `src/advertising.c:988-992`, `:1127-1129` |
| btmon print format used by T1a (`%.3f msec (0x%4.4x)`) | `monitor/packet.c:2279-2280`, `:14337` |
| `read-sysconfig` print format used by T1b (`Type: 0x%04x … Value: %s`) | `client/mgmt.c:1909` |
| New hdev per bind (defaults return after a UART rebind) | `drivers/bluetooth/hci_serdev.c:329` (`hci_alloc_dev_priv`), freed on unregister at `:402` |
| Today's `main.conf` has no `[LE]` section; `PKG_RELEASE:=3` | `firmware-2710/package/batman/batman-ble/files/main.conf`, `Makefile` |
| Before-state on 04: `LE Set Advertising Parameters` with 1280.000 msec (0x0800) | `Desktop/Batman/a4/a4-btmon-04-default.txt:180-182` |
| Harness facts: `lim`/`lim_kill` timing, `no()` prints `FAIL …`, `rebind_once`/`RB_UP`, per-rebind 180 s lease, host limit 600+120 s, dep arms always receive the btmon path, `adv-data` runs inside boot-provd | `scripts/node/ble-lib-254.sh:53-59`, `scripts/node/bt-uart-305.sh:216-248`, `scripts/dv/bt-uart-305.sh:82`, `scripts/node/prov-p2-254.sh:279-400`, `scripts/dv/prov-provd-254.sh:61-68,184,231-239` |
| known-failures classification and NEVER_KNOWN | `scripts/dv/known-failures.sh`, `scripts/validation-known-failures.txt` |

### Inferred (not directly observed)

- Real `bluetoothctl mgmt.read-sysconfig` output on a node. The format is taken from `client/mgmt.c:1909`; the design's T1b parser is consistent with it, but I saw no captured readout from 04 or 02. The offline fixtures must be built from the source format and then confirmed on the first real run (the design's T2 does this).
- The rate of unreadable `read-sysconfig` tries. The design reuses the E39 crash figures for other mgmt commands; no figure exists for this command (finding 5).

### Not checked this round

- §0 phone-side numbers (logcat counts, connection times). Round-3 reviewers recounted them; I did not repeat it.
- `scripts/test-dv-ble-254.sh` was not opened; the claim that `ble-lib-254.sh` can be sourced offline rests on the sibling `scripts/test-dv-bt-uart-305.sh` (`BT305_LIB_ONLY=1`) doing exactly that.

---

## 2. Round-3 MAJOR — closed

r3-A and r3-B both raised: T1b made one try on an image without the key, so a dead readout gave either a false NEW on a healthy old image or a KNOWN that hid the reason.

v4 §8 now: up to 5 tries on **every** image; only a complete readout (both `0x000a` and `0x000b` Value lines) decides; an unreadable try only consumes a try; "no key but value is not 0x0800" has its own line; five unreadable tries give `adv sysconfig unreadable` on both image kinds; offline cases cover each branch. This closes the finding. The fix adds at most 5 × (4 s + 2 s kill) + 4 s sleeps ≈ 35 s per readout, inside the 180 s per-rebind lease (`bt-uart-305.sh:232`) and the 720 s host limit — verified, no new timeout path.

Nothing of MAJOR severity was opened by the fix.

---

## 3. Truth tables

### T1b (per readout after a rebind with `RB_UP=1`, not `--flip`)

| Key in main.conf | Readouts over ≤5 tries | Result line | Classified | Correct? |
|---|---|---|---|---|
| absent | first complete = 0x0800/0x0800 | fixed "old image" FAIL | KNOWN (entry, expiring) | yes — healthy old image |
| absent | first complete = anything else | FAIL "…but main.conf has no key" | NEW | yes — unexplained state |
| absent | unreadable ×k (k<5), then complete | as the two rows above | — | yes — unreadable tries decide nothing |
| absent | unreadable ×5 | FAIL "adv sysconfig unreadable" | NEW (NEVER_KNOWN `unreadable`) | yes by design; see finding 5 for its rate |
| present | complete = 0x00a0/0x00f0 on any try | PASS | — | yes |
| present | complete but wrong (0x0800 or other) on all tries | FAIL "…after 5 tries" | NEW | yes — broken new image is never KNOWN |
| present | wrong, then right within 5 tries | PASS | — | yes — the keys are sent asynchronously after registration (`adapter.c:9383`, no callback), a short lag is legitimate |
| present | unreadable ×5 | FAIL "adv sysconfig unreadable" | NEW | yes |
| present (Min only, Max missing) | 0x00a0 / 0x0800 | FAIL after 5 tries | NEW | yes |
| misspelled key (reads as absent) | 0x0800/0x0800 | old-image FAIL | KNOWN | wrong image state hidden in daily runs — but the design names this and blocks it in T2/T3 (grep precondition; "KNOWN in T3 is a failure"). Accepted. |
| any | rebind left adapter down (`RB_UP≠1`) | no T1b readout; existing baseline FAIL | baseline | not T1b's business |

No cell gives PASS on a broken image, KNOWN on a broken new image, or (deterministically) NEW on a healthy old image.

### T1a (`adv_int_check <btmon> [main.conf]`)

| Key | btmon content | Result | Classified | Correct? |
|---|---|---|---|---|
| any | file missing / empty / no `0x08\|0x0006` block | FAIL (nothing to check) | NEW | yes — a test with nothing to check fails |
| absent | all blocks 1280.000 msec | fixed old-image FAIL | KNOWN | yes |
| absent | any block not 1280 | FAIL, own line | NEW | yes |
| present | all blocks min 100.000 / max 150.000 | PASS | — | yes |
| present | any block differs | FAIL | NEW | yes |

Arms: on a new image every `0x0006` block in these arms comes from provd's single instance with interval 0 → the hdev default; I found no path in the five arms that emits a block with another interval, so no mixed-value false FAIL.

### Result lines vs NEVER_KNOWN

`NEVER_KNOWN='restore|cleanup|CONNECTION-LOST|CONNLOST|reboot did not happen|unreadable|not verified|rc=3 without|NEEDS-PERSON|blocked: DNODE'`

- The two old-image lines (T1a, T1b) contain none of these words, including after the host prefix (`prov-dep-restart-254: dep-power: …` contains "restart", not "restore"). They can be matched by the known-failures entries.
- `adv sysconfig unreadable` matches `unreadable` → never KNOWN. Intended and correct.
- The `DET … unreadable=M` line is not a `FAIL ` line; `kf_classify` ignores it.
- `lim` prints its own `FAIL timeout after 4s: …` on stdout (`ble-lib-254.sh:53-59`). The design captures the try's output and has an offline case "no FAIL line printed by a timed-out try". This must hold in the implementation, otherwise a stray unmatched FAIL makes an old-image run NEW. Covered by the stated test; noted, not a finding.

---

## 4. Rules check

1. **Ownership** — `main.conf` is owned by package batman-ble; hdev interval fields have one runtime writer (bluetoothd via mgmt). debugfs is root-only and not used. No second writer. OK.
2. **Contracts** — key missing/malformed/out of range → kernel default 1.28 s (fail-open to today's behaviour, reason stated: slow connect beats no BLE). OK.
3. **Lifecycle** — rows for first boot, start, clean stop, bluetoothd restart/kill, dbus restart, power off/on, UART rebind, upgrade, rollback/downgrade, crash loop, power loss, both boards are present; each maps to a T1a arm, T1b, or T2/T3. I looked for a missing path and found none.
4. **Evidence** — all load-bearing citations check out except two wrong line numbers (findings 1, 2); the substance of both holds.
5. **Security** — no new input reachable by an unprivileged or remote actor (root-owned file in a read-only squashfs layer; mgmt needs CAP_NET_ADMIN). Faster advertising raises air-time/visibility slightly; the design states it. No secrets. OK.
6. **Tests** — negative control exists (old image FAILs with the fixed line; `--flip`-style check in T2); empty input FAILs; known-failures entries match only the two fixed old-image lines and expire; every FAIL line names its cause.
7. **Necessary changes only** — one config section, one release bump, one check function, one readout loop. Baseline harness behaviour is not altered.
8. **Real use** — the change addresses the measured field symptom (1.28 s interval → slow/failed connects); it does not claim to fix causes other than the interval.

---

## 5. Findings

**MINOR 1 — wrong citation for power-on.** §8 says bluetoothd powers the adapter at `adapter.c:9379`. That line is `fix_storage`. Power-on is `load_drivers` (`adapter.c:9380`) → `plugins/policy.c:834-835` (AutoEnable) → `adapter.c:7841` `set_mode(MGMT_OP_SET_POWERED)`. The conclusion (power is queued before the keys at `:9383`, so a readout may briefly see the old value → retries are needed) still holds. Fix: correct the citation.

**MINOR 2 — wrong citation for the unbind free.** §4 cites `hci_serdev.c:383` for "unbind frees the hdev". Line 383 is the `err_register` error path of registration. The unbind free is `hci_uart_unregister_device`, `hci_serdev.c:395-402` (`hci_free_dev` at `:402`). Fix: correct the citation.

**MINOR 3 — two different key greps in §8.** The intro uses `grep -q '^MinAdvertisementInterval'`, the definition uses `grep -Eq '^[[:space:]]*MinAdvertisementInterval[[:space:]]*='`. Implement one (the second) in one helper used by both T1a and T1b, and make the text agree.

**MINOR 4 — two implementation points to state explicitly.** (a) A try that printed both Value lines counts as complete even if `bluetoothctl` then crashes or is killed by `lim` (the values are real; E39 shows crashes at exit). (b) In `dep-bluetoothd`, `dep-bluetoothd-kill`, `dep-dbus` the `adv_int_check` call must sit inside the existing `if [ -n "${2:-}" ]` block, before `rm -f "$BMF"` (`prov-p2-254.sh:307-317`); in `dep-power` before the `rm` at `:394` and only when the arm is `dep-power`. Both are what the design implies; writing them down removes a way to implement it wrong.

**MINOR 5 — unreadable rate for `read-sysconfig` is unmeasured.** On the old image, five unreadable tries in a row give a NEW failure on a healthy node. With the E39 rates for other commands (≈1/30 – 4/30) this is negligible; if `read-sysconfig` were much worse it would not be. The harness PR should report the `DET … unreadable=M` totals from its real run on both nodes, so the 5-try bound rests on a measured number.

**MINOR 6 — stale comment.** `scripts/dv/prov-provd-254.sh:44` says adv-data is "by hand; in no suite", but line 184 runs it in boot-provd (which is why T1a in adv-data is exercised daily). Fix the comment in the harness PR.

---

## 6. Verdict

**APPROVE.** The round-3 MAJOR is closed, the truth tables show no wrong-verdict cell, and the remaining items are citation and wording fixes plus two notes for the harness PR. No further design round is needed for these.
