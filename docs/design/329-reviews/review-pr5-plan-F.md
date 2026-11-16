# Review F — #329 PR 5 plan v3 (round 3)

Reviewer F. Focus: security and fail-safe behaviour of the new parts. I reviewed the whole v3 plan (`docs/design/329-pr5-plan.md`, 625 lines) against main 2e18de6 in `C:/src/Batman-329pr5`, read-only. The baseline listed in §0 was used only as a reference.

Verdict: **APPROVE-WITH-CHANGES**. 0 BLOCKER / 1 MAJOR / 8 MINOR.

## Round 1–2 MAJORs: closure check against the source

| Item | Closed? | Evidence |
|---|---|---|
| A-M1 / B-M1 (send-to-node entry) | Yes. 2.7 adds the permanent 「更多」 entry. The send path re-derives everything through info → infoNetId → record, so it does not trust the hint. | nodes.dart:1546-1563 is moved as is; owner.rs:1041 `request_send_update` has no `dev_gate`, so the Dart gate is the only gate, and T-S5 covers it (§6 step 8) |
| A-M2 / C-M1 / D-M3 / C-M2 (permanent entries) | Yes. The 2.9 table covers every member button at nodes.dart:1733-1770. I checked each line: :1735, :1741, :1744, :1745, :1750-1752, :1757-1760, :1763-1766, :1768. 「檢查網路」 (:1737) and 「軟體更新」 (:1769) are not member buttons. | nodes.dart:1733-1770 |
| A-M3 / B-M2 (QR size) | Yes. The decision uses the encoder's own version. Kotlin and Dart both check lengths and shape. | 2.1; QrScanActivity diff in the worktree |
| D-M1 (`update_hint` lost) | Mostly closed. The read path does set `page_info`: status → info → `page_info = Some(b)` at owner.rs:950-965, and `update_hint` is `&self` and pure (owner.rs:1099-1101, rekey.rs:466-499), so a read still never writes. The way it is wired into the prober has the fail-mode gaps in m1 / m2. | prober.dart:122-127 |
| D-M2 (fingerprint / same name) | Closed for the display. A residual collision gap remains in the baseline comparison (m5). | rekey.rs:95; nodes.dart:1324-1338 |

## MAJOR

### M1. The 8.4 list of own nodes can silently leave out the leader's out-of-range nodes, and a removed member keeps access through them

**Scenario.** The leader removes Bob next to the leader's handheld node. Two of the leader's own nodes are relays on a hilltop, out of BLE range. That is the normal field layout: BLE reaches tens of metres and relays are deployed away from the leader. 8.4 opens.

2.7.1 says the own nodes on 8.3 / 8.4 are found like this: "自己的節點用 node/ 紀錄的 device_id 去讀 info，讀回的 dacHash 再對 PersonNode.dacHash … 對不上的節點不列". A relay that cannot be read gives no dacHash, so it is "對不上" and is not listed.

The leader sends to the one node that is listed, sees 「已送出」 on every row, and leaves. Both relays keep the old secrets, and Bob (removed) can still join the mesh through them. Nothing in the app tells the leader:
- The node-page hint (D-M1) appears only after a successful read of that relay. It needs BLE range, which is exactly what is missing.
- The fixed sentence 「沒有送出新密碼的節點，被移除的人仍然連得上」 is generic. A list with no unsent rows reads as "nothing left to send".

The same omission hits an own node whose `node/` record was forgotten in 開發者選項. The record still lists it as the leader's, but the phone can no longer log in to it.

**Evidence.**
- Plan 2.6 item 10 says "列出這個網路裡隊長自己的每台節點". 2.7.1 makes the list depend on live reads. The two are inconsistent, and the 2.7.1 rule is fail-open.
- No Rust entry lists own nodes without a target. `remove_own_nodes` requires exactly one of person / node (rekey.rs:37-43 `target_of`: "a person or a node, not both").
- `net_people` does give the own group's nodes offline: `PersonView.is_self` with `PersonNode.last4`, `dac_hash` and `state` (rekey.rs:47-96). Old `_remove` reads own nodes from the record, and an unreachable node is "不檢查這台", not dropped (nodes.dart:1359-1373).

**Fix.**
- Build 8.4's own-node section from the net record: the `net_people` group with `is_self`, without the excluded nodes. Do not build it from live reads.
- Map each node to `node/<device_id>` by its last 4 characters. If two own nodes share a last4, show both, with no shortcut.
- Every row is always shown, with one of these states:
  - 「已送出」;
  - 「讀不到 — 到它旁邊再按送出」;
  - 「這支手機沒有它的紀錄，送不了」.
- The unsent rows stay visible every time 8.4 is opened from the settings hub (「產生更新包」), so the list can be re-entered after the app restarts.
- Negative control (widget test): one own node's `info` fails → its row is still present and says it was not sent. With the 2.7.1 "對不上的節點不列" rule, the row disappears → FAIL.

## MINOR

### m1. The hint is computed inside the read attempt, and a failure there could change the read's own outcome

Plan 2.3 says the hint is "只讀的顯示，失敗不影響讀取本身的顏色", but the wiring it describes does not guarantee that:
- The answer step runs inside `run(st)`, which is called from the frame handler with `.catchError((e) { … done(failed()); })` (prober.dart:174-177). Any exception from the new `openNet` ends the read as `Res.broken` (or noResponse), not "no hint". The prober's existing `openRecord` pattern is catch → `keyCheck` → rethrow (prober.dart:143-148); copying it does exactly this.
  - A field case is a damaged or undecryptable `net/<id>`. Kotlin `open` returns error `keystore` (MainActivity.kt:136-140). Every read of every node in that network would turn "broken", permanently.
- Opening a record is an async Keystore round trip. It runs after the answer and before `done()`. If the core cuts the attempt in that window (`cancelled`: lease taken, round cut; node_link.dart:362, :448), the read that already succeeded is lost.
- `done()` must not be called before the hint. The probe's cleanup disposes the session right after `result.future` (prober.dart:188-203), so calling `updateHint` after `done()` hits a disposed session.

**Fix.** Say in 2.3:
- Take the `StatusView` first.
- Compute the hint inside its own try/catch, and never call `keyError` from it. `open` failures are not key-level refusals (app_link.dart:204-206), but the plan should say so.
- Bound the hint step with a short timeout, for example 2 s.
- Finish with `done(Outcome(body, v.color, (v, hint)))`. If `cancelled` fires during the hint step, still report the read, without a hint.
- Add to T-P5-H:
  - `openNet` throws → the read outcome and colour are the same as with no record;
  - `openNet` never returns → the read completes after the timeout, without a hint.

  The negative control for each: wire it like `openRecord` → FAIL.

Also keep old `_readStatusPage` semantics: the first of `net/`, `mnet/` that opens wins (`break`, nodes.dart:1165-1174). An unopenable `net/` falls through to `mnet/`.

### m2. Automatic reads now decrypt the full network record each round, in every build

Before: the prober opened only `node/<id>` (prober.dart:143-149). The old console opened `net/` only when the user pressed 狀態頁 (nodes.dart:1153-1177).

After: every round of every node that reports a netId puts the `net/` or `mnet/` plaintext on the Dart heap, and it cannot be zeroed (prober.dart:2-4). That includes mesh secrets and `net_root` (2.4 notes `net_root` is in the mnet plaintext). Rounds also run 6 s after every lease release (node_link.dart:402-429).

The actor is physical capture or a memory dump of an unlocked phone. The exposure window goes from "on demand" to "continuous". In field builds this buys nothing: versions only move through a removal, and removal is dev-gated (rekey.rs:519-526), while T-S5 hides the hint there anyway.

**Fix.**
- Compute the hint only when `devTrust` is set and `NetIndex` lists that netId as a `net` / `mnet` of this phone.
- Optionally memoise the hint per (node id, netId, record generation, info k9) for one round.

### m3. Removal or approval through `OfflineOp` after the page is popped: the outcome is never shown

T-P5-2 makes the write finish after a pop, but neither the plan nor 3.3 says where `done` / `failed(line)` goes. For 8.3 → `startRemove` this is a fail-open belief:
- If the removal fails after the leader backed out (key refusal, CAS, storage), the leader can reasonably believe the removal happened. No 8.4 appears, no hint appears (no version bump), and the removed member keeps full access.
- If it succeeds, the leader never reaches 8.4 in that run.

PR 3 already has a precedent for this case: `lastClaimNote` (app_link.dart:52-53, F41).

**Fix.** Use one of these:
- Block back navigation with PopScope while a removal / approval `OfflineOp` runs. It is local work of a few seconds.
- Or keep the last `OfflineOp` line for those two operations and show it once on the home page, like `lastClaimNote`.

Test: pop during `work`, make `work` fail → the line is shown afterwards.

### m4. `OfflineOp` has no deadline

2.4 drops the 420 s because "沒有藍牙". But `work` awaits platform calls: `signAdmin`, `seal`, `open`, `ecdh`. A Keystore / StrongBox call that never returns holds the session lease for good. Every read and every other operation then answers 「另一個操作還在進行」 until the app is killed. No user authentication is involved (Keys.kt has no `setUserAuthenticationRequired`), so this is not a normal wait.

**Fix.** Add a generous cap, for example 60 s. When it fires, the reply is `failed`, and the lease is released only after `work` returns. Do not release it under a running write, to keep the RecordWriter rule. At the least, the cap gives the user a 「重新開啟 app」 line instead of a silent hang.

### m5. The same-name warning is keyed on the 8-hex-digit fingerprint, so a ground collision hides it

`net_people` computes `same_name` as "same name and different **fpr**" (rekey.rs:95). `fpr` is 32 bits of SHA-256(owner_pub) (rekey.rs:20-23).

A malicious member who runs two identities can grind a second owner key with the same fpr: about 2^32 tries, and point addition makes this hours of work. They also give both the same name. Each identity's join is SAS-checked (approve.rs:54). Then neither group shows 「另有同名的一組」. 8.1 / 8.3 show two identical 「Alice（abcd1234）」 groups, and the "要一起移除得各按一次" sentence never appears.

The plan already rejected fpr as a key for `RemoveTicks` for the same reason (2.5, A-m5 / B-m4), but kept it for this warning. The Rust side is baseline. The fix is in Dart, in the new display.

**Fix.**
- Compute the same-name marker in Dart from `PersonView.owner` (the full key): same `name`, different `owner`.
- When two groups share both name and fpr, show a longer identifier, for example the last 8 hex digits of `owner`.

Widget test: two persons with the same name and fpr but different owners → the warning shows.

### m6. The logging guard cited in §5 does not test logs

§5 says "T-U6 的假秘密搜尋擴到新流程 … 名稱出現在紀錄裡就 FAIL". But T-U6 checks the persisted `ui/state-v1` fields (ui_state_test.dart:146-157; pages_test.dart:241 "never reaches ui/state-v1"). It does not check `debugPrint` / logcat lines.

`NodeLink.mask` only masks hex runs of 8 or more characters and MAC addresses (node_link.dart:77-79). A 6-digit SAS, a member name or a network name in a log line passes through unmasked.

**Fix.** Add a test that captures `debugPrint` across the new flows: `OfflineOp`, the `OwnerConsole` joinreq / info, the prober hint step, `NetIndex` mnets. Run them with a fake name, a fake SAS and fake hex. Any of them in the captured lines → FAIL. Negative control: add one `debugPrint(name)` → FAIL.

### m7. SecureScreen fallback: the claim and the behaviour differ slightly

§5 calls hiding the QR "fail-secure", but on such a phone the only path left is 「複製文字」. The clipboard is the more exposed channel: the IME's history, and on Android 12 `EXTRA_IS_SENSITIVE` has no effect (minSdk 31, build.gradle.kts:39).

This is acceptable under design §8 :874, but the text should not call it fail-secure. Two changes:
- In the fallback, put the clipboard warning line next to 「複製文字」 by default, not only after a copy.
- Keep 「清除剪貼簿」 visible.

The rest checks out:
- `SecureScreen` with `_on == null` renders nothing (secure_screen.dart:42-46), so nothing leaks before Android answers.
- The new `fallback` parameter leaves the Wi-Fi page unchanged.

### m8. The 8.1 「還有 N 位隊員沒交更新包」 line needs a defined "no removal in this run" state

Design :783 shows the line only "如果這次開 app 做過移除". `RemoveTicks` is `netId → Set<owner>` (2.5), which cannot tell these two cases apart:
- there was a removal, and nothing is ticked;
- there was no removal in this run.

Without a marker, either the line shows wrongly after 「產生更新包」 from the hub, or it is missing after a removal where nothing was ticked yet. The second is the fail-open case: the leader is not reminded.

**Fix.** `RemoveTicks` keeps `removedThisRun: Set<netId>`, set on removal success. The line shows when the netId is in that set and `netRecipients` minus ticks is not empty.

## Checked and found sound (no finding)

- **`qrMatrix`**: input `[0-9A-F]{1,4096}` is checked in Dart and again in Kotlin, ECC L, alphanumeric. The version is taken from `QRCode.version`, and Dart checks `size == 17+4v` and the length of `bits`. Kotlin rejects more than 4096 characters → reason sentence plus copy. Alphanumeric v40-L holds 4296, so the 4096-character test vector really yields version 40. The display is fail-safe.
- **Path safety of `openNet(rel)`**: the netId comes from the node, but `status_view_of` only emits it as `hex_lower` of exactly 16 bytes (owner.rs:2260). A malicious node cannot steer the phone into opening `node/…` or `../`.
- **Malicious node lying about k9 / k10**: it can only hide or show the hint. A node that is already compromised loses nothing more, and the send path re-checks in Rust.
- **Clipboard swap by a local app** (writing the clipboard before a paste):
  - a swapped invite gives a SAS the leader never sees, and 7.4 refuses a request for another network;
  - an approval is bound to the member's pending ECDH and SAS;
  - an update bundle is admin-signed.

  The baseline protocol covers each one. On minSdk 31, background apps cannot read the clipboard.
- **Joinreq owner key spoofing**: the request is verified under its own `owner_pub` (approve.rs:53-54). A member therefore cannot show up inside the leader's 「我（隊長）」 group.
- **Paste cap**: 300 000 characters covers the 262 144 needed for 128 KiB of hex. Rust stays the parser.
- **z / ECDH**: `_ownCopy`, then zeroed in `finally`. Kotlin `ecdh` uses `keyCall(wipe = true)` (MainActivity.kt:135). The Kotlin `EcdhPeer.accept(devTrust)` gate is unchanged.
- **Gates**:
  - the settings hub is devTrust only;
  - the 「更多」 send entry is Dart-only gated, and that is the only gate (owner.rs:1041), so T-S5 must cover it. The plan already says so.

## Negative controls I require (summary)

| Finding | Negative control |
|---|---|
| M1 | Own node unreachable at 8.4 → row present with 「讀不到」. With the "對不上的不列" rule → FAIL. |
| m1 | `openNet` throws / hangs → read colour unchanged. Wired like `openRecord` → FAIL. |
| m3 | Pop and then failure → line shown later. Without it → FAIL. |
| m5 | Same name and same fpr, different owner → warning shown. With the fpr-based rule → FAIL. |
| m6 | Captured `debugPrint` contains a fake name or SAS → FAIL. |
| m8 | Removal with zero ticks → line shown. With no removal-this-run marker → FAIL. |

## Verdict

**APPROVE-WITH-CHANGES.** M1 must be fixed in the plan before implementation: the 8.4 own-node list must come from the record, and unsent or unreachable nodes must stay visible. The MINORs can be folded into v4 without another full round, provided each gets the stated test.
