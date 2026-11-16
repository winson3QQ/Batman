# Review X — #329 PR 5 plan v12 (round 12)

Reviewer X. Focus: security and fail-safe behaviour of the new parts (R17, R14, Rust version fields, R6–R9, R10–R12, R1–R4, R15/R16, logging). Central question: can a removed member keep access unnoticed, on the leader side or the member side?

Source checked read-only in `C:/src/Batman-329pr5` (main 2e18de6 plus the working-tree QrScanActivity change). The baseline (§0) is not re-reviewed.

## Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 8 MINOR

## Appendix A MAJORs I re-checked against source

- **U-M1 (confirm on the hint card)**: closed by R17. The old status-page button `_sendFromPage` → `_sendUpdateFor(r.$1, member: r.$2)` used the default `confirm = true` (nodes.dart:1138-1143, :1567-1572). The dialog applies only when `!member`, and R17 step 2 matches that.
- **T-M2 (NetRun `[UPDATED] ` prefix)**: the current code still has `if (!u.starts('[UPDATED] '))` (net_run.dart:300-301), so the fix is needed. The `rekeyEnd` fix in R14 is correct against `update_text` (bridge rekey.rs:430-458) and against `on_after` (updflow.rs:313-325), where `Applying` comes from `save_pending: true` before any k9 comparison.
- **V-M1 (versions)**: closed for the leader (`NetView.version`, shown on 8.1 and 8.4). **Only half closed for the member**: `MnetView.version` is added but never shown. See X-M1.
- **E-M1 / G-M1 / H-M1 (hint shown, hint computed before dispose)**: the R7 order is consistent with prober.dart:69-83 and :188-205. The cleanup and `dispose` run only after `await result.future`, and the cancel handler at :83 is the one R7 changes.
- **L-M1 / J-M1 / T-M1**: R14 only ticks `current`, and the member side never ticks. Verified against updflow.rs:256-258 (`AlreadyCurrent` = node k9 == phone record version) and mupdate.rs:263-299 (an old genuine bundle is accepted).
- The other MAJORs (A-M*, C-M*, D-M2, F-M1, I-M1, K-M1, M-M1, O-M1/P-M2, Q-M1, R-M1): I found nothing that reopens them. The §2.12 map against nodes.dart:1733-1770 is complete. The old main-page 「把新密碼送給節點」 (:1745) is not dev-gated in the old console, but D9 makes it devTrust-only, which is justified: the Rust rekey and import functions all call `dev_gate()` (rekey.rs:110, 154, 255, 268, 313, 335, 397, 411).

## Central question

**Leader side.** Can a removed member keep access through one of the leader's own nodes without the leader noticing?
- 8.4 lists every own node from `netPeople`, unreachable ones included.
- The success signal is anchored (`current` only).
- `expectDac` fails closed (`node_dac_hash()` is "" when the node is not verified, owner.rs:1032-1035).
- An excluded or captured own node is refused by Rust: `NotListed` (updflow.rs:166-169), and its hint is `NOT_LISTED` with no button (rekey.rs:488-490).
- A compromised node naming another network in info k10 only gets that network's secrets if it is listed there (updflow.rs:166).

I found no unnoticed path on the leader's own nodes. The leader has no signal at all about the **remaining members' nodes**. That is baseline (T15), but the leader's fixed text does not say so (X-m5).

**Member side.** The one real hole is X-M1. A member who later sends from the hint card or from 「更多」 has nothing to read to the leader, so the T-M1 check (an old, genuinely signed bundle forwarded by a malicious member) cannot be done on the path the Rust import text itself sends the member down.

## MAJOR

### X-M1 — On the member side, the version that T-M1 relies on is only visible on the import screen; on the normal send path the member cannot verify it

**Scenario**
1. The leader removes person R. The network goes to version 6.
2. A malicious remaining member forwards to member M an old bundle for version 5 that the leader really signed and M has not used.
3. M pastes it on 8.5. `prepare` returns `Advance { to: 5 }` and shows 「更新到第 5 版」. The leader is not reachable right then, so nothing is read aloud.
4. The Rust import detail tells M to wait: 「等隊長說大家都拿到更新包了，再到狀態頁按「把新密碼送給節點」」 (rekey.rs:421).
5. Later, M sends from the node page's hint card or from 「更多」 (R17). The node answers `Updated` or `AlreadyCurrent` at version 5, because that only compares with the phone's mnet version (updflow.rs:256-258).
6. `RekeyResult(member: true)` shows `kMemberRekeyRule`: 「請把匯入時畫面上的那一句…唸給隊長聽」. That sentence is no longer on any screen.
7. If M pastes again, the answer is `AlreadyImported` 「已經匯入過」, which has no version (rekey.rs:401-402). The `AddSecrets` path also has no version (rekey.rs:400).

So nothing in the app can tell M which version the phone holds. M's node stays on version 5, which R knows, and the leader is never told.

**Evidence**
- `MnetView.version` is defined in §0 (:41) and §3.2 (:534), but no page displays it. A grep for `MnetView.version` finds only those two lines.
- The member's normal path is the deferred send. The plan's own 8.5 text ties the version check to the prepare sentence only (:362).

**Fix**
- Show 「這支手機是第 {MnetView.version} 版」 inside `RekeyResult(member: true)` and on 8.5, including the `AlreadyImported` and `AddSecrets` branches.
- Change `kMemberRekeyRule` to: 「把這一行的版本唸給隊長，和他畫面上的『目前是第 N 版』對照」.
- Test: a member result from the hint card shows the version line. Negative control: without the line, the test fails.
- Add a Rust test pinning that `MnetView.version` after an import equals the `to` in 「更新到第 {to} 版」 and equals the leader's `NetView.version` for the same bundle (see X-m4).

## MINOR

### X-m1 — R17 `expectDac` with a last-4 collision: "try each in turn" is undefined

8.4 says candidates are tried one after another when the last four digits collide. R17 step 1 says a mismatch shows 「這台的身分和網路紀錄不符」 and stops. The plan does not say whether the loop is automatic or left to the user. If it is left to the user, the first wrong candidate shows an alarming error and the leader may stop, leaving that node on the old key. Each attempt also costs two logins and possibly a second confirm dialog.

Fix:
- Loop automatically over the candidates inside `sendNewKey`, with step 1 only and no dialog.
- Show the mismatch line only when no candidate matches.
- Ask for confirmation once, after the match.

### X-m2 — R16 member-mode NetRun must pass `member: true`

`OwnerConsole.sendUpdateFor(rel, {bool member = false})` (owner_console.dart:507). The current NetRun call is `c.sendUpdateFor(rel)` (net_run.dart:300). R16 says only 「照 R17 的 NetRun 那一條送出」.

If `rel` is `mnet/…` and `member` stays false, Rust decodes an mnet as a net record and returns a `Record` failure. That fails closed and is visible, but the member's node never gets the new secrets.

Fix: derive `member` from the record kind in one place, and add a test (member-mode join → `sendUpdate` → the request has `member: true`; negative control: the default value → FAIL).

### X-m3 — The R17 and R14 source-check allowlists disagree

R17 says 「`sendUpdateFor` 只能出現在 `sendNewKey` 與 `NetRun` 裡」. R14 adds the nodes.dart exception. Neither names the definition site, owner_console.dart:507. If implemented literally, the R17 check fails on its own definition and on the old console, or else it gets loosened ad hoc.

Fix: state one allowlist in R17, namely definition + `sendNewKey` + `NetRun` + the nodes.dart exception until PR 6, and have R14 reference it.

### X-m4 — Pin what number `NetView.version` and `MnetView.version` are

The leader compares the member's spoken number against 「目前是第 N 版」. That only works if three numbers are the same counter:
- `NetView.version`, which should be `netcfg().version`, the value `update_hint_of` uses (rekey.rs:494);
- `MnetView.version`, which should be `MNet.version` (rekey.rs:476);
- `Prepared::Advance.to`.

The plan only says 「網路目前的版本號」.

Fix: name the source fields, and add one Rust test that builds a rekey, generates a bundle, imports it, and asserts all three are equal.

### X-m5 — The leader's fixed text does not say that remaining members' nodes are invisible to the app

`kRekeyDoneRule` and the 8.1 fixed line cover the leader's own nodes and handing out bundles. A remaining member who imports but never sends leaves their node on the old key, so R can still reach that node's part of the mesh, and nothing on the leader's side shows it. This is baseline (T15 / D5), so no mechanism is asked for.

Fix: one sentence in the 8.1 fixed line or in `kRekeyDoneRule`: 「每位隊員也要把新密碼送到他自己的節點；app 看不到他們送了沒，請當面確認」.

### X-m6 — R3: say whether `CodeView` shows the hex as text

R3 wraps the QR and the SAS in `SecureScreen`. If `CodeView` also renders the hex as text (for example a preview or a selectable field), that text sits outside the secure subtree. The approval code carries the member list and node names, which is the privacy reason R3 gives.

Fix: either state that `CodeView` never renders the code text, or put the whole `CodeView` inside the `SecureScreen`. Extend T-S1 to cover it.

### X-m7 — NetRun `applying` row uses the success state

R14: an `applying` row stays 「已加入」 with a note. If it reuses `RowState.ok`, a leader's run where every row is green can hide a node whose new secrets never finished applying. The only later signal is the hint card, which appears only while that node page is open (R6).

Fix: give the row a distinct neutral or warning state, or make the run summary count it as 「待確認」.

### X-m8 — R8: a successful read with no k9 clears the hint

`update_hint_of` returns none when k9 is missing (rekey.rs:466-473, `behind` needs `is_some`). Under R8 a `Res.body` round with an empty hint clears the card. R9 makes the hint non-authoritative, so this is not a MAJOR. Still, a node that briefly omits k9 (for example while a save is pending) makes the 「還在舊密碼」 card vanish.

Fix: optional. Keep the old value when the info read had no k9, or document this in R8 together with R9.

## Other checks (no finding)

**R12 / R10**
- The revoke → `RecordWriter` refusal path holds: `_check` compares the lease with `reg.current` (record_writer.dart:27-33), and `_revoke` sets `_ended` and releases (lease.dart:140-149).
- A write that started before the revoke can still land, and the R12 re-read table handles that case.
- signAdmin needs no user authentication: there is no `setUserAuthenticationRequired` or `BiometricPrompt` in the Kotlin sources, so the 60 s cap cannot be triggered by a slow biometric prompt.

**Clipboard and secrets**
- The update bundle is sealed to the member phone's key (`NotForThisPhone` / `Aead`, rekey.rs:337-352; mupdate.rs:263-268), so a clipboard leak does not expose secrets.
- Codes stay non-secret, as stated.

**Logging**
- `RecordWriter` logs `rel`, which includes net ids and device ids. That is not a secret, but T-P5-L's allowlist should expect it.
- The prober's `$e` catch-alls (prober.dart:164, :174, :184) are bypassed on the hint path by the local catch, as R7 requires.

**Gates**
- `main.dart:104-107` reads the flavor's devTrust and checks it against the Rust build. `AppLink.devTrust` is injected from there.
- `request_send_update` has no `dev_gate`. A field phone only ever holds version-1 records, so a send ends as `AlreadyCurrent`, which is harmless.
