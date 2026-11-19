# #329: a node advertises a rotating identifier only its owner's phone recognises (plan v6.1, frozen)

Refs #329 (problem; the node part of this plan is tracked on #329's checklist), #255 B16 (the advertisement owner marker this is a subset of). Base: `main` c03898c. Status: **v6.1, FROZEN after review round 6** (QQ: 0 BLOCKER / 0 MAJOR / 7 MINOR; RR: 0 / 0 / 6; both APPROVE-WITH-CHANGES; the 13 MINORs are applied as text, §13.0). v6 was written after review round 5 (NN: 0 BLOCKER / 1 MAJOR / 6 MINOR; PP: 0 / 1 / 5; both APPROVE-WITH-CHANGES; round 4 was LL, MM; round 3 JJ, KK; round 2 GG, HH; round 1 EE, FF). v6 is a **small revision** of v5: no new mechanism, nothing restructured, nothing both reviewers accepted reopened; each finding is closed by the smallest change of text or parameter, or by deleting what it hit. Every failure still falls back to "no field / no hint = today's shipped behaviour". What changed and every finding's disposition are in §13 (§13.1: v5 → v6; §13.2: v4 → v5; §13.3: v3 → v4). No code. Marks: ✅ verified (source `file:line` or captured output), ⚠️ inferred / secondhand / not measured, ❓ unknown.

The user's choices (2026-11-19): 「節點廣播一個只有擁有者手機認得的輪替識別碼」; Company ID `0xFFFF` during development and a real SIG CID before production, behind one named constant; **the node side changes for this item** — this overrides #329's "node side unchanged" (`329-app-uiux.md:3`, requirement 8) for this item only, and the node part is a checklist item on #329. The plan builds the identifier on a key the owner's phone and the node **already share since the claim**, with **no clock** and **no new key exchange**, and keeps the login's certificate / PSK check as the only identity decision.

**What the user gets, and when.** Nothing changes for the user until the node runs an image with the field (the whole fleet is on wsl.31 today). With the field and an app with the resolver, the ~37 s the F1 login spent waiting and trying another node (§1.1; ~52 s from page open to body in the same log) becomes about 2–8 s from scan start to body, typically ~5 s (⚠️ derived, §1.7), with no attempt on another node first. A recorded advert can be replayed to probe the owner's phone, and a made-up one that does the same can be found by flooding (days of scanning time): see "Known limits" in §4.4.

## 1. Facts

### 1.1 The symptom (reproduced 2026-11-19)

| # | Fact | Evidence |
|---|---|---|
| F1 | On the software-update page the app waited ~37 s inside `loginFor` before the right login (~52 s from the page's round start at 12:26:41.517): `round 24 cancelled` 12:26:56.340; first `connect()` 12:27:26.484 (= 30 s later) to a node that was not the target (`loginFor …58×…7d2c result=undecryptable after 5075ms` 12:27:31.545), then the right one (`…27×…7d2c result=body after 2118ms` 12:27:33.677). ✅ | `scratchpad/ux-sub.logcat` lines 448, 1169, 1756-1757 (EE re-read) |
| F2 | During the 30 s with no connect the scanner saw both current addresses 23 times each, i.e. one advert per ~1.3 s per node. Results are `addressType=1` (random), `eventType=0x1b` (legacy, connectable, scannable: Android scans actively). ✅ | logcat `onScanResult … address=78B52C_7 / 5989DD_8` (awk count 23 / 23) |
| F3 | The scheduler waits for a remembered 「是 Y」 address for `Params.window = 30000` ms before it tries unknown addresses, then tries them in scan order. ✅ | `app/lib/src/nodelink/core.dart:9`, `_candidates` `:437-448` (`:442` early return), `LoginFor.next` `:769-789` |
| F4 | A 「是 Y」 memo is only set after the node's certificate was verified and the login answered; a broken msg2 before signing is `noResponse`. ✅ | `core.dart:36-40`; `329-app-uiux.md:410` |
| F5 | The scan backend passes only the address to the core. ✅ | `app/lib/src/nodelink/ble_backend.dart:22-23` |
| F6 | The vendored scanner carries manufacturer data to Dart: company ID (LE, 2 B) followed by the payload, first company ID only. ✅ | `app/third_party/reactive_ble_mobile/android/.../ManufacturerDataConverter.kt:5-17`; `ProtobufMessageConverter.kt:45` |
| F6b | In a round, `noResponse` on an address that is not this target's 「是 Y」 puts it in `r.exhausted` (no further attempt in the round); in `loginFor` every `noResponse` is retried. The driver forwards only first sightings: `core.onScan` returns true only for an address new to the round, and the `loginFor` `seen` callback skips addresses already seen. ✅ | `core.dart:530-539`, `:352-358`, `:828-833`; `node_link.dart:375-385`, `:799` |

### 1.2 What the node advertises today

| # | Fact | Evidence |
|---|---|---|
| F7 | The advertisement is **one 128-bit Service UUID list (18 B) + Flags (3 B, 0x04, added by BlueZ after the UUID list) = 21 B**; no service data, no manufacturer data, no Local Name, no scan-response data, not discoverable; the same in every node state. ✅ | `bluez.go:268-270`; `254-p2-impl.md:593` (F-P11 correction, 02 btmon `Data length: 21`, `Flags: 0x04` after the UUID list); BlueZ 5.72 `advertising.c:727-742`, `:753-773` (EE) |
| F8 | The serial last-4 (STATUS key 5) is in the GATT `STATUS` characteristic only, for states 0 / 3. ✅ | `provd/server.go:599-615` |
| F9 | **Byte budget: 31 B on air, checked by BlueZ with Flags included** (`calc_max_adv_len` = 31 for a legacy instance, check `advertising.c:780-799`, refusal "Advertising data too long" `:908`, EE); the kernel then skips its own Flags (`eir.c` `skip_flags`, EE). Registered data today 18 B → **10 B left**. provd's own self-check `preflight` (`bluez.go:70-80`) computes `18 + advFlags(3) <= 31`; its comment "the Flags AD the kernel prepends" (`bluez.go:39`) is stale since F-P11. **There is no host test of `preflight`**; the only check is the device unit `prov-provd-wbox-254.sh` (`ADV_LEN_TEST`, `:27`, `:206`). The F-P10 panic ✅ n=1 was a trial with **31 B of instance data and no Flags in it**: the kernel then adds its own Flags past the buffer, which patch 999 (F45) bounds. In this design BlueZ puts Flags **inside** the instance data (F-P11 correction: today's `0x0055` block is 21 B = 18 + 3), so at 31 B the kernel finds Flags, adds none, and the packet on air is the 31 B of the block; patch 999 is only the backstop. ⚠️ reasoned from the two P2 facts: BlueZ / kernel sources are not in this repo and no 31 B capture exists. D1 settles it by also judging the HCI advertising-data block (§8). | `bluez.go:39`, `:70-80`; `254-p2-impl.md:33`, `:593`; #254 comments 6539869418 / 6539887614 |
| F10 | The Pi 4 controller (BCM4345C0) has **no LE extended advertising** → legacy only, ADV and scan response 31 B each. ✅ (2026-11-01 capture) | `254-p2-impl.md:25` (F-P2) |
| F11 | BlueZ 5.72 puts `ServiceUUIDs / ServiceData / ManufacturerData / Data` in the ADV (`client->data`); the scan response carries only the Local Name and is empty without one (`generate_scan_rsp`). `parse_manufacturer_data` expects `a{qv}` with `ay` values; a parse failure fails `RegisterAdvertisement`. ✅ | BlueZ 5.72 `src/advertising.c` (FF, tag 5.72; EE `:340-391`) |
| F12 | Both reachable nodes are Pi 4 (`BCM2711-6c89` = 10.41.19.24, `BCM2711-45d7` = 10.41.85.110), kernel 6.6.138, OpenWrt 1.8.0, `Privacy = device`, no `RPATimeout` and no `KernelExperimental` in `/etc/bluetooth/main.conf`. ✅ | ssh read-only 2026-11-19 05:18Z (§1.6); EE (`batman-ble/files/main.conf`) |

### 1.3 How the RPA rotates, and who can know

| # | Fact | Evidence |
|---|---|---|
| F13 | The kernel regenerates the RPA **only at an advertising enable after `rpa_timeout` (900 s) has expired**; while the RPA is valid it is reused, and while advertising is on the change is deferred. ✅ (EE re-read on 6.6.138) + on hardware: the existing harness assertion "no new random address at the disconnect re-registration (< 900 s)". | `hci_sync.c:1112`, `:1081-1087`; `mgmt.c:1012-1024`; `scripts/dv/prov-provd-254.sh:294-300` |
| F14 | provd re-registers when idle every `900 s + rand(30..120) s` after **its last registration of any reason** (`nextRPA` is re-armed at every `register()`); reasons `start / disconnect / rpa_timeout / health / helper / bluetoothd`. ✅ | `bluez.go:37`, `:607`, `:791-793`; `254-p2-impl.md:227` |
| F15 | The kernel is a **second writer** of the instance: after a connection ends it re-enables the instance itself (`hci_event.c:3421-3424` → `hci_enable_advertising_sync` `hci_sync.c:1851-1935`, which may set a new RPA and **does not re-send the advertising data**), and at power-on it re-enables a surviving instance before provd re-registers. Measured: 1.2 s (bondable withdraw), ~3.1 s (power-on); the "≤ 9.5 s" bound is **reasoned** (L67 / L89), not measured. A power cycle is root-only (power, rfkill, `hciconfig down`). ✅ (P2 btmon; EE source) / ⚠️ (9.5 s) | `254-p2-impl.md:58`, `:602`, `:611-612`, `:648` |
| F16 | provd **cannot read the current RPA** (D-Bus allow-list, `Adapter1.Address` = identity address, debugfs off). ✅ / ⚠️ (debugfs per brief) | `bluez.go:4-5`; `254-stage1-impl.md:60`, `:308` |
| F17 | The actual RPA timeout on the node was not readable; 900 s = kernel default, no override (F12). ⚠️ | F12 |
| F17b | Lockstep below holds only with **no LL privacy** (with it the controller rotates the RPA on its own timer, `hci_sync.c:1105-1108`; enabled only by the mgmt experimental feature, `hci_core.h:1888`, `mgmt.c:4566`; not set, F12) and **no extended advertising** (F10). ✅ (EE, source) | as cited |

Consequence: the identifier cannot be computed **from** the RPA, and provd cannot watch it change. But the RPA changes **only at an enable**, and in the normal path that enable **is** provd's `register()`. A fresh identifier at every `register()` therefore changes with every RPA, except in the kernel-own re-enable paths of F15 (§4.6).

### 1.4 What the owner's phone and the node already share

| # | Fact | Evidence |
|---|---|---|
| F18 | Per-node **`adv_owner_key` (32 B)**: generated at claim, rotated at `owner/remove`, in p5 and every owner app; `adv_owner = HKDF(adv_owner_key, "batman-adv-owner-v1" ‖ device_id)`. ✅ | `219-protocol.md:295`, `:303`, `:210` |
| F19 | Node: `claim` draws it, `claim.replay` returns the stored one, `owner.remove` draws a new one; last owner cannot be removed. ✅ | `node/node.go:589-590`, `:668`, `:937-941`; `provstore/provstore.go:7`, `:54`, `:83-84`, `:176` |
| F20 | Phone: the record carries it as **key 6**, in every record version since the first claim code (bbd74c6, 2026-11-09). ✅ | `bridge/src/api/claim.rs:224-231`; `git show bbd74c6:…/claim.rs:190`; `replay.rs:342` |
| F21 | Both sides implement `adv_owner` against the shared vector file. ✅ | `proto/proto.go:160-162`; `batman-proto/src/kdf.rs:43-46`; `tests/vectors/219-protocol/vectors.json:23,41` |
| F22 | **provd never receives adv keys** (`psks.get` = keys 1/2/3 only, by decision). ✅ | `node/node.go:431-452`; `readonly_test.go:175` |
| F23 | `auth/owner` answers `{}` in stage 1 → added / remaining owners hold no current key. ✅ | `provd/session.go:824-848` |
| F24 | No `owner/add` / `owner/remove` app flow. ✅ | grep, no hit |
| F25 | Team members share nothing node-specific with the node. ✅ | `219-protocol.md:296`, `:304`, `:355` |
| F26 | `NodeLink` serves only owned records. ✅ | `core.dart:29-34` |
| F27 | Records are opened via the platform channel with a Keystore key not bound to user auth; `NodeLink` opens a record per attempt and a Keystore error there goes through `keyCheck` (may set the `keys` overlay). ✅ | `app_link.dart:32-36`; `prober.dart:126`, `:203-219` |
| F27b | The helper socket admits only provd's uid (SO_PEERCRED); a local unprivileged process cannot reach a helper verb. ✅ | `sock/sock.go:1-8`, `:189-203` (EE) |
| F27c | provd has three helper connections: `ctl` (health poll, `ctlMu`, 10 s), `ro` (app-triggered read-only verbs, `roMu`, closed on timeout), `ops`. A `Call` that times out leaves the request in flight, so the next call on that connection gets `ErrBusy` unless the connection is closed. Read-only verbs are answered without `n.mu` and pay a per-connection (5/s) and a helper-wide (10/s) quota. ✅ | `provd/server.go:94-97`, `:172-203`; `provd/helper.go:188-236`; `node/readonly.go:1-21`, `:98-103` |
| F27d | Flutter-Rust-bridge **sync** calls on opaque objects are already used. ✅ | `bridge/src/api/claim.rs:199`, `:253`; `member.rs:136`, `:165` |

### 1.5 Pairing / IRK is forbidden

| # | Fact | Evidence |
|---|---|---|
| F28 | Any pairing peer gets the IRK and identity address → `SecureConnections = only`, no agent, `bondable=0` are preconditions of advertising. ✅ | `254-stage1-impl.md:60`; `254-p2-impl.md:222` |
| F29 | The IRK is per adapter and new each boot. ✅ | `254-stage1-impl.md:126` |

### 1.6 Clocks (read-only, 2026-11-19)

```
2026-11-19T05:18:17Z host
== 10.41.19.24   (BCM2711-6c89)
2025-08-13T15:52:13Z      uptime 1566 s     ls: /dev/rtc*: No such file or directory
== 10.41.85.110  (BCM2711-45d7)
2025-06-24T13:05:23Z      uptime 1288 s     ls: /dev/rtc*: No such file or directory
2026-11-19T05:18:18Z host
```

| # | Fact | Evidence |
|---|---|---|
| F30 | Both node clocks are 15 and 17 months behind and disagree by ~7 weeks; no RTC. ✅ | above |
| F31 | provd's timers use the monotonic reading (`time.Since` / `time.Now().Add`). ✅ | `bluez.go:607`, `:791` |

→ **Any time-based identifier is out.** The scheme uses no clock on either side.

### 1.7 Expected timeline (FF, from the scratchpad logcats; ⚠️ derived, not a run of this design)

Inputs measured over all scratchpad logcats: advert every ~1.3 s; `connected` 216–4226 ms (avg 1943, n = 121); body 1872–6641 ms after attempt start (avg 3586, n = 134); `noResponse` common (95 results; many from disconnect tests). With the field: first advert ≤ 1.3 s → 「像 Y」 → attempt at once → body **~2–8 s after the scan starts, typically ~5 s**. A transient `noResponse` on the first attempt costs one gap (6 s) plus one attempt (R-A5), not the 30 s window.

### 1.8 Facts added for v3 (all read by the author of v3)

| # | Fact | Evidence |
|---|---|---|
| F32 | `register()` is only reached when `HealthOK()` is true. That needs a successful `health.get`, the node certificate (built from helper answers) and `info.state`, all from the helper. Init order: helper `START=89`, provd `START=92`. **So the helper has answered provd before provd's first `register()`.** ✅ | `bluez.go:752`; `provd/server.go:502-534`, `:278-333`, `:375-451`; `batman-provhelper.init`, `batman-provd.init` |
| F33 | The `ro` connection is used only by `roCall`: `status.get`, `settings.get`, `update.status`. It is dialled lazily, and the helper closes a connection idle for 30 s, after which the next call redials (a dial is subject to the helper's accept limits, `AcceptPerSec = 5`, `MaxConns = 4`). No BLE session exists while the advert is on air (it is withdrawn while a link exists), but a `register()` follows a disconnect within tens of ms, so a `roCall` of the session that just ended, or of a Wi-Fi (HTTP) session, can still hold `ro` at that moment. ✅ | `server.go:25`, `:195-204`; `session.go:876`, `:907`; `update.go:55`; `helper.go:131-144`, `:189-236`; `sock/sock.go:28`, `:32`; `bluez.go:307` |
| F34 | Any unpaired central can read the node's state number from the `STATUS` characteristic (plain read). The claim state is therefore **already readable today by connecting**. ✅ | `server.go:599-615`; `bluez.go:236`; `254-p2-impl.md:596` |
| F35 | A read-only verb that needs the record answers `EUnsupported` ("no usable provisioning record") when there is no record or it cannot be read after 4 re-reads (mid-transaction included). `AdvOwnerKey` is in the record only once set (claim). ✅ | `node/readonly.go:81-94`, `:144-147`; `provstore/provstore.go:54`, `:83-84`, `:176` |
| F36 | Read-only quotas: per connection 5/s (burst 20), helper-wide 10/s (burst 40); over → `ERate`. ✅ | `readonly.go:23-26`, `:98-103` |
| F37 | The advert object's properties are exported with `prop.Export` and the returned handle is discarded. No `Emit` is set, so they are `EmitFalse`: godbus sends **no** `PropertiesChanged`; BlueZ reads them only at `RegisterAdvertisement`. `export(c)` runs once per bus connection, from `connect()`. ✅ | `bluez.go:268-274`, `:466`, `:477`; godbus `prop/prop.go:22`, `:293-294`, `:341` |
| F38 | When `RegisterAdvertisement` fails today: one rate-limited line `provd: adv register failed: <err>`, return, `advOn` stays false, `converge` runs again at the next pass of provd's BLE run loop (at most 5 s later, `time.After(5 * time.Second)`; sooner on a signal). `withdraw()` ignores the Unregister result. ✅ | `bluez.go:586-610`, `:612-625`, `:689`, `:743-797` |
| F39 | Phone: 「不是 Y」 is set by `undecryptable` (outside N9, on an address that is not 「是 Y」) and by `certRejected`. It is cleared by: 20 min unseen, pull-to-refresh (`refresh()`), `loginFor(clearNotY)`, a record written or removed. In a round, a `noResponse` on an address that is not this target's 「是 Y」 puts the address in `r.exhausted`. Memo tables have no entry cap (a 64 cap was removed in review). ✅ | `core.dart:504-518`, `:372-378`, `:323`, `:728-738`, `:278-320`, `:530-540`; `329-app-uiux.md:426` |
| F40 | Phone: no scan runs while a kept link is parked or reading; leaving the node page closes the kept link; when a kept link is gone the round continues by a new connect (scan starts). `start()` awaits only `readRecords()` before `core.startup`. ✅ | `node_link.dart:752-764`, `:232`, `:646`, `:212-222` |
| F41 | Existing harness code that depends on the advert content: `scripts/node/prov-p2-254.sh:314` (`Advertising data length: 21` in `adv-data`, which judges the last `MGMT Command (0x0055)` block, `:297-320`). **A provd test switch has five places.** Product side, under `feed/batman-prov/`: `files/batman-provd-test.init:25` (allow-list; unknown keys dropped silently) and `src/cmd/batman-provd/testenv_provtest.go:26-50` (`//go:build prov_test`; reads the environment). Harness side, under `scripts/node/`: `prov-wbox-254.sh:162` (`die "unknown provd switch"`), `prov-p9-254.sh:77` (ERE of the switches in provd's environment), `ble-lib-254.sh:173` (`PROVD_KEYS`). A release build compiles `testenv_release.go` (`//go:build !prov_test`) instead; its `testEnv` returns an empty `provd.TestEnv{}`, so a release binary reads no switch. The comment at `testenv_release.go:7-8` names a `strings` release gate, but **no script in this repo runs one** (grep of `scripts/` and `.github/`: no hit); what exists is the firmware build's `check-prov-test-gate` (F46). ✅ (own read) | as cited |
| F42 | The `rpa` arm of `scripts/dv/prov-provd-254.sh` (`:251-319`) is the unit of suite **`prov-rpa-254`** (`scripts/dv/prov-dv-254.sh:71`: `prov-rpa-254|prov-provd-254|rpa`; a unit ends with `UNIT <name> PASS|FAIL|INVALID`, lines come from `ok` / `no` / `inv`, `prov-254.sh:46-48`). It captures btmon on the node over two `rpa_timeout` registrations, and already FAILs when a random-address set has no provd registration 0..5 s before it (`:298`, `:302-303`). It has early exits (`{ …; pr_result; exit 1; }`) and removes its capture files on the node (`rm -f $PCD/rpa.btmon …`, `:286`) **before** its own checks (`:287-318`), which work on what was already fetched to the host (`:279-284`); `pr_release` is `:319`. The script's common head FAILs an old image with a text that carries the version (`:85`). ✅ | as cited |
| F43 | prov_test binaries reach a node without a reflash: `push-helper` / `push-provd` bind-mount them from tmpfs, `set-provd-env` writes `/tmp/run/batman-prov-test/provd.env`, `unbind-all` restores. All of it is tmpfs: **gone after a reboot**. ✅ | `scripts/node/prov-wbox-254.sh:81-98`, `:124`, `:144-146`, `:154-169`; `scripts/dv/eh12-push-provd-254.sh` |
| F44 | Known failures: one TAB-separated line `suite, ERE, issue, expires=YYYY-MM-DD` in `scripts/validation-known-failures.txt`, checked by `scripts/dv/known-failures.sh`. Precedent c03898c: the entry was removed once the fleet image carried the fix, and `scripts/test-dv-ble-254.sh` asserts it is gone. ✅ | as cited |
| F45 | The kernel patch that fixes the F-P10 panic at 31 B is `target/linux/bcm27xx/patches-6.6/999-batman-eir-adv-flags-oob-254.patch`. It is a kernel-tree patch, not a board patch under `patches/ekh-*/`; the firmware build byte-compares it with the master copy `scripts/dv/data/999-batman-eir-adv-flags-oob-254.patch` (`build-board.sh` step 4). ✅ `~/firmware-2710/scripts/build-board.sh:147-155` (965b17ad): `cmp -s` of both `999-batman-*-254.patch` files against the feed's master copies, `refusing to build` on a difference. ✅ In the tree that built wsl.31 (`build_dir/target-aarch64_cortex-a72_musl/linux-bcm27xx_bcm2711/linux-6.6.138`, read 2026-11-19): `patch -p1 -R --dry-run` of the eir patch succeeds and the forward dry run fails (= applied); `eir.c` 2026-11-03 23:39 < `eir.o` 23:46 < `Image` 23:53. ⚠️ That the wsl.31 image holds this `Image` is inferred (same build tree, kernel not rebuilt); the device check is D1's HCI block | `254-p2-impl.md:33`, `:126`, `:281`, `:403` |

### 1.9 Facts added for v4 (all read by the author of v4)

| # | Fact | Evidence |
|---|---|---|
| F46 | Build evidence for the image **both bench nodes run**: firmware PR #30 (merged) records the build output `patch-witness: all 11 patch(es) of ekh-bcm2711 witnessed in the image` and `check-prov-test-gate: ok (no test seam; helper tags=[]; provd release)` for `1.5.14-wsl.31+5c718d8.fwd4f5dc8.bench`, and "`BATMAN_VERSION=1.5.14-wsl.31+5c718d8.fwd4f5dc8.bench` on both". ✅ (PR body, `gh pr view 30 -R winson3QQ/firmware`). The harness reads a node's version read-only from `BATMAN_VERSION` in `/etc/batman-build` (`pv_ver`, `prov-dv-254.sh:15`; `chk_patches_275`, `daily-validation.sh:908-937`). The 11 witnessed patches are **board** patches (`scripts/patch-witness.sh list <board>`, `build-board.sh:211-212`); patch 999 is a kernel-tree patch and is **not** one of them. Its evidence is F45, not the witness line. | as cited |
| F47 | Existing crash checks in the harness: the boot id (`bid()`, `/proc/sys/kernel/random/boot_id`) and the node's crash record `/opt/batdata/log/boot-reasons.log`. ✅ | `scripts/dv/prov-lib-254.sh:26`; `scripts/dv/prov-254.sh:435`, `:925` |
| F48 | Phone, app in the background: `core.background()` cancels the running round, sets `fg = false` and clears the round schedule; it does **not** clear the 「是 Y」 memos. Rounds need `_eligible` = `started && fg && !lease && page != Page.other`, so no round and no scan runs in the background. `NodeLink.background()` also closes the kept link. `foreground()` begins a round at once; `setPage` cancels the running round, and a node page begins a round at once. The 30 s window counts from the **round's start** (`now - r.start >= p.window`), not from the first scan result. `r.count[a]` is incremented per attempt on an address whatever the target; `_open` refuses an address at `perAddr`. Lifecycle changes arrive as `paused` / `hidden` / `detached` → `background()`, `resumed` → `foreground()`. Logcat: `BMAPP nodelink lifecycle <state>`, `BMAPP nl <t> round N full|early […]`, `BMAPP nl <t> round N cancelled`. ✅ | `core.dart:207`, `:229-250` (`:237`, `:243`), `:252-261`, `:263-267`, `:395`, `:401`, `:428`, `:437-448`, `:452-476`; `node_link.dart:236-240`, `:249-258`; `app_link.dart:122`, `:228-236`; lifecycle samples in `scratchpad/ux-s20-2-main.logcat`, `-5-`, `-6-` (RR) |
| F49 | `logLimit(key, line)` has **one** memory shared by all keys (`lastWhy` = key + line): it does not write a line whose key and text equal those of the previous `logLimit` call; a success does not reset it, a call with another key or text does. `register()` snapshots `c, on := b.conn, b.advOn` in one `b.mu` section. ✅ | `bluez.go:627-635`, `:587-589` |

## 2. Scope (from the field)

Triggers of "the phone does not know which address is its node":
1. The node's RPA rotated since the phone last logged in (every ~15–30 min, F14) — the common case (F1).
2. The node rebooted / bluetoothd restarted (new IRK, F29).
3. Several Batman nodes in range: unknown addresses are tried in scan order (F3) and may be someone else's (F1).

After the change, for a node on an image with the field and a phone holding its record: the phone recognises the node's current address from the first advert it scans and tries it first, with no 30 s wait and no attempt on other nodes first. **Whenever the field or the hint is missing, the behaviour is exactly today's.**

Not handled, stated plainly:
- **Until the node image is updated, nothing improves for the user.** The app change alone does nothing (no field on air).
- **Team members**: no node-specific secret (F25), not served by `NodeLink` (F26). They see an opaque field and behave as today.
- **Additional owners / after `owner/remove`**: no or an old key until `auth/owner` returns it (F23, B16 #255) → fallback. No app flow (F24).
- **Unclaimed nodes**: no key, so **no field** (today's 21 B advert); found by STATUS last-4 as today.
- **A registration at which the helper did not answer** (busy, rate limit, slow, restarting): that advert has no field until the next ordinary registration (at most ~17 min; sooner at any connect / disconnect). No retry timer (§3.2).
- **Replay** of a recorded advert: see "Known limits" in §4.4.
- Phones on app versions without the resolver; app reinstalled (records gone): today's behaviour.
- The 30 s wait itself is not changed (§4.3).
- Other stable identifiers of a node (SSID, HaLow MAC) are unchanged.

## 3. Scheme

### 3.1 Keys and identifier

| Item | Definition | Status |
|---|---|---|
| Base secret | `adv_owner_key` (32 B, per node), shared since claim (F18–F20) | existing |
| Per-node key | `K = adv_owner = HKDF-SHA256(adv_owner_key, "batman-adv-owner-v1" ‖ device_id)`, salt empty, 32 B | existing, shared vector (F21) |
| Nonce | `n` = **3 B** from the helper's CSPRNG, fresh at **every** `adv.id` call | new |
| Tag | `t = HMAC-SHA256(K, "batman-adv-id-v1" ‖ n)[0..3]` (the first **3 B**) | new label, new vector `adv_id` |
| Field | Manufacturer Specific Data AD: `len=0x09, type=0xFF, CID (2 B LE), n (3 B), t (3 B)` = **10 B** | new |
| CID | one named constant per side (`advCID` in Go, `ADV_CID` in `batman-proto`), value `0xFFFF` on dev images; the `adv_id` vector entry carries the CID and both sides' tests assert their constant equals it; switching to the SIG CID before v3.0 PROD is a #329 checklist item | user decision |
| Advertisement | claimed node: UUID list 18 + field 10 + Flags 3 = **31 B on air = BlueZ's limit, 0 B margin** (why R-N2b exists and why D1 is a merge gate); no key / no helper answer: 21 B as today | new |

Why 3 + 3 (v3 had 4 + 2; same 6 B, same 10 B AD, same 31 B): the tag length decides how hard it is to **make up** a payload that the owner's phone takes for its node (§4.4); the nonce length decides only how often a node repeats a payload. With a 2-byte tag a flood of made-up adverts found a hit in about 22 minutes (JJ M1); a byte moved from the nonce to the tag makes that 256 times longer. All figures ⚠️ computed, not measured.
- 24-bit tag, made-up payloads: one advert matches a given owned node with 2⁻²⁴ → 2²⁴ / N ≈ 16.8 M adverts expected for a phone owning N = 1 node; numbers and time in §4.4.
- 24-bit tag, foreign Batman nodes (also CID 0xFFFF in development): 3 own nodes, 30 foreign nodes re-registering ~4 times an hour → one wasted attempt per ≈ 1 940 days ≈ 5.3 years of continuous scanning (v3: ~7.6 days).
- 24-bit nonce: an idle node registers once per 930–1 020 s, about 85–93 times a day, ≈ 31 000–34 000 a year. Expected repeated pairs per node per year ≈ n² / 2²⁵ ≈ **30** (v3: 0.16); a 50 % chance of a first repeat after ≈ 1.18 · 2¹² ≈ 4 800 registrations ≈ 7–8 weeks. **What a repeat gives:** the same `n` gives the same `t`, so the same 6 B appear in two RPA periods, and a passive observer **who recorded both** can link those two periods of that node. Nothing else: no key material, and nothing a single recorded advert does not already give for replay. Accepted as the price of the longer tag.

No version field: a future format uses another label or CID; an old app then resolves nothing and falls back.

### 3.2 Node

- **Helper** (root, owns p5 and `adv_owner_key`): one new **read-only** verb `adv.id` (in `readOnlyVerbs`, answered without `n.mu`). No arguments (`onlyKeys(a)`). It takes the same path as the other record verbs: existing quotas (F36), then `loadOverlayRO`. Answers:
  - record present with a 32-byte `AdvOwnerKey` → `{1: bstr .size 6}` = `n ‖ t`, `t = proto.AdvIDTag(proto.AdvOwner(key, KS.DeviceID()), n)`;
  - no record, record unreadable / mid-transaction, or no 32-byte `AdvOwnerKey` (unclaimed, legacy) → `EUnsupported`, as the other record verbs answer (F35);
  - over quota → `ERate` (existing).

  It never returns `K` or the key. The helper chooses `n`. **No own rate bucket** (deleted in v3).
- **provd**:
  - New method `func (s *Server) AdvID(wait time.Duration) ([]byte, error)`: `roMu.TryLock()` (held → `ErrBusy`, no wait), `s.ro.Call("adv.id", {}, wait)`; on `ErrTimeout` it closes `ro` (as `roCall` does, so no request stays in flight); accepts only `{1: 6 B}`. It never touches `ctl`, so the 4 s health poll is never behind it. `wait = 2 s` bounds the whole call. The call is made synchronously from `register()`, i.e. on the converge goroutine: when the helper stalls, that registration (and so the time off air) is up to 2 s later. Accepted: `staleLinks` just before it can already take seconds, and a stalled helper is withdrawn by the health poll anyway.
  - The advert's `ManufacturerData` property is exported from the start with D-Bus type **`a{qv}`** (godbus `map[uint16]dbus.Variant`, value `dbus.MakeVariant([]byte)` = `ay`), initially the empty dict, `EmitFalse` like the others (F37). The `*prop.Properties` handle is **per bus connection**: `export(c)` stores it in `bleSide` next to `conn` (`bluez.go:477`), and `register()` takes the handle in the **same `b.mu` section** that snapshots `c := b.conn` (`bluez.go:587-589`), so handle and connection always belong together. "No field" = the empty dict (godbus cannot delete an exported property; BlueZ parses an empty dict as no data ⚠️ from source, proven on device in §10 step 3).
  - `register()`, after the `staleLinks` / count check (`bluez.go:593-600`) and before `RegisterAdvertisement` (`:601`):
    1. `ADV_ID_OFF` set (prov_test only) → empty dict, `why=off`. Otherwise call `AdvID(2 s)`: 6 B → set `{advCID: n ‖ t}`; **any** error (`ErrBusy`, `ErrTimeout`, `ERate`, `EUnsupported`, unknown verb on an older helper, connection error, wrong shape) → empty dict, `why=helper`.
    2. `RegisterAdvertisement`. Success → step 4.
    3. It failed. If the dict is empty: today's failure path, unchanged (F38). If the field was set: **whatever the D-Bus error is** — write the existing `adv register failed: <err>` line (through `logLimit` as today, F49: an identical consecutive line is not repeated), set the empty dict, call `RegisterAdvertisement` once more, `why=register`. If this second call also fails: today's failure path (the same rate-limited line, return, `advOn` false, no `adv field` and no `adv registered` line, `converge` tries again at its next pass, ≤ 5 s later (F38), and starts at step 1). No BlueZ error name is matched: a name could only be pinned from a device capture of a refusal that cannot be produced with a release build, and the rule "the node never stays silent because of the field" needs none.
    4. Registered: write `provd: adv field id=1` or `provd: adv field id=0 why=<helper|register|off>`, then the existing, byte-identical `provd: adv registered reason=<why>` line; set `advOn`, `nextRPA`, `advAt` as today.
  - **No retry timer** (deleted in v3). A registration without the field stays so until the next ordinary `register()`: `rpa_timeout` (≤ 1 020 s), or any `disconnect` / `health` / `helper` / `bluetoothd` registration before that. A helper restart itself causes a `reason=helper` registration, so the field is back within seconds of the helper being back. `nextRPA` and the reasons list are untouched.
  - `preflight` counts the field: `advUUIDAD + advMfrAD(10) + advFlags <= advMax` (18 + 10 + 3 = 31). `ADV_LEN_TEST` (prov_test only) keeps replacing the whole registered length, so `ADV_LEN_TEST=29` → 29 + 3 > 31 → exit 3 as today. The `advFlags` comment becomes "the Flags AD BlueZ adds (F-P11)".
  - **One** test switch, prov_test build only, read from `provd.env`: `ADV_ID_OFF=1` (never call `adv.id`; D2's control and the one-off 21 B device check of §10 step 3). It has five places (F41), each assigned to one PR in §10. A release binary cannot read it: `testenv_release.go` (build tag `!prov_test`) reads no environment, and the firmware build's `check-prov-test-gate` refuses an image with a test seam (F46: `ok (no test seam; helper tags=[]; provd release)` for wsl.31; ⚠️ that script was not readable from here). There is no `strings` gate (F41); the stale comment `testenv_release.go:7-8` is corrected in the node PR. (`ADV_ID_REUSE` of v3 is deleted, §13.)

### 3.3 Phone

- **Resolver (Rust)**: opaque `AdvResolver` in `bridge/src/api/owner.rs`, built from a list of opened record plaintexts: per record, key 1 (`device_id`) and key 6 (32 B) → `K_i = batman_proto::kdf::adv_owner(key6, device_id)`; records without key 6 skipped; `K_i` zeroised on drop (as `Creds`, `flow.rs:23-45`). `#[frb(sync)] resolve(mfr: &[u8]) -> Option<String>`: accept only `len == 8` and CID == `ADV_CID`; compute `batman_proto::kdf::adv_id_tag(K_i, n)` for each record, constant-time compare; **exactly one** match → its `device_id`; zero or several matches → `None`.
- **Build** (`app_link.dart`, new `buildResolver()`): opens every record with `openSealedRecord`, **never calls `keyCheck` and never calls `setRadio(keys:)`**; a record that fails to open is left out (that node falls back); if the whole build fails the previous resolver stays in use. Started (not awaited) at the two places `NodeLink` reads the record list: in `start()` after `readRecords()` (`node_link.dart:217-218`) and after each lease release (`:705-715`). Each build takes the next number of a counter; a finished build is installed only if no build with a higher number was already installed, so two overlapping builds end with the newer record list. A removed record is gone from the resolver with the build its removal starts (removal runs under a lease); until then its key may still give a hint, which the core ignores because that `device_id` is no longer a target. **Until the first build finishes the resolver is null and every hint is null (= today's behaviour); the next advert of the node, ~1.3 s later, is resolved with the new resolver** (see "Scan": every result is resolved, so nothing is remembered as "already seen without a hint"). Keys live in Rust memory only. `NodeLink` gets the builder as one more optional constructor argument, like `loginProber` / `keysOk` (`node_link.dart:75-86`; passed at `app_link.dart:149`); the build counter and the install rule are in `NodeLink`, so S9 drives them on the host with a fake builder. The real builder takes its record opener as an argument (as `openNet` wraps `openSealedRecord`, `app_link.dart:32`, `:126`), so "a record whose open throws is left out" is a host test as well; "`keyCheck` is not called" is then true by construction (the opener is the builder's only way to a key). ⚠️ No existing host seam for the Rust constructor call was looked for; if there is none, S9 fakes the builder's last step too. The build time (N Keystore opens) is measured on the S20 in D2 (⚠️ not measured).
- **Scan**: `BleBackend.scan()` becomes `Stream<(String, Uint8List?)>`; `ReactiveBackend` maps `(d.id, d.manufacturerData)` (empty → null). `BleGate` (`ble_gate.dart:12`, `:210`, `:235`) passes the pair through. The driver resolves **every** scan result (a sync µs call, F27d; ~1 result per 1.3 s per node) and passes the result to the core as `hint` (a `device_id` or null). **The driver keeps no table of payloads** and the core never sees the payload bytes.

### 3.4 Implementation decisions (one answer each; §13 maps the reviewers' "implementer must invent" items to these)

| # | Point | Decision |
|---|---|---|
| 1 | Where `adv.id` lives | `readOnlyVerbs` + a case in `readOnly()` **after** the common `loadOverlayRO` step, so quota and record errors are the existing ones (`ERate`, `EUnsupported`); one extra check `len(rec.AdvOwnerKey) == 32` else `EUnsupported`; `onlyKeys(a)`; new `proto.AdvIDTag(k, n []byte) []byte` next to `proto.AdvOwner`. |
| 2 | Connection, timeout | `ro` via `Server.AdvID(2 s)` (`TryLock`, close `ro` on timeout); never `ctl`. |
| 3 | Property handle | per bus connection, assigned in `export(c)`, kept with `conn` and read in the same `b.mu` section as `conn` (`bluez.go:587-589`); `a{qv}` / `ay`; `EmitFalse`; "no field" = empty dict; written only inside `register()`, i.e. while provd's `advOn == false`. |
| 4 | Errors of `adv.id` | every error is treated alike: no field for this registration, `why=helper`, nothing scheduled. No transient / permanent classes. |
| 5 | Errors of `RegisterAdvertisement` | any error with the field set → one field-less attempt in the same `register()`; double failure = today's failure path (§3.2 step 3). |
| 6 | Log | `provd: adv field id=1` / `provd: adv field id=0 why=helper` / `… why=register` / `… why=off`, written only for a registration that succeeded, immediately before the unchanged `adv registered reason=` line. Never the bytes. A reader pairs them as "the **last** `adv field` line since the previous `adv registered` line" (other goroutines may log in between, `bluez.go:307`). |
| 7 | `preflight` with `ADV_LEN_TEST` | `ADV_LEN_TEST` replaces the whole registered length (UUID + field), as it replaces `n` today. |
| 8 | `scan()` type and fakes | `Stream<(String, Uint8List?)>`; the `BleBackend` fakes in `test/nodelink/{ble_gate,connect_fail,kept_link,node_link,prober}_test.dart` and `test/flows/owner_console_test.dart` yield `(a, null)` unless a test sets a payload. `test/nodelink/review_pr1_test.dart` hands `gate.scan` a callback (`:316`, `:461`, `:586`, `:602`) and also has four `Radio` subclasses that override `Stream<String> scan()` (`:83`, `:92`, `:697`, `:716`); they change with the type (10 places in 7 test files in all, RR). |
| 9 | Hint delivery (round) | `core.onScan(now, a, {String? hint})`: `lastSeen[a] = now`; with a round, add `a` to `r.seen` if new; set `r.like[a] = hint` (remove the entry when `hint == null`); return true when `a` is new to the round **or** `r.like[a]` changed. `_startScan`'s callback (`node_link.dart:797-799`) passes the hint and is otherwise unchanged. |
| 10 | Hint delivery (`loginFor`) | `LoginFor.onScan(now, a, {String? hint})` likewise, returning the same boolean. In `node_link.dart:374-392`, `early` becomes a `Map<String, String?>` (address → last hint, insertion order kept) replayed into `l.onScan`; `seen` calls `l.onScan` for **every** result and pokes only on true. |
| 11 | Where 「像 Y」 lives | **per round / per login only**: `r.like` (`Map<addr, id>`) in `_Round`, `like` in `LoginFor`. No memo across rounds, so no expiry, no cap and no clean-up rule: it dies with the round, and is bounded by the addresses scanned in the round like `r.seen`. The next round rebuilds it from the first adverts. |
| 12 | "Tried as 「像 Y」" | `r.likeTried[id]` (`Set<addr>`, per target per round; one set in `LoginFor`). An address counts as 「像 Y」 for target Y when: `like[a] == Y`, `isY[a] == null`, `!isNot(a, Y)`, and (`a ∈ likeTried[Y]` or `likeTried[Y].length < 2`). Otherwise it is an ordinary unknown address. Membership in `likeTried[Y]` is never removed within the round (the slot stays used); `like[a] == Y` is evaluated at each use, so after a hint change the address is an ordinary unknown address. |
| 13 | `_candidates` (round) | Unchanged first: Y's 「是 Y」 address scanned in this round → `[k]` as today. Else `like` = the round's addresses that count as 「像 Y」 (item 12), in the order of today's `order` list (`r.seen` order with the `noRespLast` addresses last, `core.dart:443`), not in `r.exhausted`, `_canTry`. Then `if (!lookOk && isY.containsValue(id)) return like;` else `[...like, ...unknown as today without duplicates]`. `next()` already takes the first candidate that is `_open`, so a 「像 Y」 address inside its 6 s gap does not hold back unknown addresses once the window has passed. |
| 14 | Queue in `next()` (`core.dart:461`) | a pick that counts as 「像 Y」 goes in the **known** queue and is added to `r.likeTried[id]`. Today's split at `:461`, `(_knownAddr(r, id) != null ? known : look)`, asks about the target; it must ask about the **pick** as well: `known` when `_knownAddr(r, id) != null` or the pick counts as 「像 Y」. The address joins `r.likeTried[id]` when the attempt is started, at the same place as `r.tried.add`, not when it becomes a candidate (so the `length < 2` of item 12 is spent only on addresses actually tried). |
| 15 | `result()` (round) | Only `noResponse` changes, and only for an attempt whose address is in `r.likeTried[id]` (by membership, whatever the hint is now). **The cap is checked first**: `r.count[a] >= perAddr` → `r.exhausted.add(a)` (as an unknown address today, so `_conclude` `:691-703` is unchanged); else → `r.retry.add(key)` (as a 「是 Y」 address). `r.count[a]` is shared by all targets (F48), so if another target already spent an attempt on that address there is no retry. A retried address whose hint has changed meanwhile is taken under the unknown-address condition (item 12). `undecryptable` / `certRejected` already set 「不是 Y」 (F39), which item 12 respects; every success branch already sets 「是 Y」. |
| 16 | `LoginFor.next` / `result` | Known address as today. Else the addresses that count as 「像 Y」 with `silent[a] < perAddr`, in the order of `seen` (`LoginFor` has no `noRespLast`), first one that is `_ok` and free. If none can be picked now and (`!isY.containsValue(id)` or the window has passed): unknown addresses as today. `LoginFor.result` is unchanged (it already retries every `noResponse`, `:828-833`). |
| 17 | Rust | `AdvResolver` (opaque) in `bridge/src/api/owner.rs`; `batman_proto::kdf::adv_id_tag`; zeroise on drop. |
| 18 | G2 seam | `register()` uses a concrete `*dbus.Conn`; two seams in `bleSide`: `advID func() ([]byte, error)` (default `srv.AdvID(2 s)`) and `adv advAPI` with `SetMfr(map[uint16]dbus.Variant)`, `Register() error`, `Unregister()` (default: today's D-Bus calls on the current connection's handle). The fake records the value at each `Register` and can refuse. The per-connection handle is behind the seam, so it is tested on a device (§8 D1 `dep-dbus`). |

Stated consequences of items 11–16 (accepted, no extra rule):
- A 「是 Y」 address scanned earlier in the same round is tried first; if the node rotated in the middle of the round, the new 「像 Y」 address is tried after the old address stayed silent twice (≤ 2 attempts + one 6 s gap). Rare: needs a rotation inside one round.
- For another target Z, a 「像 Y」 address is an ordinary unknown address, and the 2-per-address limit of a round is shared (`_open`). In a round with several targets, Z may use one of the two attempts on Y's address; Y then ends the round as 還沒輪到 and is tried in the next round, as today. (Stated only: no test drives this case.)
- Beyond 2 addresses per target, further 「像 Y」 addresses are ordinary unknown addresses (the 30 s wait if Y has a 「是 Y」 memo). See §4.4.

## 4. Rules

### 4.1 Node rules

| # | Rule |
|---|---|
| R-N1 | Every `register()` asks the helper for a **new** `n ‖ t`. provd never stores or reuses a previous payload. |
| R-N2 | No fresh payload → register **without** the field (today's advert). Nothing is scheduled; the next ordinary `register()` asks again. Fail-open: the field is only a hint, its absence is today's privacy and behaviour; reusing an old payload would link two RPAs. |
| R-N2b | `RegisterAdvertisement` fails (any error) while the field is set → in the same `register()`, one more attempt without it. If that fails too, today's failure path. The node never stays silent because of the field. |
| R-N3 | provd writes the property only inside `register()`, when **its** `advOn == false`. `withdraw()` ignores the Unregister result (`bluez.go:612-625`), so this is provd's belief, not BlueZ's state; the property emits no change signal (F37), so BlueZ sees a new value only at the next `RegisterAdvertisement`. |
| R-N4 | The helper returns a tag only for a record with a 32-byte `AdvOwnerKey`; otherwise an error. It never exports `adv_owner_key` or `K` (keeps F22). |
| R-N5 | The ADV stays ≤ 31 B with Flags; `preflight` refuses more (exit 3). |

### 4.2 Phone rules (changes to `core.dart` §4.3.3-5 / -6 and `LoginFor`)

| # | Rule |
|---|---|
| R-A1 | **「像 Y」** is per-round (per-login) state: the last hint the scan gave for an address in this round. A later result for the same address replaces it (another id) or removes it (null). |
| R-A1b | **Precedence: 「是」 (any record) > 「不是 Y」 > 「像 Y」.** An address with any `isY`, or with `Y ∈ notY[a]`, never counts as 「像 Y」. Several own records matching one payload → no hint (R1). |
| R-A2 | A 「像 Y」 address is **never** a 「是 Y」: only a verified login sets 「是 Y」 (F4 unchanged). |
| R-A3 | Candidates for Y, in order: (1) Y's 「是 Y」 address if scanned (unchanged); (2) else Y's 「像 Y」 addresses, in the order of §3.4-13 / -16 — **at once, without the `window` wait**; (3) unknown addresses under today's condition (after `window` if Y has a 「是 Y」 memo, else at once). Same in `LoginFor.next`. |
| R-A4 | **Cap: per target, per round (per login), at most 2 addresses are tried as 「像 Y」.** Why 2: with 1, a single replayed address would take the only fast slot in every round; 2 leaves room for the real node next to one stale or replayed address, and bounds the probes of §4.4 to 2 per target per round. More would only widen that. |
| R-A5 | Outcome of an attempt on a 「像 Y」 address: `body` / `errorCode` / `refused*` / `broken` → as today (sets 「是 Y」); `undecryptable` (outside N9) or `certRejected` → 「不是 Y」 as today, so the address is not tried as 「像 Y」 again while that memo lives (F39); **`noResponse` → retried once like a 「是 Y」 address** if the address still has an attempt left in the round (the 2-per-address limit is shared by all targets), otherwise it goes in `r.exhausted` (§3.4-15). All existing limits (2 per address, 6 s gap, 90 s cap, 60 s login budget) apply. |
| R-A6 | No payload, unknown CID, wrong length, no resolver yet, several matches → `hint = null` → the same attempts in the same order as today. One difference remains without a hint: during `loginFor` every scan result now reaches `l.onScan` (§3.4-10), so `lastSeen` is refreshed on repeats, where today only the first sighting does it (`node_link.dart:381-382`); a memo of a still-visible address lives longer, nothing else. `Params.window` stays 30 s; it now only guards the fallback. |

No separate "refuted" memory: the existing 「不是 Y」 memo is the memory of a failed 「像 Y」 attempt. It is cleared by the existing events only (F39); after such a clear (for example pull-to-refresh) a still-present replayed address can cost one more attempt.

### 4.3 Is the 30 s wait still needed?

Not for a node that sends the field to a phone holding its record (R-A3). It applies only to the fallback (old node image, unclaimed node, key missing, Keystore failure, helper did not answer, more than 2 「像 Y」 addresses). Shortening it is **not** part of this change: §4.3.3 of `329-app-uiux.md` is frozen with simulation tests that encode 30 s. Not scheduled.

### 4.4 Privacy and security

**What a resolved identifier proves: nothing.** It only orders attempts. Identity is still decided only by the login (Noise `NXpsk0` with `psk_owner`, DAC / node-cert check, `219-protocol.md:39`, `:72-74`).

| Actor | Attack | Result |
|---|---|---|
| Radio observer | Track a node across RPAs | PRF output under a per-node 256-bit key with a fresh 24-bit nonce per registration → unlinkable without `K`, except when a nonce repeats: the payload is then identical, and an observer who recorded both can link those two RPA periods. Static parts (UUID list, CID) say "a Batman node", as today. Residuals: nonce repeats (≈ 30 pairs / node / year, first one after 7–8 weeks at even odds, §3.1; ⚠️ computed); kernel-own re-enable (§4.6). |
| Radio observer | Tell claimed from unclaimed nodes; see a claim happen | **New, accepted**: a claimed node sends 31 B with the field, an unclaimed one 21 B, so the claim state is visible **passively**. Today it is visible only by connecting and reading STATUS (F34), which any unpaired central can do. Also visible: a registration where the helper did not answer (21 B for one period). |
| Radio attacker with a recorded advert | **Test whether a nearby phone owns node Y; link two sightings** | **New, not closed** — see "Known limits" below. |
| Radio attacker | Replay an observed advert to delay the owner | The replayed address is 「像 Y」 and tried first; the login fails → 「不是 Y」, or it stays silent → 2 attempts and out for the round. At most 2 such addresses per round (R-A4); the real node, if scanned after them, is then an ordinary unknown address = today's wait. A replayer that keeps transmitting from fresh addresses can deny the speed-up for as long as it transmits; it cannot do worse than today plus ≤ 4 wasted attempts per round. An address whose adverts alternate between a replayed payload and none changes its hint at every result, so the driver re-plans per advert (§3.4-9): a small cost, comparable to today's flood of fresh addresses, and the cap still bounds the connects. A radio attacker can jam anyway. |
| Radio attacker | Relay a 「像 Y」 address to the real Y | Passes the login, so 「是 Y」 lands on the relay's address; the same happens today after 30 s, the hint only makes it immediate. Identity stays correct. Honest bound. |
| Radio attacker | Forge a payload without the key and **without ever having been near the node**: flood made-up adverts until one matches | **New, not closed** (JJ M1). One made-up advert matches a given owned node with 2⁻²⁴, so the expected number of adverts until a hit is 2²⁴ / N: ≈ 16.8 M for a phone owning N = 1 node, ≈ 5.6 M for N = 3. At 50 different adverts per second reaching the phone's resolver that is ≈ 93 h ≈ 3.9 days of scanning time (N = 1), ≈ 31 h (N = 3); v3's 2-byte tag gave ≈ 22 min. ⚠️ computed, not measured — the rate at which an Android scan delivers results was not measured; one address is enough, since each result is resolved. The time counts only while the phone scans (app in the foreground on a page that looks for nodes). A hit shows as an at-once connect, and the attacker can confirm it by sending the same payload again. **A hit is a non-expiring token for that phone**: it serves exactly like a recorded advert ("Known limits"). The cap of 2 (R-A4) counts only addresses whose payload matched, so it does **not** limit the flood. No mechanism is added. |
| Radio attacker / Wi-Fi peer | Make a registration go out without the field (keep `ro` busy or drain the read quota at that moment) | That advert is today's advert until the next registration. Loss of the speed-up only, never loss of advertising. ⚠️ Whether an unauthenticated peer can trigger the three `ro` reads (F33) was not traced; the consequence is the same either way. |
| Other app on the phone | Read the field | Sees the same bytes; without `K` learns nothing. Records sealed (F27). |
| Local unprivileged process on the node | Call `adv.id` | Cannot reach the helper socket (F27b). |
| Compromised provd (uid 471, jail) | Get the key / choose nonces | Gets only helper-chosen `n ‖ t` for its own node at the existing read quota (5/s); `K` stays in the helper (R-N4). At that quota it can collect ≈ 432 000 valid payloads a day (about one in 39 of all nonces); each is a non-expiring replay token for **its own node** until that node is re-keyed ("Known limits"). It controls this node's advert anyway (could omit or repeat the field, or hand out what it advertises). |
| Node captured / SD card read | `adv_owner_key` from p5 (rootfs not encrypted) | **Passive, undetectable** recognition of **that** node's adverts for as long as the key lives: for a single-owner node until reflash (the last owner cannot be removed, `node.go:937-939`; no re-key verb). Per node, HKDF'd with `device_id` → nothing about other nodes. Honest bound: reflash after a suspected capture, as for every secret on the card. |
| Phone captured / lost | Records give `K` of every owned node | Same passive recognition of those nodes, if the Keystore yields (records not bound to user auth, F27). Mitigation as for `psk_owner`: reflash. Honest bound. |
| Former owner after reflash / re-claim | Keep recognising | New claim draws a new key (`node.go:589-590`) → old record never resolves. ✅ by construction. |
| Removed co-owner | Keep recognising | `owner.remove` rotates the key (`node.go:941`). The payload computed under the old key stays on air until the node's next registration (≤ ~1 020 s, §4.5); after that the removed owner resolves nothing. Remaining owners fall back until `auth/owner` returns the new key (F23). |
| Removed team member | — | Never had the key (F25). |
| Our own mistakes | Reusing a payload; logging `K` / bytes | R-N1 (G2 (a) mutant; D1 distinct-payload check with its two negative controls, §8); the log carries only `id=` and `why=` (§3.4-6; the lines G2 asserts). |

**Known limits (for the user; a property of the chosen approach, not closed by this design).**
- A payload `n ‖ t` **never expires**: the scheme has no clock (F30) and no counter. Anyone who once recorded an advert of node Y can replay it later, anywhere, from their own address.
- The owner's phone, **while the app is in the foreground on a page that looks for Y**, connects to that address **at once**; a phone that does not own Y treats it as an unknown address (after 30 s, or in scan order). The replayer is the peripheral and sees who connects and how fast.
- So the replayer can (1) test "does this phone own node Y", (2) learn that two recordings belong to the same node (both get the fast connect from the same phone), (3) on the node page, learn which node the user is looking at.
- **Today's image has no such leak**: with no identifier on air, every unknown address is treated alike.
- What limits it: the phone only scans while such a page is open; at most 2 「像 Y」 addresses per target per round (R-A4); after a failed login the address is 「不是 Y」. **These limit the repetition of a replay, not the single probe.**
- **A valid payload can also be found without a recording**, by flooding made-up adverts (the "Forge" row): expected 2²⁴ / N adverts, i.e. days of the phone's scanning time at 50 adverts per second (⚠️ computed). The cap of 2 does not count adverts that do not match, so nothing here limits the flood except the tag length and the time the phone spends scanning. The found payload does not expire for that phone.
- Closing it needs freshness (a clock or a counter both sides keep: A4 / A5 were ruled out by the missing RTC and by node state), i.e. a different approach. That is a product decision for the user, not a detail of this plan.

**Attack-surface delta.** Node: one helper verb (no input, existing quotas, read-only on p5); one more D-Bus property on provd's own object, read by BlueZ as it reads `ServiceUUIDs`; no new BlueZ method, no dbus-policy change ⚠️ (inferred: the reverse-direction property read already works for `ServiceUUIDs`; D1 proves it). Phone: parses ≤ 8 untrusted bytes per scan result (length-checked) into a hash compare. **Privilege**: the HMAC runs in the root helper, which already holds the key; provd stays without keys. **Secrets**: `adv_owner_key` stays in p5 and in the sealed record; `K` only in helper memory and in the app's Rust memory (zeroised); never in a log, a URL or a world-readable file. **Fail mode**: fail-open for the hint (absence = today), never fail-closed for reachability (R-N2b). **Negative tests**: S2 (a hint never becomes 「是 Y」), S3 (cap), G1 (no tag without a key), R1 / R2 (wrong key resolves nothing); a local process with another uid is refused at the helper socket by the existing `TestWrongPeerClosed` (`sock/sock_test.go:67`), which covers `adv.id` like every verb.

### 4.5 Key lifecycle

| Event | Node | Owner phone | Field |
|---|---|---|---|
| Claim | new `adv_owner_key` in p5 | key 6 in record; lease release → resolver rebuilt | present from the next registration (the post-claim disconnect), resolves |
| Claim response lost → `claim/replay` | same key (`node.go:668`) | record rewritten (`replay.rs:342`) | resolves |
| `owner/remove` (no app flow) | new key | others: old key until `auth/owner` (F23) | others fall back |
| Reflash / resale | unclaimed, no field | old record never resolves | none until the next claim |
| Phone record deleted / Keystore wiped / app reinstalled / restored from a backup without the Keystore key | — | no resolver entry | fallback |
| Records written by an older app version | — | key 6 present since bbd74c6 (F20) | resolves |

A key change (`owner.remove`, a record restored on the node) does **not** itself trigger a registration: the payload under the old key stays on air until the next ordinary registration (≤ ~1 020 s), and during that time no phone with the new key gets a hint from it (fallback). Accepted, no trigger added (JJ m7): one period, and only the speed-up is lost.

### 4.6 Lockstep with the RPA (and where it is not)

Requirement: **the field must change at every RPA change**. Extra changes within one RPA are harmless (they only link payloads already linked by the same address).
- Normal path: provd re-registers at 930–1020 s after its last registration (F14); if the RPA expired the kernel enables with a new RPA (F13), and the field is new (R-N1). ✅ by construction; proven on a device by D1.
- `disconnect` / `start` / `health` / `helper` re-registration: new field, on the same RPA or on a new one if the RPA had expired — harmless either way.
- **Kernel-own re-enable with an old payload** (F15):
  - (a) A connection that ends before provd's `Unregister` reaches the kernel (D-Bus signal → converge → Unregister, tens of ms), while the RPA has expired. Because `nextRPA` is re-armed at every registration, the RPA can sit expired but not yet replaced for up to ~1 020 s after a `disconnect` / `health` registration. Any central can cause it actively (connect, drop at once); an LE encryption failure also forces RPA expiry (`hci_event.c:3573-3577`; ⚠️ controller-dependent, not probed). It adds little: an **active** attacker already links an RPA change by timing (P2 bound `254-p2-impl.md:95`). A **passive** leak needs a legitimate connection shorter than provd's withdraw latency, which is rare.
  - (b) A power cycle shorter than provd's 4 s poll (L89): root-only (not remotely reachable, `254-p2-impl.md:611`). The old field goes out with the new RPA until provd re-registers: measured 1.2 s / ~3.1 s, reasoned bound ≤ 9.5 s ⚠️ → about 1–7 adverts.
  - Not fixed: closing it needs provd to see the RPA (F16). Changing how `nextRPA` is re-armed would touch P2's tested timer contract (`prov-provd-254.sh:287-293`); not done.
- Holds only without LL privacy and without extended advertising (F17b; §7). D1 in daily validation catches a regression on any image or board.

## 5. Interfaces

**Ownership** (one writer each)

| Resource | Writer | Readers |
|---|---|---|
| `adv_owner_key` (p5 key 7) | helper (claim / owner.remove), as today | helper only (`adv.id`) |
| `n` (nonce) | helper `adv.id` | provd (to advertise) |
| helper `ro` connection's in-flight slot | provd, serialised by `roMu` (sessions' read-only verbs and `AdvID`); `AdvID` never waits for it (`TryLock`) and closes it on timeout | helper |
| `ManufacturerData` property of `/org/batman/provd/adv0` and its handle | provd `register()` only (handle replaced by `export(c)` per bus connection), only while its `advOn == false` | BlueZ (at register) |
| Advertising instance in the kernel | provd via BlueZ; **kernel is a second writer** (re-enable, F15, existing) | air |
| Record key 6 | claim / replay persist (existing `RecordWriter` path) | `buildResolver` (read) |
| Resolver keys `K_i` | `NodeLink` (Rust memory), rebuilt at record re-read | `NodeLink` driver |
| 「像 Y」 (`r.like`, `r.likeTried`; `LoginFor` likewise) | `NodeLink` core, per round / login | `NodeLink` core |

No new timer, no new persistent state, no new file on either side.

**Contracts**

| Interface | Writer → reader | Valid / format | Missing / stale / malformed | Who can write |
|---|---|---|---|---|
| Advert field | provd → phone scan | AD 0xFF, CID, 6 B `n ‖ t` | absent / other CID / length ≠ 8 / several matches → no hint (fail-open: today's behaviour); stale (kernel re-enable) → resolves to the right node, privacy bound §4.6; replayed → §4.4 | **anyone in radio range** → hint only (R-A2) |
| `ManufacturerData` D-Bus property | provd → BlueZ | `a{qv}`, value `ay` (6 B); empty dict = no field; no change signal | BlueZ refuses the registration → R-N2b | provd |
| `adv.id` verb | provd → helper | req `{}`; resp `{1: bstr .size 6}` | `EUnsupported` (no record / no key / unreadable), `ERate`, `ErrBusy`, > 2 s, unknown verb, wrong shape → advert without the field for this registration (fail-open: today's advert) | provd only (socket peer-cred, F27b) |
| `K` derivation | both sides | 219 §6 `adv_owner`, existing vector | record without key 6 → skipped | — |
| Tag | both sides | `HMAC-SHA256(K, "batman-adv-id-v1" ‖ n)[0..3]`, `n` 3 B; vector `adv_id` (with CID) | — | — |
| Log `provd: adv field id=1` / `id=0 why=helper` / `why=register` / `why=off` | provd → harness | its own line, only for a successful registration, before `provd: adv registered reason=<why>` (that line and its reasons unchanged) | the reader takes the last `adv field` line since the previous `adv registered` line; none → an image without the feature (judged as such, §8 D1) | provd |
| Scan hint | driver → core | `hint` = the `device_id` of a record the current resolver was built from, or null, with every scan result | null, or an id that is not a target of the round → today's behaviour | driver (from the resolver) |
| Test switch `ADV_ID_OFF` | harness → prov_test provd via `provd.env` | `=1`; prov_test build only | missing from one of its five places → dropped or refused (F41); a release binary reads no environment (`testenv_release.go`, build tag) and the firmware build's `check-prov-test-gate` refuses a test seam (F46) | root on the node (existing wbox path) |

## 6. Lifecycle matrix

| Path | Today | After | Test |
|---|---|---|---|
| Install / first run (unclaimed) | UUID-only advert, 21 B | the same: `adv.id` → `EUnsupported` → no field, `id=0 why=helper` | G1 (error), G2 b |
| Claim | phone finds node by memo / 30 s | next registration carries the field; lease release rebuilds the resolver | S9, D2 |
| Start (provd) | register `start` | + field (helper already answered, F32) | G2, D1 |
| Clean stop | withdraw | same | — (unchanged) |
| Restart provd / bluetoothd | re-register | re-register with a new field | D1 (`dep-*` arms) |
| Restart of the bus (new D-Bus connection) | re-export, re-register | + new property handle from `export(c)` | D1 `dep-dbus` arm (31 B and `id=1` must agree) |
| Restart of the helper; helper down, slow or busy at a registration | health withdraw; `reason=helper` registration when back | registration without the field if `adv.id` fails (`why=helper`), field back at the `reason=helper` or next registration; a helper restart during `AdvID` = one such failure; a stalled helper delays that registration by ≤ 2 s (§3.2) | G2 b, G5 (host only: the `dep-helper` arm has no btmon, `prov-p2-254.sh:242-259`, and gets no new check) |
| `ro` busy at that moment (a `roCall` of a Wi-Fi session, or of the BLE session that just ended, F33); `ro` idle-closed after 30 s | — | busy: `TryLock` fails → no field for this registration (`why=helper`). Idle-closed: `AdvID` redials; a redial refused by the helper's accept limits → no field. Rare, and only the hint is lost | G5 |
| BlueZ refuses a registration with the field | — | registered without it in the same `register()`; both fail → today's failure path | G2 c, c2 |
| provd crash / crash loop | respawn, re-register | each start one `adv.id` (well under 5/s); `ERate` would mean no field, nothing else | G2 b (any error) |
| Node reboot / power loss | new IRK, new RPA | new RPA + new field at `register(start)` | node side: G2, D1 (`start` registration). Phone side: same core path as a rotation (S1, D2). ❌ no separate end-to-end reboot run (§8) |
| RPA rotation | new RPA at `rpa_timeout` | new RPA **and** new field | D1 |
| Connect / disconnect | withdraw / re-register | new field | D1 (its one connection) |
| Network loss | — | n/a: nothing here uses the network | — |
| Clock jump (GPS / NTP) | timers monotonic | no clock used, no new timer | n/a |
| Upgrade node image | — | field appears; an old app ignores it (it maps only the address, `ble_backend.dart:22-23`) | D3 |
| Rollback / downgrade to an image without the field | — | no field, no `adv field` line → app fallback; harness judges it as an old image (§10) | D2 off arm (the same air); `adv-data` on wsl.31 |
| Old node + new app | — | hint always null → today | S4; D2 off arm |
| New node + old app | — | ignores manufacturer data | D3 |
| provd and helper of different versions (only via `push-provd` / `push-helper`; an image upgrade replaces both) | — | old helper: unknown verb → no field; old provd: never asks | G2 b |
| Upgrade app (records from older app versions) | — | key 6 present since bbd74c6 → resolves | R1 (fixture of the bbd74c6 shape) |
| App reinstall | records gone | no resolver entry → fallback | — (no record = no `NodeLink` target) |
| App cold start | records read, round starts | resolver built in the background; adverts before it is ready give no hint, the next one does | S7 |
| Keystore failure while building the resolver; phone restored from a backup (key not restorable ⚠️ not checked) | — | record left out, no `keys` overlay, previous resolver kept | S9 |
| Kept link parked (no scan), then gone after the RPA rotated | round reconnects after the 30 s wait | scan starts, first advert gives the hint | S1 (same core path), S7 |
| Bluetooth off / on on the phone | overlay reason | resolver unchanged; 「像 Y」 is per round | existing T-L |
| `owner/remove` | key rotated | others fall back | G4 |
| Reflash / re-claim | — | old record no longer resolves | R2 |
| Supported boards | Pi 4 (BCM4345C0, legacy adv) | same | D1 on 04 (merge gate, §10 step 3) and with the image (§10 step 7; 02 there ⚠️). Pi 3 not supported (user decision 2026-10-23). **CM4 (production): ❓ controller not checked** → #329 checklist item: before v3.0 run D1 and `bluetoothctl show` on a CM4 |

## 7. Evidence for assumptions

| Assumption | Evidence | Mark |
|---|---|---|
| RPA changes only at an enable after expiry | `hci_sync.c:1112`, `:1081-1087`, `mgmt.c:1012-1024` (EE, 6.6.138); harness `prov-provd-254.sh:294-303` on hardware | ✅ |
| No LL privacy on the node | `hci_core.h:1888`, `mgmt.c:4566`; no `KernelExperimental` in main.conf (EE) | ✅ (current image); D1 catches a change |
| No extended advertising on the Pi 4 | F10 | ✅ Pi 4; ❓ CM4 |
| BlueZ puts `ManufacturerData` in the ADV, `a{qv}`/`ay`, refuses on parse / length failure | F11 (BlueZ 5.72 source, FF + EE) | ✅ source; D1 confirms on air |
| BlueZ treats an empty `ManufacturerData` dict as no data | FF (source) | ⚠️ → §10 step 3 (`ADV_ID_OFF`: registered, 21 B) before anything merges |
| BlueZ reads the property only at registration; provd emits no change signal | F37 | ✅ source |
| The helper has answered before the first `register()` | F32 | ✅ source |
| Every `RegisterAdvertisement` produces one `MGMT 0x0055` block with the registered data (what `adv-data` judges today) | `prov-p2-254.sh:297-320` on hardware | ✅ for 21 B; ⚠️ btmon's text for a Manufacturer AD inside that block not captured yet |
| Android delivers the manufacturer data with a UUID-filtered result | both ADs in the same ADV PDU; converter F6 | ⚠️ → D2 on the S20 |
| 31 B with Flags is accepted and does not panic the kernel; the Flags on air are the ones BlueZ put in the instance data | F9 (BlueZ check, EE; F-P10 / F-P11 reconciled by reasoning), F45 (patch as backstop) | ⚠️ source + reasoning, 0 B margin → D1 merge gate judges the HCI block and the crash record; R-N2b covers a refusal |
| Kernel re-enable windows are short | F15 measured 1.2 / ~3.1 s; 9.5 s reasoned | ⚠️ |
| `adv.id` answers within 2 s while `net.apply` holds `n.mu` | read-only verbs skip `n.mu` (`readonly.go:3-4`) | ✅ for read-only verbs; G1 stall arm for `adv.id` |
| Records of every app version carry key 6 | F20 | ✅ |

## 8. Tests

Every test goes into the regular suites (Go / Rust / Dart unit suites in CI; device rows in daily validation per #290, harness PR first, §10). Each has a negative control: the change without which it must fail.

**Host tests**

| # | Test | Asserts | Negative control (must FAIL) |
|---|---|---|---|
| V1 | Shared vector `adv_id` (with the CID) in `tests/vectors/219-protocol/vectors.json` (`gen.py` / `verify.py`); Go `proto` test and Rust `vectors.rs` read it | both sides compute the same `t` from `K`, `n`; both CID constants equal the vector's | change the label; truncate the tag to 2 B; use a 4 B nonce; change one side's CID |
| G1 | Helper `adv.id` | claimed record → 6 B and the tag verifies under `AdvOwner(key, device_id)`; no record / record without a 32-byte key / unreadable record → `EUnsupported`; 1 000 calls (the test clock advances 1 s per call: the existing read-only quota covers `adv.id`) → every tag verifies and ≥ 990 distinct nonces (correction at implementation: with a 3-byte nonce, 1 000 draws repeat at least once with probability ≈ 3 %, so "1 000 distinct" would be a flaky bar); 60 calls in one instant → some but not all `ERate`; answered in < 100 ms while `n.mu` is held | constant nonce; random bytes instead of the error; verb not in `readOnlyVerbs` (stall arm fails) |
| G2 | provd `register()` through the two seams (§3.4-18) | (a) two registrations → `advID` called twice, two different values at `Register`; (b) `advID` returns an error → registered with the empty dict, `adv field id=0 why=helper`, **nothing further scheduled**, `nextRPA` as today; (c) on a fresh `bleSide`, the fake refuses the registration with the field → the same `register()` ends registered with the empty dict, `why=register`, the `adv register failed` line written once; (c2) fake refuses everything with the same error → not registered, `advOn` false, **no** `adv field` and no `adv registered` line, and the failure line appears once (the identical second one is held back by `logLimit`, F49: asserted as such — it holds because no other `logLimit` call lies between the two failures inside one `register()`); the next `converge` pass calls `advID` again and registers when accepted; (d) the property is never written while `advOn` is true; (f) `ADV_ID_OFF` → `advID` never called, `why=off` | (a) cache the payload; (b) return from `register()` on a helper error (nothing registered); (c) no second attempt; (c2) log the `adv field` line before the outcome is known; (d) write in `converge`; (f) switch ignored |
| G3 | `preflight` | UUID list + field + Flags = 31 → 0; `ADV_LEN_TEST=29` → 3 | `advMfrAD = 11` → the default must exit 3 |
| G4 | `owner.remove` | after it, the tag verifies under the new key and not under the old | key not rotated |
| G5 | `Server.AdvID` with `fakeHelper` (`provd/rig_test.go:31`) | `adv.id` stalls 5 s → `ErrTimeout` within 2.1 s, `ro` closed, the next health poll on `ctl` succeeds, a later `status.get` reconnects; `roMu` held → `ErrBusy` at once | make the same call on `ctl` → the poll gets `ErrBusy` |
| R1 | Rust resolver | own payload → that `device_id`; payload under another key → none; wrong CID, length 7 / 9 → none; a record without key 6 is skipped; two own records matching one payload → none; a fixture of the bbd74c6 record shape resolves | ignore the CID; return the first match |
| R2 | Rust resolver after a re-claim | a record with the old key does not resolve a payload under the new key | resolver keyed by `device_id` only |
| S1 | Core simulation, round: Y has a 「是 Y」 memo on old address A (not scanned); B (hint Y) and C (no hint) scanned, C first | the first attempt goes to B less than 1 s after the scan result; no attempt on C before B's result | drop R-A3 step 2 → first attempt at 30 s, on C |
| S1L | The same in `LoginFor` | the first attempt goes to B at once | as S1. On a device: D2's `loginFor` pair (§8; ⚠️ needs a dev build) |
| S2 | Replay: C carries a hint for Y, the fake answers `undecryptable`; B is the real node | C tried first; C → 「不是 Y」, **no 「是 Y」 on C**; B then tried → body; 「是 Y」 on B | set 「是 Y」 from the hint → the test sees 「是 Y」 on C |
| S3 | Cap (the characterisation test of §4.4): three addresses with hint Y, all silent or refuting | exactly 2 are tried as 「像 Y」 (at once); the third is treated as an unknown address (waits for the window while Y has a memo); attempts on 「像 Y」 addresses ≤ 4 in the round | remove the cap → the third is tried before the window |
| S4 | Every existing core simulation with `hint = null` everywhere | traces identical to today's | treat a null hint as 「像」 of the page's target |
| S5 | `noResponse` on a 「像 Y」 address | round: second attempt after the 6 s gap; second silence → `r.exhausted`, Y concluded as today; `LoginFor`: after 2 silences the address is no longer preferred | today's handling (exhausted at the first silence) → no second attempt |
| S6 | Precedence | an address that is 「是 Z」, or has `Y ∈ notY`, and gets a hint for Y → not a 「像 Y」 candidate | let the hint override the memo |
| S7 | Hint delivery (`node_link` test with the fake backend) | every scan result is forwarded with its hint; B first scanned with a null hint (resolver not ready), then with hint Y → planned at once (`onScan` returns true on the change); `loginFor`: a hint seen before the login object exists (`early`) is replayed | forward first sightings only → B waits for the window |
| S9 | `node_link` test: resolver build | claim writes a record under the lease → release → resolver rebuilt → the payload resolves; a record whose open throws a Keystore error is left out, `keys` stays true, `keyCheck` is not called; a build that fails as a whole keeps the old resolver | no rebuild at release; build through `keyCheck` |

(S8 of v2 is gone with the memo it tested.)

**Device tests**

**D1 — the identifier judge inside the `rpa` unit (node, daily validation; merge gate of the node PR).** Judged from the same btmon capture and `logread` that the `rpa` arm of `scripts/dv/prov-provd-254.sh` already records (F42): no second ~50-minute run (`prov-provd-254.sh:31`; lease 3 300 s `:253`, loop cap 3 000 s `:267`). It is **part of the unit of suite `prov-rpa-254`** (`scripts/dv/prov-dv-254.sh:71`), not a suite of its own: a second suite line for the same arm would run the ~50 minutes twice. Its lines are therefore `PASS` / `FAIL prov-rpa-254: …` lines of that unit; in this document "D1" names these checks.
- **Where it runs in the arm**: the lines kept (next sentence) are fetched to the host **before** the arm's `rm` at `:286`; the judgement itself is placed after the arm's existing checks (`:287-318`) and before `pr_release` (F42). What is kept in the result log (and what the offline fixture consists of) is, in capture order: the node log lines `provd: adv field …` and `provd: adv registered reason=…`; each `MGMT Command (0x0055)` block and each HCI `LE Set Advertising Data` block (`LE Set Extended Advertising Data` on a controller that has it), **matched by opcode** (`0x08|0x0008`; extended `0x08|0x0037`) as the arm already matches the random-address commands (`:282-284`: btmon shortens command names when it does not write to a terminal) — the block's header line and its indented lines up to the next header. Nothing else of the capture is kept. ⚠️ btmon's exact text for the Manufacturer AD is taken from the first real capture (§10 step 3) and frozen in the fixture.
- **The arm exits early** (lease, unreachable node, a failed capture — its existing `exit 1` paths): the judge did not run; the unit is already FAIL by the arm's own line. No D1 line is printed and nothing counts as a pass. If the arm reaches the judge and the capture has **no `0x0055` block or no `adv registered` line** after the unit's marker → `FAIL prov-rpa-254: adv id: nothing captured` (never a pass).
- **Precondition**: the node's state, read from `/etc/batman-prov/prov.meta` as `last4()` does (`prov-provd-254.sh:67-73`), is `claimed` or `member` (both hold a 32-byte `AdvOwnerKey`). `unclaimed` or `legacy` → `FAIL prov-rpa-254: adv id: node is <state>, nothing to check`. That text is not in the known-failures list, so it shows as NEW; the bench nodes' base state is a committed member (`prov-normalise-254` only commits slot A; it does not make a member), so this is a set-up fault to look at, not an expected state.
- **Old image**: no `adv field` line at all after the marker → exactly one line, `FAIL prov-rpa-254: no adv field line on 04 (<BATMAN_VERSION>): an image without the field`, and the block checks below are skipped (so an old image produces this one D1 line and no other).
- For every `adv registered` line after the marker: the last `adv field` line since the previous `adv registered` line (§3.4-6) must be `id=1`. An `id=0` is a FAIL printed with its `why=`; it is the product's fail-open path, and is attributed with evidence like any other FAIL (never "flaky" by default). To keep that path out of the judged registrations, **nothing logs in to the node between the unit's marker and the end of the capture except the arm's own one connection** (no status page, no Wi-Fi session of the harness: F33).
- For every `MGMT Command (0x0055)` block after the marker: `Advertising data length: 31`, and exactly one Manufacturer AD with CID 0xFFFF and 6 B of data. **A registration's payload** is that of the last `0x0055` block before its `adv registered` line (a registration may show more than one block). The two clocks differ: the `adv registered` line comes from `logread` in whole seconds (`:281`), a block from `btmon -t` in microseconds; so "before its line" means **a block's time ≤ the line's second + 1 s**, compared with the arm's own `sec()` as `:297-303` do. Registrations in this arm are minutes apart, so no block can be taken for the wrong one. Every registration has at least one block, and the payloads of the registrations are **pairwise distinct** (R-N1).
- For every HCI advertising-data block after the marker (this settles F9 on a device): data length 31; it contains the Flags AD, the 128-bit UUID list, and one Manufacturer AD whose 6 B equal those of the last `0x0055` block before it. A block with Flags missing, with a different length, or with other payload bytes is a FAIL.
- The existing checks of the `rpa` arm stay as they are, including `:302-303` (a random-address set with no provd registration 0..5 s before it → FAIL). With it, "the field changes at every RPA change" follows from: every RPA change has a registration, every registration has a new payload. **D1 adds no INVALID state.**
- `adv-data` (`scripts/node/prov-p2-254.sh:314`) becomes image-aware by the log. **The line it reads** is the last `adv field` line between the previous `adv registered` line and the `adv registered` line of the judge's own restart of provd (the arm already counts its registration, `r`) — never the last such line of the whole `logread`: after a prov_test push, a later run in the same boot would else read an old `id=1` and demand 31 B. One offline fixture has an older `id=1` line before a newer registration with none. That line `id=1` → its `0x0055` block must be 31 B with the Manufacturer AD; `id=0` or no line → 21 B without it. A mismatch either way is a FAIL. Its `ok` line prints the length and the `id=` value it judged by (`… 31 B, id=1` / `… 21 B, id=0 why=<why>` / `… 21 B, no adv field line`). The judge does not know which arm was meant: where this plan says "PASS at 31 B" (§10 step 3, D2's on arm), the `31 B, id=1` line must be in the output, else that run does not count (a fail-open push, `id=0 why=helper`, PASSes at 21 B). The arms that run under btmon (`dep-dbus`, `dep-bluetoothd`, `dep-bluetoothd-kill`, `:261-296`; today they judge only "no advertising enabled before provd's own Add", `:291-294`) get the same rule on their last `0x0055` block. `dep-dbus` is what proves the per-connection handle (§3.4-3). `dep-helper` has no btmon (`:242-259`) and is not changed.
- **Negative controls for "payloads are distinct"** (the device switch `ADV_ID_REUSE` of v3 is deleted): (a) today's image FAILs D1 (the old-image line above) while `adv-data` PASSes at 21 B — the old-image evidence of #290; (b) offline fixtures in `scripts/test-dv-ble-254.sh`, cut from the step-3 capture in the format above: good → PASS; **one payload reused by two registrations → FAIL**; `adv field` lines removed → the old-image FAIL; an HCI block without Flags → FAIL; no block at all → "nothing captured" FAIL. The code-level control of R-N1 is G2 (a).
- **Known-failures entry** (until the fleet image carries the field): suite `prov-rpa-254`, ERE `^FAIL prov-rpa-254: no adv field line on 04 \(1\.5\.14-wsl\.31\+[^)]*\): an image without the field$`, issue 329, an expiry date. The ERE is **pinned to the old image's version**: a later image on which the line has vanished prints another version, does not match, and is NEW. A suite is KNOWN only if every FAIL line matches (`known-failures.sh`), so no other FAIL of the `rpa` unit is hidden by it.
- **Merge gate of the node PR**: the three runs of §10 step 3 on **04** with the PR's binaries pushed — the `rpa` unit (with D1) PASS, `adv-data` PASS at 31 B, `adv-data` with `ADV_ID_OFF` PASS at 21 B — and during the `rpa` unit the node neither rebooted nor recorded a crash: boot id before = after and no new line in `/opt/batdata/log/boot-reasons.log` (F47). This is read **by hand** before and after the run (`cat /proc/sys/kernel/random/boot_id`, `wc -l` of the log, both read-only) and reported in the PR; the unit does not do it (`bid()` is in `prov-lib-254.sh:26`, which the `rpa` unit does not source). The binaries are pushed only by the unit's own push step, which first checks the image (§10 step 3). ⚠️ **This evidence is from prov_test builds** (the push verbs refuse a release binary); the release build first runs on a device with the image at §10 step 7, which is also where 02 is checked. The PR body says so and does not claim "release verified".

**D2 — the user-visible gain (S20 + two nodes in range, the target owned by the phone).** The judged rounds of the main runs are node-page rounds (`_candidates`); one further pair of runs judges the `loginFor` path, where F1 was seen (the `loginFor` pair below). The operator drives the phone remotely over adb with these actions only: launch the app, tap a node card, the app's Back button, sub-page entries, the HOME key, and in the `loginFor` pair the read-only button 「讀取設定」. Nothing that changes a node.
- Set-up: PR helper and prov_test provd pushed by the push step of §10 step 3 (F43); one APK (`adb install -r` only) and **one app process** for all runs. Each run is made inside one invocation of the `adv-data` unit of step 3, on arm `ADVID_PUSH=<dir>`, off arm `ADVID_PUSH=<dir> ADVID_OFF=1`, with **`ADVID_HOLD=1500`** (seconds): after its judge has passed the unit prints a hold line and waits that long before its `pr_release`, so the binaries stay pushed for the run under the unit's own lease and deadman. The unit's lease is its existing length plus `ADVID_HOLD`. The judge's `ok` line must show the arm as intended (`31 B, id=1` on, `21 B, id=0 why=off` off); else the invocation is not used. 1 500 s: one run needs up to about 1 140 s from its step 1 (body ~15 s, HOME and mark ~10 s, wait ≤ 1 020 s, launch ≤ 60 s, off arm ≥ 30 s and the body), which leaves about 6 minutes to begin; the `loginFor` pair has a few more taps. **A run whose judged round or login has not ended when `pr_release` starts is INVALID.** **Between invocations the app is in the background**: HOME is pressed once the judged round (or the 「讀取設定」 result) has ended, and the app returns to the foreground for step 1 only after the hold line is printed — a foreground app would log in during the push and the judge, and its request can hold `ro` (F33) at the very registration the judge reads (`id=0`). ⚠️ `ADVID_HOLD` is the one thing v5 adds: without the v4 wrapper nothing else keeps a push in place, and a push outside a lease has no deadman. During the hold nothing of the unit acts on the node: the host waits, and on the node only the lease's deadman timer runs (`scripts/node/prov-lease-254.sh:8-9`; a renewal only re-arms it). ✅ source (NN). What restarts provd and the helper is the push and the judge **before** the hold line and `pr_release` **after** it. Each invocation restarts provd before step 1 (`start` registrations; the RPA changes there if it is older than 900 s, which does no harm: A is read in step 1, after them).
- **Precondition (MM m1)**: the phone stays awake and unlocked while charging. Checked read-only over adb before step 1 and again right before the launch of step 5 (`dumpsys power`: awake; `dumpsys window`: no keyguard showing; ⚠️ the exact field names on the S20 are read at test time). No phone setting is changed without the user's approval; a phone found asleep or locked makes the run INVALID, and that is reported.
- One run:
  1. Set the arm. On the home page, tap the node card: the node page begins a round at once (F48). Body shown → 「是 Y」 on the current address A.
  2. With the body shown, press the HOME key **on the node page** (no Back). HOME → `background()` at the **first** of `lifecycle hidden` / `paused` (`NodeLink.lifecycle` calls it for `paused`, `hidden` and `detached`, `node_link.dart:249-258`; on the phone the order when leaving is `inactive → hidden → paused`, on return `hidden → inactive → resumed`, so a running round's `round N cancelled` line lies between `hidden` and `paused`): the kept link is closed (`node_link.dart:236-240`; the node logs `adv registered reason=disconnect`), and **no round and no scan runs while the app is in the background** (F48). The memo for A stays; its 20-minute clock runs from the app's own last scan result of A, which is shortly before the body of step 1 (validity e).
  3. About 10 s after HOME, write a mark into the node log (`logger`, as `hmark` does, `prov-provd-254.sh:59`). The last provd advert line before the mark must be `adv registered reason=disconnect`; otherwise the run is INVALID **now**, before the wait.
  4. Wait, reading the node log read-only, for `adv registered reason=rpa_timeout`: 930–1 020 s after the **last** `adv registered` line before the mark (F14).
  5. Within 60 s of that line: adb launch, nothing else (`lifecycle resumed` → `foreground()`; the page is still the node page, so the round it begins is the **judged** node-page round, with no home round and no tap).
- **A run is valid only if all of these hold** (else INVALID: listed in the results, repeated, never counted either way):
  - (a) node log, between the mark and the `rpa_timeout` line: no `adv withdrawn reason=connect` and no `adv registered` line of any reason — so the phone did not reach the node during the wait and the 「是 Y」 memo still names the old address A (KK MAJOR-1);
  - (b) logcat, between `BMAPP nodelink lifecycle paused` and `… resumed`: no `BMAPP nl … round` start line (the cancel line of step 2 comes before `paused`);
  - (c) the app's pid in logcat is the same before and after (the memo lives in memory);
  - (d) the first `BMAPP nl … round` line after `lifecycle resumed` is the judged round, and no `BluetoothGatt: connect()` line lies between `lifecycle resumed` and it;
  - (f) the address of the judged connect (the one that ends in the body after the return) differs from the address A of step 1; equal → INVALID (the RPA did not change, and 「是 Y」 on A alone would pass). Both addresses are in the `connect()` lines already read;
  - (e) the first round after the return starts less than 1 190 s after the **body time of step 1** (「是 Y」 is dropped at a round start once unseen for 20 min, `core.dart:372-378`; its clock is `lastSeen[A]`, written only by the app's own scan callback, `core.dart:352-358`, which stops when the kept link parks — so it lies before the body, by up to ~10 s ⚠️ taken from the 2–8 s scan-to-body figure. Logcat's `onScanResult` lines include other scanner clients and are not used for this). Worst case of the procedure: ~15 s to HOME + 1 020 s + 60 s ≈ 1 095 s after the body, so the margin is ≥ ~95 s (⚠️ derived, not measured; the check itself is on the logged times).
- Lines read. Logcat: `BMAPP nodelink lifecycle <state>`; `BMAPP nl <t> round N full […]` (a round's start line; the judged round is the first one after `lifecycle resumed`) and `round N cancelled`; Android's `BtGatt.GattService: onScanResult … address=<addr>` (a scan result); `BluetoothGatt: connect() - device: <addr>` (the start of a connect). Node `logread`: `provd: adv registered reason=`, `provd: adv withdrawn reason=`, `provd: adv field`. The target's current address is the one whose connect ends in the body. The body line is the core's `BMAPP nl <t>   <addr>×<id> -> body` (`core.dart:491`; validity (e) uses its time). The app prints an address by its last two hex digits (`…58`), Android's lines print another short form (`5989DD_8`): the two are matched by time (in the F1 sample the trace line's time − N ms and the `connect()` line differ by 14 ms). "The first scan result of that address" in the pass rules is counted from the app's own `Start Scan with callback` line of the judged round or login, so another scanner client's results are not taken (in `ux-sub.logcat` all 84 `onScanResult` lines are the app's).
- Pass, **on arm**: in the judged round the first `connect()` goes to the target's current address and starts ≤ 6 s after the judged round's first scan result **of that address** (6 s = `Params.gap`), with no `connect()` to another address before it. **Off arm** (the negative control): the first `connect()` of the judged round starts ≥ 29.5 s after the judged round's **start line** (the window is 30 s; 0.5 s allows for the two logcat times, and the on arm's limit is 6 s, so nothing is lost) (`Params.window` counts from the round's start, F48; v3 measured from the first scan result). If an off-arm run connects sooner, the D2 result is INVALID as a whole (the control does not discriminate) and that is reported.
- ≥ 3 valid runs per arm, arms interleaved; fewer → FAIL. Time to body and the resolver build time are reported, not gated.
- **The `loginFor` pair (F1's own path; MM M1)**: one valid run per arm, same set-up and wait. Steps 1, 3, 4 as above. Step 2 becomes: the app's Back button to the home page (`_back` → `Page.home`, `home_page.dart:206-208`; `NodeLink.setPage` closes the kept link, `node_link.dart:224-232`; the node logs `reason=disconnect`). With two nodes on the phone, `setPage(Page.home)` may begin a home round at once (`core.dart:229-250`: the node-page round's full end covers only Y) and that round may connect to either node before the next tap; the next tap cancels it, step 3's rule (the last advert line before the mark is `adv registered reason=disconnect`) rejects a run where a link was still up, and step 4 counts from the last registration before the mark. Then the 設定 icon of the home page (`home_page.dart:337-341` → `Page.other`: the running round is cancelled and none can start, `core.dart:207`, `:229-250`), then HOME. Step 5 becomes: launch (the page is still `Page.other`, so `foreground()` begins no round, `core.dart:264-268`), then 「查看節點設定」 → 「讀取設定」 (`settings_page.dart:88`; `dev_pages.dart:233-244`: `OpSession.once(opDeps(app), …, (c, gone) => c.settings())`, whose login is `link.loginFor`, `settings_pages.dart:28`; with no kept link parked on the node, `_loginFor` scans, `node_link.dart:374-392`). The request only reads the node's settings. **Lines and clocks of this pair (PP M1).** The core's lines `BMAPP nl <t0> loginFor <id>` (the login's start, `core.dart:737`) and `BMAPP nl <t1>   loginFor <addr>×<id> -> <result>` reach logcat only when the lease is released, after the login and the request (`_forwardLog` runs only from `note()` and `_pump()`, `node_link.dart:127-139`; `_loginFor`, `:340-424`, does not pump; the release does, `:694-727`). Their **position and logcat time are therefore not used**, only the core seconds `<t0>`, `<t1>` printed inside them. What is in logcat at once is the trace line `BMAPP nl loginFor <addr>×<id> result=<res> after <N>ms` (`node_link.dart:496`), one per attempt, at the attempt's end. So: **the first attempt** is the first such trace line after `lifecycle resumed`; **its start on the core clock** is its `<t1>` − N/1000; **its start on the logcat clock** is the trace line's time − N ms. Sample, the F1 run (`ux-sub.logcat`): `297.0 loginFor …`, `332.1 loginFor …58×… -> undecryptable`, trace `… after 5075ms` → 332.1 − 5.075 − 297.0 = 30.0 s. Validity: (a), (b), (c), (f) as above; instead of (d), no `BMAPP nl … round` start line between `lifecycle resumed` and the first trace line; (e) does not apply (memos are dropped only at a round start, and no round runs). Pass, on arm: the first attempt's address is the target's current address; its start on the logcat clock is ≤ 6 s after the first scan result of that address after `lifecycle resumed`; and no `connect()` to another address lies between `lifecycle resumed` and it. Off arm: the first attempt's start on the core clock is ≥ 29.8 s after `<t0>` (the window is 30 s; `<t0>` and `<t1>` are printed rounded to 0.1 s, `core.dart:721`, and the sample is 30.025) (`LoginFor.next` counts `Params.window` from the login's start, `core.dart:760-835`) — this is F1 again, the negative control; an off-arm run whose first attempt starts sooner makes the pair INVALID. (One cause to look for first: the home round after Back got two `noResponse` on the old address, which removes 「是 Y」, `core.dart:531-534`; the off arm then has nothing to wait on.) ⚠️ Not run. ⚠️ MM's outline named "the settings sub-page" after the body; traced, the pages opened **from the node page** keep `Page.node` (only `home_page.dart` and two other pages call `setPage`) and their login borrows the parked kept link without a scan (`node_link.dart:360-373`), so the route above goes through the home page instead. ⚠️ 「查看節點設定」 exists only in a dev build (`devTrust`, `settings_page.dart:82`) and is enabled only when the start-up key check allows a login (`:33`, `:96`); with two owned nodes the page's node picker needs one more tap (`dev_pages.dart:29-32`, `:232`). If the test phone's build has no such entry, this pair is ❌ not run and F1's own path stays host-only (S1L, S7): reported on the #329 checklist, not hidden.
- **No reboot arm** (dropped in v3): a reboot removes the pushed binaries and the switch (F43), so the off arm would not be off; the phone path after a reboot is the same core path as after a rotation; the node side of a reboot is the `start` registration covered by G2 and D1. ❌ An end-to-end reboot run is therefore not part of this plan; it becomes possible once an image carries the field (#329 checklist).
- Side effects: tmpfs binds and `provd.env` on the node, provd / helper restarts (advertising gaps of seconds). Restore: the unit's `pr_release` (`unbind-all`, which checks that provd is `/rom`'s again). No reboot, no change of claim state, no change on the phone beyond `adb install -r`.

**D3 — old app + new node.** The current release app against a node with the field: finds the node, claim-scan path (`claim.dart:340`) and login work as before. No negative control by nature (it shows the absence of a regression); listed as such.

**Rules with no device row**: R-N2b (G2 c / c2 only): a real BlueZ refusal cannot be produced with a release build; the fake covers the code path, and `ADV_ID_OFF` on a device (§10 step 3) covers BlueZ's handling of the empty dict. **`ADV_ID_OFF` is checked once during this work (§10 step 3, and as D2's off arm), not in the daily suite**: the daily suite runs release binaries, which have no switch, and the empty dict is what R-N2 sends whenever the helper does not answer. One line on the #329 checklist: repeat step 3's `ADV_ID_OFF` check when the BlueZ version changes. §3.4's second consequence (another target using an attempt on Y's address) has no test.

## 9. Alternatives considered

| # | Alternative | Why not |
|---|---|---|
| A1 | Shorter wait only | Still guesses: tries other nodes in scan order (F1's `undecryptable`); a fixed wait |
| A2 | Bonding / IRK so the phone OS resolves the RPA | Forbidden: any pairing hands out the adapter IRK + identity address (F28) |
| A3 | Static identifier (last-4, `device_id` hash) | Links every RPA (F8) |
| A4 | Time-based identifier | Clocks 15–17 months off, no RTC (F30); a timer not tied to the RPA links consecutive RPAs |
| A5 | Counter with phone look-ahead | Needs a counter persisted on the node and resync logic; the random nonce is stateless |
| A6 | Identify by connecting and reading STATUS | One connection per address; claimed nodes carry no last-4 (F8) |
| A7 | Identifier as Local Name in the scan response | Abuses the name (shows in every scanner); not needed now that the CID is decided |
| A8 | Replace the UUID list by 128-bit Service Data | Old apps filter on the UUID list (F5) |
| A9 | Member marker as well | No room for two fields in 10 B; no member flow uses `NodeLink` (F26) |
| A10 | Give provd `adv_owner` and compute in provd | Reverses F22 for no gain |
| A11 | Bind the tag to the RPA | provd cannot read the RPA (F16) |
| A12 | `id=` inside the `adv registered` line | Breaks every existing parser of that line (`$NF` parsers if appended; the literal `adv registered reason=` greps if prepended, §5) |

## 10. Implementation order (no code here)

Per #290 the harness change is its own PR and merges first, with old-image FAIL and new-build PASS evidence. **No step needs a file before the PR that owns it**: the push step of step 3 takes a **directory** holding the node branch's locally built files (`ADVID_PUSH=<dir>`), and the node-side verbs take the files and their hashes as arguments (`push-provd <bin> <bin-sha> <init> <init-sha>`, `prov-wbox-254.sh:138-139`), so the harness branch is run against the node branch's files before either merges.

The five places of the `ADV_ID_OFF` switch (F41), each in exactly one PR:

| Place | PR |
|---|---|
| `feed/batman-prov/files/batman-provd-test.init:25` | node (product file) |
| `feed/batman-prov/src/cmd/batman-provd/testenv_provtest.go:26-50` | node (product file) |
| `scripts/node/prov-wbox-254.sh:162` | harness |
| `scripts/node/prov-p9-254.sh:77` | harness |
| `scripts/node/ble-lib-254.sh:173` (`PROVD_KEYS`) | harness |

1. **Node branch**, built locally, not merged: helper verb `adv.id`, `proto.AdvIDTag`, `Server.AdvID`, `register()` (§3.2), the two seams, `preflight`, the `adv field` log line, the `ADV_ID_OFF` switch in its two product places (table above). Host tests V1, G1–G5.
2. **Harness branch, run against wsl.31** (the nodes as they are; 04 is the DUT, as in every prov unit): the `rpa` unit FAILs with exactly the old-image line of D1, `adv-data` PASSes at 21 B. This is the old-image evidence.
3. **Harness branch, run against the node branch's prov_test binaries pushed to 04.** There is **no separate wrapper** (v4's `scripts/dv/advid-push-254.sh` is deleted: a unit takes the host lock itself and `pr_lock` has no "already mine" branch, `prov-provd-254.sh:82`, `prov-254.sh:178-185`; and a unit's own `pr_release` unbinds whatever was pushed before it). Instead `scripts/dv/prov-provd-254.sh` gains one env-gated step, run right after the unit's existing `lease` (`:82`; the `rpa` arm's is `:253`). With the variables unset nothing changes, so the daily run is as today. The variable names are new and belong to the harness PR:
   - `ADVID_PUSH=<dir>`: `<dir>` is the node branch's local prov_test build — `batman-provhelper`, `batman-provd`, `batman-provd-test.init`, `SHA256SUMS` — made in step 1. It is **not** under `$PR_TOOLS/<image version>/`: that directory is the output of `scripts/dv-prov-tools.sh`, keyed by image version and read by every prov suite (`pr_helper_push`, `prov-254.sh:714-717`; `pv_pre`, `prov-dv-254.sh:32`), and nothing of this plan writes into it. A missing file or a hash that differs from `SHA256SUMS` → nothing is pushed, FAIL. First **the image check** — the node's `BATMAN_VERSION` (already read by the script's head, `:83`) must be in the script's named list of images built by the firmware build that runs the patch-999 byte-compare and the `patch-witness` gate (F45, F46); the list starts with `1.5.14-wsl.31+5c718d8.fwd4f5dc8.bench`; **a version not in the list → nothing is pushed, FAIL**. Then the push itself, written out in the step as `eh12-push-provd-254.sh:30-38` does it: hashes on the host, `pw prep`, `scp` of the three files into the unit's W directory, `pw push-helper <file> <sha>`, `pw push-provd <bin> <sha> <init> <sha>`. The helpers `pr_helper_push` / `pr_push_helper` are **not** used: they read `$PR_TOOLS/$PR_V/<variant>/`, and `PR_V` is set only by `pr_begin` (`prov-254.sh:661`), which this script does not call (it uses `lease`, under `set -u`, `:40`).
   - `ADVID_OFF=1` in addition: `set-provd-env ADV_ID_OFF=1`. That verb restarts provd and itself refuses unless `/proc/<provd pid>/environ` carries exactly the wanted keys (`prov-wbox-254.sh:172-181`), so v4's separate "control not armed" check is not needed.
   - `ADVID_HOLD=<seconds>`: only for D2 (§8); the unit's lease is lengthened by it, and a hold line is printed when the wait begins.
   - Nothing new restores: the unit's existing `pr_release` runs `unbind-all` (`prov-254.sh:546`), which asserts that provd is `/rom`'s again (`prov-wbox-254.sh:81-102`), and `unbind-all` is already in the first segment of the lease's deadman (`prov-lease-254.sh:19-20`).

   The `adv-data` judge cannot be run on pushed binaries today: its only caller is the `boot-provd` unit (`:144`), which FAILs a prov_test init (`:91`), and the unit list has no entry for it (`:41`). The harness PR therefore adds the smallest entry that can: a unit name **`adv-data`** in that list (and in the usage text of `:41`), which does `lease 900` (+ `ADVID_HOLD` when set), the env-gated step, `pr_pc_place`, the btmon upload with its sha check (as `:141-144`), `j adv-data "$PCD/btmon" 120` and `pr_release`. It gets no suite line in `prov-dv-254.sh`; the daily keeps judging `adv-data` inside `boot-provd`.

   The three runs, all with 04 as the DUT:
   - `ADVID_PUSH=<dir> bash scripts/dv/prov-provd-254.sh rpa` → the `rpa` unit with D1 PASS, with the crash check of D1's merge gate;
   - `ADVID_PUSH=<dir> bash scripts/dv/prov-provd-254.sh adv-data` → PASS with the judge's line `31 B, id=1` in the output (a PASS at 21 B here is a failed run: the push fell open);
   - `ADVID_PUSH=<dir> ADVID_OFF=1 bash scripts/dv/prov-provd-254.sh adv-data` → PASS with the line `21 B, id=0 why=off`. This proves the empty-dict assumption of §7 on a device.

   The capture of the first run becomes the offline fixture. ⚠️ All three run **prov_test builds**: `push-helper` checks that the file is a prov_test build (`prov-wbox-254.sh:128-129`) and `set-provd-env` works only with a prov_test provd; `push-provd` refuses only a file whose hash equals `/rom`'s provd (`:143`); the release build of the same source first runs on a device at step 7. If BlueZ refuses the empty dict here, or the HCI block is not as D1 expects, stop and revise §3.2 before anything merges.
4. **Harness PR (first to merge).** Files (own grep, F41 / F42):
   - `scripts/dv/advid-judge-329.sh` (new) — the D1 judge as functions over a saved btmon text and saved log lines, nothing else. It is sourced by `prov-provd-254.sh` and by `scripts/test-dv-ble-254.sh`, as `scripts/dv/link-grace-329.sh` is (`prov-254.sh:82`, `test-dv-ble-254.sh:190`): `prov-provd-254.sh` connects to 04 in its head (`:83`), so the offline fixtures cannot source it;
   - `scripts/dv/prov-provd-254.sh` — the call of that judge in the `rpa` arm (kept lines fetched before the `rm` at `:286`); the env-gated push step after `lease` with the image list; the unit name `adv-data` (step 3);
   - `scripts/node/prov-p2-254.sh` — `adv-data` (`:314`) and the `dep-*` arms that run under btmon become image-aware (§8 D1); the comment at `:62`;
   - `scripts/node/prov-wbox-254.sh:162`, `scripts/node/prov-p9-254.sh:77`, `scripts/node/ble-lib-254.sh:173` — `ADV_ID_OFF` in the three harness lists, all three in one commit;
   - `scripts/test-dv-ble-254.sh` — the offline fixtures and their verdicts (§8 D1);
   - `scripts/validation-known-failures.txt` — the one entry of §8 D1 (suite `prov-rpa-254`, version-pinned ERE, issue 329, expiry), because the fleet image has no field until step 5 ships.

   No new suite line: D1 is part of `prov-rpa-254` (`scripts/dv/prov-dv-254.sh:71` is unchanged). The existing parsers of `adv registered reason=` are not touched (the line is byte-identical). PR body: the outputs of steps 2 and 3.
5. **Node PR**: the node branch as built in step 1 (with the switch's two product places), plus two comments (`bluez.go:39`, stale since F-P11; `testenv_release.go:7-8`, which names a `strings` gate that does not exist → it names the build tag and the firmware `check-prov-test-gate` instead), the log contract in `254-p2-impl.md:227`, `219-protocol.md` §4.1 / §6 and the vector. **Merge gate: the three runs of step 3 on 04** (§8 D1), with their output in the PR body, marked as prov_test builds.
6. **App PR**: Rust resolver and `adv_id_tag`, `scan()` pair through `BleBackend` / `BleGate`, `buildResolver`, `core.dart` and `node_link.dart` (§3.4-9..16), `329-app-uiux.md` §4.3.3-5 / -6 with the simulations. Tests R1, R2, S1–S7, S9.
7. **D2, D3**, then full validation on the image that ships. That image is the first **release** build of the field on a device. Full validation runs suite `prov-rpa-254` (with D1) with **04** as the DUT; the prov suites refuse any other DUT (`pv_pre`, `prov-dv-254.sh:28`), so D1's "on 04" text and ERE are right as they are. **02** (same board, same image) is checked by one direct run of the `rpa` unit with the roles swapped through `NODE` / `PEER` / `MAC` / `PEERMAC` (`prov-254.sh:29-31`). ⚠️ Never run that way: 04 must then act as the central, and the unit's texts and lock name still say "04". If it does not run as it is, 02 is reported ❌ not verified and the user decides; no script is changed for it in this plan.
8. **After the fleet image carries the field**: a harness PR removes the known-failures entry and asserts it gone (precedent c03898c, F44).
9. **#329 checklist** (no new issues): the node part of this plan; CID → a SIG CID before v3.0 PROD; on a CM4: D1 and `bluetoothctl show`; one end-to-end reboot run once an image carries the field; repeat the `ADV_ID_OFF` device check when the BlueZ version changes.

## 11. Open points

None that the design leaves to the user. Three things are **reported** to the user because they are properties of the approach the user chose, not details:
1. The replay limit ("Known limits", §4.4): a recorded advert lets an attacker test whether a nearby phone owns that node. **No recording is needed either**: by flooding made-up adverts an attacker finds a payload the phone accepts after an expected 2²⁴ / N adverts — about 3.9 days of the phone's scanning time at 50 adverts per second for one owned node (⚠️ computed, not measured) — and that payload then works like a recording, without expiry. Not closed here; closing it means a different approach (freshness).
2. The claim state becomes visible passively (31 B vs 21 B); today it takes a connection (F34).
3. The 3-byte nonce repeats: about 30 times a year per node a payload is one the node sent before, and an observer who recorded both sightings can link those two periods (§3.1; ⚠️ computed). This is the price of the 3-byte tag in point 1.

## 12. Not verified

| Item | Mark | Where it is settled |
|---|---|---|
| RPA timeout on the node (900 s assumed from the kernel default and the harness) | ❓ value not read on a device for this plan | D1 (the `rpa` arm already measures the rotation) |
| CM4 controller: legacy advertising, LL privacy | ❓ | #329 checklist |
| BlueZ accepts an empty `ManufacturerData` dict as "no data" | ⚠️ source only | §10 step 3 |
| At 31 B the Flags on air are BlueZ's, inside the instance data (F9 with F-P10 / F-P11) | ⚠️ reasoned; sources not in this repo | D1's HCI block check (§10 step 3 first) |
| btmon's text for a Manufacturer AD in the `0x0055` block and in `LE Set Advertising Data`; that the `rpa` arm's capture shows both kinds of block | ⚠️ not captured | §10 step 3 (fixture) |
| Whether the wsl.31 image on the nodes holds the kernel `Image` in which patch 999 is applied (F45) | ⚠️ inferred from the build tree; no witness in the image | D1 judges the HCI block at 31 B on the device; the push step of §10 step 3 pushes only to versions on its list |
| Every figure about flooding, nonce repeats and foreign false positives (§3.1, §4.4); the rate an Android scan delivers results | ⚠️ computed / not measured | not settled; a faster or slower flood changes the days, not the conclusion |
| Android delivers manufacturer data together with a UUID-filtered result on the S20 | ⚠️ | D2 |
| Resolver build time on the S20 | ⚠️ not measured | D2 (reported) |
| D2's timing margin (≥ ~95 s before the 「是 Y」 memo expires) | ⚠️ derived | checked per run on the logged times (validity e) |
| 9.5 s bound of the kernel re-enable; LE encryption failure forcing RPA expiry | ⚠️ reasoned / controller-dependent | not settled; §4.6 bound |
| Keystore key after a phone backup / restore | ⚠️ not checked | none needed: the fallback is today's behaviour |
| Whether an unauthenticated peer can trigger the `ro` reads | ⚠️ not traced | none needed: consequence is a missing hint |
| `loginFor` hint path on a device | ⚠️ not run; needs a dev build on the test phone | D2's `loginFor` pair (§8); without a dev build ❌, host-only (S1L, S7) |
| Step 3 and the node PR's merge gate run prov_test builds, not the release build | ⚠️ by construction (the push verbs refuse a release binary) | §10 step 7: full validation on the image that ships |
| The `rpa` unit with 02 as the DUT (roles swapped by environment) | ⚠️ never run | §10 step 7; else ❌ reported |
| Nothing acts on the node during `ADVID_HOLD` except the deadman timer | ✅ source (`prov-lease-254.sh:8-9`), not on a device | D2 validity rule (a) |
| The phone stays awake and unlocked for ~17 min on the charger; `dumpsys` field names | ⚠️ not checked (no device access for this document) | D2 precondition, per run |
| §3.4 consequence 2 (another target spends an attempt on Y's address) | ❌ no test | stated only |
| End-to-end run after a node reboot | ❌ not run | #329 checklist |
| SIG rule on shipping 0xFFFF | ⚠️ | checklist item (CID before v3.0) |
| "2–8 s" | ⚠️ derived from other logcats (§1.7) | D2 reports the measured time |

## 13. Changes

### 13.0 Round 6 (v6 → v6.1): no BLOCKER, no MAJOR

QQ (harness / node side) and RR (phone side / D2) reviewed the whole v6. All 13 MINORs are applied as text; nothing else changed. QQ: m1 the range of the `adv field` line the `adv-data` judge reads (+ one fixture); m2 what `push-provd` refuses; m3 the crash check is read by hand; m4 `adv-data` lease 900 s and the usage text; m5 `prov-normalise-254`; m6 a line number; m7 one commit for the three lists. RR: 1 tolerances of the off arm (29.5 s / 29.8 s); 2 where the lifecycle samples are; 3 `review_pr1_test.dart` has four `Radio` subclasses; 4 the body line and matching the two address forms; 5 scan results counted from the app's own scan start; 6 an attribution hint for the pair's off arm.

### 13.1 Changes from v5 (round 5)

Review round 5: NN (0 BLOCKER / 1 MAJOR / 6 MINOR) and PP (0 / 1 / 5), both APPROVE-WITH-CHANGES. v6 changes text only: how the push step gets its files, how the `loginFor` pair is timed, and eleven restatements. No mechanism, no log line and no product rule is added; §3–§7 change only in §3.4-14 (one sentence). Neither reviewer found a contradiction between sections other than NN MAJOR-1's.

| Finding | Disposition | Where |
|---|---|---|
| NN MAJOR-1 — the push step cannot run as written (`pr_helper_push` needs `PR_V`; the tools directory is keyed by image version and shared by every prov suite); "as arguments" against "`DV_PROV_TEST`" | **fixed**: `ADVID_PUSH=<dir>` (the node branch's local build, outside `$PR_TOOLS`); the step does `pw prep` → `scp` → `pw push-helper` → `pw push-provd` itself, as eh12 does; the references to `pr_helper_push` and `DV_PROV_TEST` are deleted; the §10 opening agrees | §10 opening, step 3; §8 D2 set-up |
| PP M1 — the `loginFor` pair's anchor line reaches logcat only after the lease is released (66 s late in the F1 capture) | **fixed** by text: the pair is timed by the core seconds inside the lines and by the immediate trace line `loginFor … result=… after Nms`; validity ends at the first trace line | §8 D2, the `loginFor` pair |
| NN MINOR-1 — two clocks in D1's pairing | **fixed**: block time ≤ the line's second + 1 s | §8 D1 |
| NN MINOR-2 — the `adv-data` judge does not know the intended arm | **fixed** by text: the `ok` line prints length and `id=`; "PASS at 31 B" requires that line | §8 D1, D2 set-up; §10 step 3 |
| NN MINOR-3 — the hold's ⚠️ can be settled; "the RPA does not change" is false after 900 s | **fixed** (✅ source; sentence corrected) | §8 D2 set-up; §11 |
| NN MINOR-4 — 1 300 s leaves too little; lease size unstated | **fixed**: 1 500 s; lease = existing + hold; a run cut by `pr_release` is INVALID | §8 D2 set-up; §10 step 3 |
| NN MINOR-5 — app state between invocations | **fixed**: background until the hold line | §8 D2 set-up |
| NN MINOR-6 — the D1 judge must be sourceable by the offline test | **fixed**: `scripts/dv/advid-judge-329.sh`, as `link-grace-329.sh` | §10 step 4 |
| PP m1 — Back to home may begin a home round; where 930–1 020 s counts from | **fixed** (stated; counts from the last registration before the mark) | §8 D2 step 4, the pair |
| PP m2 — an unchanged RPA would pass the on arm | **fixed**: validity (f) | §8 D2 |
| PP m3 — `hidden` comes before `paused` | **fixed** (wording; rule (b) unchanged in effect) | §8 D2 step 2, (b) |
| PP m4 — line numbers | **fixed** | §8 D2, the pair |
| PP m5 — `next()`'s split is per target; when `likeTried` is added | **fixed** (one sentence) | §3.4-14 |

### 13.2 Changes from v4 (round 4)

Review round 4: LL (0 BLOCKER / 1 MAJOR / 7 MINOR) and MM (0 / 1 / 7), both APPROVE-WITH-CHANGES. v5 deletes the push wrapper, restates what the findings hit, and adds one pair of D2 runs. Product design (§3–§7) is unchanged apart from wording.

**LL's findings**

| Finding | Disposition | Where |
|---|---|---|
| MAJOR-1 — the step-3 wrapper and the merge gate cannot run as written (nested lock; `pr_release` unbinds; `adv-data` has no unit that passes on a prov_test init; 02 as DUT) | **fixed by deleting the wrapper**: an env-gated push step inside `prov-provd-254.sh` after `lease`; three named invocations; a unit name `adv-data` (the judge was not callable directly); merge gate = those three on 04; 02 at the image step | §10 steps 3–5, 7; §8 D1 |
| MINOR-1 — where the judge sits against the `rm`; HCI blocks by opcode | **fixed** (the `rm` is at `:286`; LL wrote `:288`) | F42, §8 D1, §10 step 4 |
| MINOR-2 — `dep-helper` has no btmon | **fixed by deletion**: `dep-helper` gets no check; the btmon arms are named | §6, §8 D1 |
| MINOR-3 — "pairwise distinct blocks" against "blocks ≥ registrations" | **fixed**: one payload per registration (its last `0x0055` block) | §8 D1 |
| MINOR-4 — the P1 canary sentence has no file | **deleted**; points to G2 | §4.4 |
| MINOR-5 — merge-gate evidence is a prov_test build | **stated** ⚠️ | §8 D1, §10 step 3, §12 |
| MINOR-6 — 4 s poll; 35 minutes; "launch + tap" | **fixed**: run loop ≤ 5 s (`bluez.go:689`); ~50 min; launch alone | F38, §3.2, §8 G2 / D1, §13.3 |
| MINOR-7 — `logLimit` has one memory for all keys | **fixed**: F49 restated; premise named in G2 (c2) | F49, §8 G2 |

**MM's findings**

| Finding | Disposition | Where |
|---|---|---|
| M1 — F1 is in `loginFor`; no device test of that path | **fixed**: one pair of D2 runs (on / off) through a read-only `loginFor` entry. The route differs from MM's outline (traced: node-page sub-pages borrow the kept link); ⚠️ needs a dev build | §8 D2, S1L, §12 |
| m1 — the screen must be awake at the launch | **fixed**: precondition, checked read-only; else INVALID | §8 D2 |
| m2 — validity (e) read the wrong clock | **fixed**: measured from the body time of step 1 | §8 D2 |
| m3 — R-A6 "bit for bit" | **restated**, the one difference named | R-A6 |
| m4 — "scan order" of like addresses | **fixed**: which list, for the round and for `LoginFor` | §3.4-13, -16, R-A3 |
| m5 — how `NodeLink` gets the resolver; S9 on the host | **fixed**: one sentence; ⚠️ the Rust-call seam | §3.3 |
| m6 — `review_pr1_test.dart` is not a backend fake | **fixed** | §3.4-8 |
| m7 — alternating hint / no-hint adverts | **stated**, no mechanism | §4.4 |

**Deviations and things to know (v5)**
- A unit name `adv-data` is new harness work: the judge arm could not be called directly.
- `ADVID_HOLD` is new: D2's set-up relied on the deleted wrapper, and nothing existing keeps a push in place under a lease for the length of a run.
- "The shipped image runs the `rpa` unit on both nodes" is not how the harness works: the prov suites accept only 04 as the DUT (`prov-dv-254.sh:28`). 02 is one direct run with swapped roles, ⚠️ never done.
- D1's "on 04" FAIL text and ERE are unchanged: the unit's texts say "04" literally and the daily DUT is always 04.

### 13.3 Changes from v3 (round 3; history, as written for v4)

Review round 3: JJ (0 BLOCKER / 1 MAJOR / 14 MINOR) and KK (0 / 2 / 14), both APPROVE-WITH-CHANGES. v4 is a small revision: nothing was restructured, no mechanism was added, and nothing both reviewers accepted was reopened (the approach, CID 0xFFFF in development, no battery measurement, no clock on the nodes, the replay / owner-phone oracle and the passive claim-state visibility as accepted limits, the P2 advertising and RPA timer contract, N1 #358, the kept link #359, the plugin fix #357, the key derivations).

**What changed, in short**
- Payload split **3 B nonce + 3 B tag** (was 4 + 2); same 6 B, 10 B AD, 31 B. Flooding, nonce-repeat and false-positive figures recomputed and stated honestly (§3.1, §4.4, §11).
- D2: the app waits in the **background** (HOME on the node page), returns by launch alone; validity rules and timings re-derived from `core.dart` / `bluez.go`; the logcat lines named.
- The device gate for 31 B is an **image-version list** checked before anything is pushed; F9 and F-P10 reconciled by reasoning (⚠️) and settled by a new HCI-block check in D1; the crash check names the boot id and `boot-reasons.log`.
- `ADV_ID_REUSE` **deleted**; uniqueness has two negative controls (today's image, an offline fixture). `ADV_ID_OFF` stays, checked once, not daily; its five places each belong to one PR.
- The release-binary claim no longer cites a `strings` gate (none exists): build tag + the firmware build's `check-prov-test-gate`.
- D1 is part of the unit of suite `prov-rpa-254` (no suite of its own), with defined results for an early exit, an empty capture, an unclaimed node and an old image, and a version-pinned known-failures ERE.
- New facts F46–F49 (§1.9); citations corrected (F9, F27c, F32, F33, F35, F36, F41, F42, F45).

**JJ's findings**

| Finding | Disposition | Where |
|---|---|---|
| M1 — a 2-byte tag is found by flooding in ~22 min; "no gain over replay" is wrong | **fixed** by parameter (3 + 3) and by rewriting the row with numbers; the residue (days, not closed) is a Known limit and §11 point 1 | §3.1, §4.4, §11 |
| m1 — D1 "claimed": is `member` included | **fixed**: `claimed` or `member`, read as `last4()` | §8 D1 |
| m2 — `strings` gate does not exist; F41 lacks `testenv_release.go` | **fixed**: claim replaced by the build tag + `check-prov-test-gate` (script ⚠️ unreadable here) | F41, F46, §3.2, §5 |
| m3 — §10 steps 1 and 5 contradict on where the init / testenv changes land | **fixed**: both product places are in the node branch from step 1; table of five places | §10 |
| m4 — `ADV_ID_REUSE` semantics undefined | **deleted** with the switch | §3.2, §8 D1 |
| m5 — which checks are one-off, which daily | **fixed**: `ADV_ID_OFF` once (step 3, D2), not daily, with the reason | §8, §10 |
| m6 — result when the `rpa` arm exits early; exact old-image text and ERE | **fixed** | §8 D1 |
| m7 — a key change does not re-register | **accepted**: old payload ≤ ~1 020 s, only the hint is lost; no trigger added | §4.4, §4.5 |
| m8 — 2 s synchronous wait in `register()`; handle snapshot | **accepted** (≤ 2 s more off air when the helper stalls) / **fixed** (same `b.mu` section as `conn`) | §3.2, §3.4-3, §6 |
| m9 — `likeTried` after a hint change; basis of the `noResponse` rule | **fixed**: one reading | §3.4-12, -15 |
| m10 — two resolver builds at once; record removal | **fixed**: newest build wins; a removed record's hint is ignored by the core | §3.3, §5 |
| m11 — a compromised provd can collect tokens | **accepted**, stated with the number | §4.4 |
| m12 — line-number drift; `TryLock` needs Go ≥ 1.18 | **fixed** (citations); Go: `go.mod` says 1.26.4, nothing to do | §1 |
| m13 — F33 wording; `ro` idle-closed after 30 s | **fixed** | F33, §6 |
| m14 — which logcat lines D2 reads; peer-cred negative test; `logLimit`; consequence 2 untested | **fixed** (lines named; `TestWrongPeerClosed` cited; `logLimit` in §3.2 and G2) / **accepted** (consequence 2 marked as not tested) | §8 D2, §4.4, §3.2, §8, §12 |
| Invent 1 (claimed vs member) | fixed | §8 D1 |
| Invent 2 (where the `strings` gate is) | deleted: there is none; nothing new is built | F41, §3.2 |
| Invent 3 (`ADV_ID_REUSE` details) | deleted | — |
| Invent 4 (which unit holds the switch checks) | fixed: one-off in step 3; uniqueness by fixture | §8, §10 |
| Invent 5 (early exit line, FAIL text, ERE) | fixed | §8 D1 |
| Invent 6 (handle and `conn` under one lock) | fixed | §3.2 |
| Invent 7 (`likeTried` membership, `noResponse` basis) | fixed | §3.4-12, -15 |
| Invent 8 (concurrent builds, removal) | fixed | §3.3 |
| Invent 9 (D2 logcat lines) | fixed | §8 D2 |
| Invent 10 (`logLimit` and the step-3 failure line) | fixed: the line goes through `logLimit`; G2 (c) uses a fresh `bleSide`, (c2) asserts the suppression | §3.2, §8 G2 |

**KK's findings**

| Finding | Disposition | Where |
|---|---|---|
| MAJOR-1 — D2: with the app in the foreground the home round reaches the node during the wait | **fixed**: background wait, return by launch alone, validity (a)–(e), timings re-derived | §8 D2, F48 |
| MAJOR-2 — "the image carries patch 999" had no executable check; F9 vs F-P10; crash check unnamed | **fixed**: version list before any push; HCI-block check; boot id + `boot-reasons.log`. Patch 999 is not one of the "11 witnessed" board patches; its evidence is the build's byte-compare and the applied patch in the build tree (F45); F9 reconciliation is reasoning until D1 runs | F9, F45–F47, §8 D1, §10 step 3 |
| MINOR-1 — the suite is `prov-rpa-254`, not `ble-rpa-254` | **fixed**; D1 is part of that unit | F42, §8 D1, §10 |
| MINOR-2 — claimed or member; unclaimed node | **fixed** | §8 D1 |
| MINOR-3 — ERE must be pinned to the old version | **fixed** | §8 D1 |
| MINOR-4 — `ADV_ID_REUSE` needs a second 35-min run | **deleted** | — |
| MINOR-5 — the `rpa` arm discards its capture | **fixed**: judged before the `rm`; kept lines defined | §8 D1 |
| MINOR-6 — F33: an owner session's `roCall`; do not drive the node with a logged-in session before a judged registration | **fixed** | F33, §8 D1 |
| MINOR-7 — `logLimit` and "written once" | **fixed** | §3.2, §8 G2 |
| MINOR-8 — cap against retry order | **fixed**: cap first | §3.4-15, R-A5 |
| MINOR-9 — hint change inside a round | **fixed** | §3.4-12 |
| MINOR-10 — `AdvID(2 s)` on the converge goroutine | **accepted**, stated in the lifecycle row | §3.2, §6 |
| MINOR-11 — who owns the `strings` gate | **deleted**: no such gate; existing mechanisms cited | F41, §3.2 |
| MINOR-12 — five switch places | **fixed**: table, one PR each | §10 |
| MINOR-13 — the step-3 wrapper is new work | **fixed** in v4 by a named wrapper; v5 deletes the wrapper (§13.2, LL MAJOR-1) | §10 steps 3–4 |
| MINOR-14 — the `bluez.go:39` comment | **fixed**: in the node PR list | §10 step 5 |
| Invent 1 (where the app sits in D2; how adb returns) | fixed | §8 D2 |
| Invent 2 (patch-999 device check; crash check) | fixed (version list; F47) | §10 step 3, §8 D1 |
| Invent 3 (Flags at exactly 31 B; which HCI command) | ⚠️ reasoned in F9; D1 judges `LE Set (Extended) Advertising Data` | F9, §8 D1 |
| Invent 4 (suite wiring; unclaimed node) | fixed | §8 D1 |
| Invent 5 (ERE text and version pin) | fixed | §8 D1 |
| Invent 6 (push wrapper: lease, deadman, restore) | fixed in v4; replaced in v5 by a step inside the unit (§13.2) | §10 step 3 |
| Invent 7 (cap vs retry for an address another target tried) | fixed | §3.4-15 |
| Invent 8 (the file that runs the `strings` gate) | deleted: none | F41 |
| Invent 9 (format of the kept capture lines) | fixed; btmon's exact text ⚠️ frozen from the first capture | §8 D1 |

**Deviations from the reviewers' suggestions, and things to know**
- D1 has no suite name of its own (v3: `ble-advid`): one arm, one unit, one ~50-minute run. Its known-failures entry is on `prov-rpa-254` with an ERE that matches only D1's old-image line.
- The image check lives in the push step only (v5: inside the unit, env-gated), not in the daily judge: the risk it guards is pushing a 31 B provd onto an image without the patch; an image that ships the field went through the firmware build's own gates.
- D2's off-arm threshold is measured from the judged round's **start line**, because that is where `Params.window` counts from.
- D2 leaves by HOME on the node page and returns by launch alone, so no home round runs at the return (the first draft of v4 used Back + HOME and launch + tap, where a fast hinted connect of the short home round could invalidate an on-arm run).
