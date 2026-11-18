# Security review — #329 PR 6 (branch feat/329-pr6, `git diff c4905ed..HEAD`, docs/ excluded)

Scope: app/lib, app/android, app/rust/bridge/src, app/rust/batman-proto/src. Threat actors considered: a compromised
node sending strings, local apps reading the clipboard, a field (DEV_TRUST=false) build exposing developer features.

## Findings

**No findings with confidence ≥ 8.**

## What was checked

- **SSH 金鑰 (dev_pages.dart `SshKeysPage`, api/ssh.rs, owner_console.dart `sshKeys`, owner.rs:817 `request_ssh_keys`).**
  The op goes through the existing owner-signed `owner_op` path (unchanged since c4905ed, owner.rs had `request_ssh_keys`
  already). The page and its settings entry are gated on `devTrust` twice (settings_page.dart `if (devTrust)`, and
  `_send` returns if `!widget.app.devTrust`); `DEV_TRUST` is `false` for the field flavor (android/app/build.gradle:75).
  The node is the authority on line validation (node.go:752/:848); the app's Rust check is an additional, stricter
  client-side filter. The hand-written base64 decoder only feeds a display fingerprint; malformed input returns None.
- **查看節點設定 (owner.rs:676 `settings_text`).** Whitelist of fields 1, 2, 10, 20.1; the passphrase (20.2) is never
  read; every node string goes through `statuspage::shown` -> `invite::display_name` (Cc/Cf incl. U+001E/U+001F and bidi
  -> U+FFFD). A compromised node cannot inject technical-part markers, line breaks or direction marks here.
- **Technical-part markers (say.dart `splitCode`, Rust sentence functions).** Node-sent verbs (`error_text`) and
  countries (`display_name`) are sanitized before being placed in a sentence, so a node cannot open/close a technical
  part to hide main text. Unpaired markers fall back to showing the whole line (fail-visible).
- **Clipboard copies (diag_page.dart `diagCopy`, dev_pages.dart settings/log copy, main.dart startup copy).** Contents:
  app version, flavor, key-ability yes/no names, node technical lists through `NodeLink.mask`, whitelisted settings text,
  in-memory text log (masked). No key material, passphrase, record plaintext or token is copied. The startup copy holds
  full device ids / record file names, which are not secrets and were already shown as selectable text before this PR.
- **Logging.** New `debugPrint` sites pass through `logText` and (startup) `NodeLink.mask`; no secrets are logged.
- **Team page.** Off in every shippable build (`team_enabled()` = `teamview::WRITE_MESH_ADDR`, `team-write` feature is
  tests only); renders Rust-built strings; prints nothing to logs.
- **忘記加入中的節點 / 排除這台.** Dev-only and gated on `devTrust`; the exclude path checks the dacHash is one of this
  phone's own nodes in the decrypted record and hands off to the existing `RemoveConfirmPage` controller; forget writes
  only this phone's record under a session lease via `RecordWriter`.
- **Country restricted to US (owner_console.dart `setCountry`).** Client-side narrowing, fail-closed; no new surface.
- **Kotlin `flavor` method.** Returns `BuildConfig.FLAVOR`, display only.
- **Old console deletion (nodes.dart, node_list.dart).** Removes surface; no gate that the old console enforced was
  found missing from its replacements.

## Candidates dropped

| # | Candidate | Why dropped | Confidence |
|---|-----------|-------------|-----------|
| 1 | 診斷 page (every build, incl. field) copies node technical lists to the clipboard, readable by other local apps | Contents are non-secret diagnostics (versions, yes/no abilities, masked node technical list); no key, passphrase or PII; clipboard is a user-initiated action | 2 |
| 2 | Startup key-check page copies full node device ids / record names (`logText('$_report\n$_tech')`) | Device ids are identifiers, not secrets; already on screen as SelectableText before this PR; user-initiated | 2 |
| 3 | SSH line validation is client-side only; Rust `request_ssh_keys` sends any strings | The node validates (node.go regex); client-side lacking checks is excluded by precedent; op is owner-signed | 2 |
| 4 | Hand-rolled base64 decoder in ssh.rs could mis-decode | Only affects the displayed fingerprint (a user cross-check aid); no security decision rests on it; inputs bounded to 256 bytes; malformed -> None | 2 |
| 5 | Node strings with U+001E/U+001F hiding sentence words (UI spoofing) | Rust sanitizes node text via `display_name`/`shown` (tests T6-4, G MINOR-3, J MINOR-4); Dart-side names come from the user or from records whose names pass `check_name`; impact would be cosmetic | 3 |
| 6 | Text log (`core.log`) copy | Dev-only; masked; in-memory events with last fours only | 2 |
| 7 | Dev pages reachable in field build via direct construction | Entries rendered only under `if (devTrust)`, and each action re-checks `app.devTrust`; no deep link/route registers them | 2 |
