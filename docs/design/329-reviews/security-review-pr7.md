# #329 PR 7 — security review (3020374..6d763d8, excluding docs/)

Scope: Kotlin app/android, Rust app/rust, Flutter app/lib (plus app/tool/device_contrast.dart, app/device_check).
I read the code without running it. Nothing was run on a phone or emulator.

## Result

**No findings with confidence ≥ 8.** (HIGH 0 / MEDIUM 0 / LOW 0)

## Areas reviewed and conclusions

- **Kotlin `open` gate (KeyHandlers.kt / Keys.kt / MainActivity.kt / KeyPolicy.kt).** Before this change, the `open`
  channel called the public `Keys.open` with no gate. Now `Keys.open` is private and reached only through
  `KeyHandlers.open` → `use(KeyOp.OPEN, …)`. That path checks the live RECORD_AES level with `KeyPolicy.refused`,
  which fails closed on a null, unknown or missing level. This is a strict tightening. Reading only RECORD_AES's
  level, and not all four keys, matches what `open` touches (only the record AES key). It does not widen access,
  because before the change no level was checked at all.
- **Plaintext wipe (KeyAnswer.deliver).** The plaintext is zeroed after `result.success` returns, so the codec has
  already encoded it. There is no use-after-zero hazard, because the bytes are serialized synchronously inside
  `success`. The code comment correctly says this is not a full erase.
- **Error detail.** `keystore` errors pass `ExceptionClass: message` into the channel's error. For `open`, the
  messages are argument-presence strings ("no record" / "no aad") or Keystore and Cipher exception text. They carry
  no key material or plaintext.
- **Rust `store_has_records` tri-state (simple.rs).** An unreadable kind folder or entry now returns `Err`, not
  `false`. `main.dart` `_install` catches it, sets `_recordsUnread`, and returns before `firstRun`, so no key is
  regenerated. The app then stays off. The change closes a fail-open path, in which a key would have been
  regenerated over records the app could not see. The error string contains the kind name and the io error only.
- **BLE address under 技術資訊 (claim.dart S10).** BLE addresses are broadcast over the air and are not secret.
  Showing them, or copying them through 「複製文字」, exposes no PII or secret.
- **Node-provided strings in the UI.** The strings go into Flutter `Text` / `SelectableText`, which has no
  markup or HTML sink, so there is no injection.
- **scan.dart lease hold, core.dart roundsEnded, T19 removal of the unreachable lease path in main.dart `_open`.**
  These are concurrency and UX changes. They add no authorization boundary and remove none: the removed path is
  documented as unreachable, because `_app == null` whenever that page shows.
- **app/tool/device_contrast.dart.** This is a host-side CLI. It reads two files whose paths come from CLI
  arguments (trusted by precedent), runs no process and makes no shell call. The XML and PNG parsing is
  memory-safe Dart. Malformed input can only crash the tool, which is excluded as DoS.

## Dropped candidates

| # | Candidate | Reason dropped | Conf. |
|---|-----------|----------------|-------|
| 1 | `open` checks only RECORD_AES and ignores the other key levels | The other keys are not used by `open`. Before the change there was no gate at all, so this is not a regression and does not bypass anything. | 1 |
| 2 | The wipe leaves copies (codec buffer, Cipher internals, Dart side) | Defense-in-depth or hardening, already stated in the code; excluded ("lack of hardening"). | 2 |
| 3 | `_log('found $id')` / BLE address in tech text and clipboard | The BLE address is public broadcast data, not a secret or PII under the precedents. | 2 |
| 4 | `store_has_records` error text includes the io error and kind name | Contains no secret or PII; it appears only in the local tech area. | 1 |
| 5 | device_contrast `double.parse` / parser on untrusted input | Host tool, CLI-trusted input, only a crash or DoS possible; excluded. | 1 |
| 6 | Startup race between `storeHasRecords` and `firstRun` (records appearing between the check and generation) | Theoretical race; excluded. The single-process startup also makes it implausible. | 2 |
