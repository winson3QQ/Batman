# #254 — a network change that did not succeed goes back to the previous state; `network/leave` forgets the mesh (design v7, 2026-10-30)

Status: v7 for review. v1–v3 REJECTED; v4: A REJECT (model sound), B APPROVE-WITH-CHANGES; v5 and v6: both
APPROVE-WITH-CHANGES (one MAJOR each in round 6, both one-line contract fixes, §13). §10 round 4, §12 round 5, §13 round 6. **Owner rule: a change that did not succeed returns the node to the previous state — "use the previous
one".** Owner decisions: L22 → A (leave = forget the network); legacy / operator-keyed node whose join fails → back to
the operator's own settings (2026-10-30). Product change: helper, `halow-setkey`, `batman-config-save`. Branch
`feat/254-p1b-seams`.

## 1. The bug (reproduced on 04 wsl.9; same on `origin/main` 5914f03)
Power loss during `net.apply` leaves `/etc/batman-prov/.txn`; the shipped restore persists through `config-save --save`,
which refuses while `.txn` exists (`batman-config-save:163`); `.txn` is removed only on success (`main.go:492-507`) →
it stays and **every later save is refused** (04 crash boots 4237a6ae / c38cc548; `txnstuck.sh`). Also: a fresh card's
previous key is the placeholder (`halow-setkey:64` refuses it); generation matching is fooled by another verb's commit
(reviewer B probe); `network/leave` keeps the key (`node.go:710-724`).

## 2. "The previous state"
| the committed record (resolved from p5, §3) | previous / desired mesh wireless |
|---|---|
| member (has a Net) | that network: mesh id, channel, key — **decoded from the record without re-verifying signatures** (it was verified when accepted and lives in root-only `/etc/batman-prov` 0700; re-verifying fails after an admin handover, review A-B1 / B-M3, `node.go:1095` + 219 §7.1) |
| left (`Left = true`, set by a successful leave) | forgotten: placeholder key, radio blocked (keyguard), mesh markers removed |
| anything else (legacy, legacy-claimed, claimed never joined, unclaimed) | **the snapshot taken at the start of this change** (`.txn` holds it: key, mesh id, channel, uci `disabled` of the morse radio). Placeholder key → restored with `--forget-mesh`. A real key → restored as key / id / channel; the radio's `disabled` is never written by a restore — a change cannot start on a radio switched off by hand (§4.2 pre-check), and `halow-setkey` releases only radios in the keyguard mark (`:95-107`), so it is unchanged; Finish checks it and, if it changed (an operator switched the radio by hand meanwhile), logs CRIT
and **continues** — the operator's choice stands, `.txn` does not stay for it (review A r7 m1). The snapshot's
`disabled` value is kept for that check and the log only; nothing ever restores it (review A r7 m2; A r6 M1, B r6 m2). "Blocked" for the placeholder case = the keyguard mark lists the morse radio (`halow-keyguard:22-27`), never just uci `disabled` |
Implementation of "decoded without re-verifying": the `cose` package has only `VerifySign1` (`cose/cose.go:36`); add
`cose.Sign1Payload(item)` (parse the COSE_Sign1 structure, return the payload, no signature check) used ONLY on the
stored record; the secrets are then decrypted exactly as today (`cose.Decrypt` with the DAC ECDH, `node.go:905`), which
does not depend on the signer set. Verbs that accept new objects keep `VerifySign1`.
The same decode-without-re-verify is used at the two other places that re-read the STORED network objects and break
after an admin handover today (review B r5 MAJOR-3, A r5 m7): `netUpdate`'s check of the stored net_config
(`node.go:1053-1057`, needs the object hash too) and `netRoot` / `psks.get` (`node.go:873`, `:368`).
`Left` canonical form: absent = false; key 12 present must be `true` and requires `State == claimed` and `Net == nil` —
anything else is a decode error (`unknown(prov-corrupt)`), so a corrupt record cannot make Finish forget a live network
(review A r6 m3). `Left` is a new record field, **encoded only when true** (key 12 present only on a left record; the new decoder accepts
11 or 12 keys). Reason: older images' `provstore.Decode` demands exactly 11 keys (`provstore.go:110`, same on
`origin/main`) — writing it always would make every rollback freeze the node (review A/B r5 MAJOR-1). A LEFT node rolled
back to an older image is read as `unknown(prov-corrupt)` (verbs refused) — fail-closed, its mesh is already forgotten;
it recovers by rolling forward (stated; §8). `RadioManaged` keeps its
meaning and is not used to choose the previous state (a fresh-card claim sets it true while a factory key is live —
review B-M2b).

## 3. Mechanism
- **`.txn`** (root 0600, dir 0700) = "a mesh wireless change is unfinished" + the snapshot of the live wireless taken
  before it (empty fields `-`). Written at the start of `net.apply` and `network/leave`; while it exists `config-save`
  refuses saves (unchanged). An old-format `.txn` (shipped) is read as "unfinished" with its prev fields as the snapshot
  when parsable, else no snapshot (§3 Finish then refuses to guess: CRIT, `.txn` kept).
- **Record resolution**: as today's `boot.Run` (p5 vs overlay) **minus its `.txn` generation branch** (`boot.go:105-131`
  removed; nothing infers "committed" from generations). A side-effect-free `Resolve()` is factored out for runtime use.
  **Finish runs only when p5 was actually read** (rc 0 or a parsed meta); p5 unreadable → `.txn` kept, Finish retried at
  the next boot (review B-M1 probe `TestProbeV4P5Flap`, A-M2).
- **Finish** (Node, under `n.mu`): **write the run-dir marker with `.txn`'s token** (after a reboot the tmpfs marker is
  gone and the daemon removes stale ones at start, `main.go:450-453`; without it `--save --txn` is refused and the
  original bug returns — review A/B r5 MAJOR-2) → if `Resolve()` picked p5 over a stale overlay, rewrite the overlay
  from p5 as boot does (`boot.go:177`; review A r5 m2 / B r5 m8) → previous/desired per §2 → apply it unless already live (compare `CurrentWireless` +
  keyguard state; the success path of a verb never re-applies — review A-m1 / B-7) → left/forgotten: `RemoveMeshMarkers`
  → **`config-save --save --txn <token>`** (accepted while this `.txn`/marker hold the same token, as `--prov-only`
  already does — so the save lands BEFORE `.txn` goes; review A-M5 / B-6; rc 0 or 6 = done — rc 6 = a live value that
  cannot be persisted, accepted as `applyNet` does, `node.go:1127`) → RemoveTxn → ClearTxnMarker → rewrite prov-state
  (mesh_expect follows the new state — review A-m3). The verb that called Finish reloads its record afterwards.
  **The marker is cleared on every exit of Finish** (defer, as `applyNet` does, `node.go:1103`); only `.txn` stays on a
  failure — a leftover marker would make `config-save --prov-only` refuse the commit-only verbs (`config-save:171-172`;
  review B r6 MAJOR-1).
- **Apply**: member → `halow-setkey --mesh - --mesh-id … --channel … --no-persist` (key on stdin); forgotten or a
  placeholder / blocked snapshot → `halow-setkey --forget-mesh --no-persist`; other snapshot → `--mesh -` with its values.

## 4. When Finish runs
1. **Every state-changing verb that saves or changes the wireless** (`net.apply`, `network.leave`, `ssh_keys.set`,
   `root_password.reset`, `claim.replay`, `settings.set` — chosen in the dispatcher by verb class, not a free-text list;
   review B-8): if `.txn` exists, Finish first, then the verb as today. Commit-only verbs (`owner.add`, `owner.remove`)
   do not Finish (no wireless step): with no generation inference their commit cannot be mistaken for the wireless change
   (review A r5 m5), so an owner can always remove a co-owner, even with a dead radio (review A-M4). They DO run
   `Resolve()` + the overlay rebuild first (no wireless), so they never commit on a stale overlay over a committed join
   (review A r6 m1).
   - A retried join / update / leave after a commit whose reply was lost finds the node finished and gets today's answer.
     The app decides "already done" from `info.state`, which gains `net_id`, `version` and `left` — **returned only in an
     owner-authenticated session** (a stable `net_id` to any BLE peer would link a fleet, against the rotating member
     advertisement; review A r6 m4, B r6 m3) — an error code alone is ambiguous (`EStaleVersion` also means "another
     network", `node.go:996`; review A r5 m3, B r5 m7). A retried leave that finds `left` = true is done.
   - Finish fails (e.g. a dead HaLow module): the saving verbs above return `EState` "an earlier network change could
     not be finished (radio)" — stated.
   - A leave whose commit landed but whose forget failed returns `EApply` "left the network; the radio still has the old
     settings — retry" (the app must not show "left" as complete; review A r5 m4).
2. **The wireless verbs' own steps**: pre-check — `net.apply` on a node whose morse radio is switched off by hand
   (uci `disabled=1` and NOT in the keyguard mark) is refused before anything changes: `EApply` "the HaLow radio is
   switched off on this node" (the change could never be verified, and its undo would fail the same way — review A r6
   M1) → `.txn` (snapshot) + marker → live change (`--no-persist`) → commit (`commitTxn` with
   the token) → Finish (nothing to re-apply) . A failure before / during the commit → Finish (= back to the previous
   state if the commit did not land, forward if it did — decided by `Resolve()`, p5 read). `halow-setkey` rc 2 (nothing
   changed) → RemoveTxn + ClearTxnMarker only (review B-M2 fix 1).
3. **Boot / helper start with `.txn`**: wait for the mesh radio (`meshjoin_radio_up`) or 120 s — not when the previous
   state is forgotten / blocked — then Finish, then serve (≈ 5 min worst case before serving, only after an unfinished
   change; accepted by both reviewers). Finish fails → serve; `.txn` kept; CRIT.
- `halow-status`: "unfinished network change" from `.txn` presence (root); non-root → "unknown" (B-10).
- `--boot` mode does not Finish (no caller).

## 5. `network/leave` (L22)
`.txn` (snapshot) → commit (claimed, `Left = true`, no Net / Members / Admins; token) → Finish (forget: placeholder,
radio blocked, markers removed, saved to p5). Power loss anywhere → boot Finish: before the commit the record is still
member → that network; after → forgotten. Re-join = `net.apply` (clears `Left`; `halow-setkey` releases the keyguard
block, `:95-107`). After a leave: `MeshExpect` = `0`. **Not a secure erase**: p5 `lkg` (rotated only by `--seed /
--if-healthy / --on-join`, `config-save:542-544`) and the other slot's overlay keep the old key; resale = reflash
(`254-stage1-impl.md:283`).

## 6. `halow-setkey` and chanfix
- `flock` (`$RUNDIR/halow-setkey.lock`, `/usr/bin/flock` present on 04) for every write mode; ≤ 90 s → rc 2 busy;
  `$RUNDIR` unusable → rc 2 (fail closed).
- `99-batman-chanfix` takes the lock per reassert, not for its whole loop; busy / unusable → reassert anyway (fail open:
  chanfix runs only on a fresh slot's first boot, a trial, when no helper change runs — `node.go:170` EBusy on trials;
  skipping would strand the slot on ch42, `99-batman-chanfix:4-16`).
- `--forget-mesh` (no key; mesh id / channel unchanged): stage the keyguard block (radio `disabled=1`, merge into
  `/etc/halow-keyguard.blocked`) and the placeholder key, ONE `uci commit wireless`, `wifi reload`; verified `wlh0` gone
  and ubus `up=false disabled=true` for the morse radio (`morse_radio()`, as setkey already finds it — not a hard-coded
  `radio1`, review A r5 m8) within 30 s → rc 0, else rc 3. Evidence (04 2026-10-30, `radiooff.sh`): both
  within 2 s; `morse0` and `phy1-ap0` (other radio) stay. `--mesh CHANGE-ME-NOW` stays refused.
- On a node whose record is member or left, a later Finish puts the record's state back over a hand-made change
  (stated; review A-m2).

## 7. `batman-config-save`
- `--save --txn <token>`: allowed while the marker and `.txn` carry that token (the marker is rewritten by Finish, §3; same check as `--prov-only`,
  `:169-170`); without it, saves keep yielding while `.txn` exists.
- `--save` / `--if-healthy` / `--on-join`: compare the txn sequence (marker token + `.txn` presence/token) before
  staging and before the p5 write; changed → abort ("next tick").

## 8. Lifecycle
| path | after | test |
|---|---|---|
| no `.txn` | unchanged | regular suite |
| power loss mid update (member) | Finish → the record's network | powerloss txn-1..5 (node), Go |
| power loss mid join, legacy / operator key (04's S0) | Finish → snapshot (operator's settings) | **new prov-powerloss-legacyjoin-254** (node: from S0 legacy claim → join killed at txn-2 → operator mesh back, p5 = operator values, AND `.txn` gone, `--check` fresh, a later `--save` rc 0 — the three that the shipped code fails; mutant "always forget" proves the snapshot rule — review B r5 m5), Go |
| power loss mid join, fresh / left node (placeholder) | snapshot placeholder → forgotten | **prov-powerloss-rejoin-254** (node: claim → join → leave → join killed at txn-2). Negative control: the helper's init is disabled before the killpoint (an overlay change the S0 restore undoes), the mutant `helper-noforget` is bound after the reboot (sha checked), then the helper started — this exercises "helper start with `.txn`", the same Finish (review B r5 m4); also the shipped image (its leave keeps the key), Go |
| older image reads a v6 record (rollback / other slot) | records without `Left` read as today; a LEFT record → `unknown(prov-corrupt)`, recovers by rolling forward | prov-downgrade-254 extended both ways; Go (old-Decode fixture — review A/B r5 MAJOR-1) |
| admin handover, then `network/update` / `psks.get` | stored objects decoded without re-verify | Go (rotating chain with secrets signed by the previous admins — review A r5 m6, B r5 MAJOR-3) |
| power loss mid leave | before commit → network; after → forgotten | Go killpoints; prov-leave-ota-254 (node) |
| commit landed, reply lost, app retries | Finish first, retry answered "already" | Go |
| another verb commits while `.txn` exists | saving verbs Finish first; commit-only verbs Resolve + rebuild the overlay, no Finish; Finish uses the current record either way | Go (reviewer B's collision probe on a saving verb and on owner.add as negative controls) |
| Finish fails (dead radio), then `owner.remove` | marker cleared on Finish's exit → the commit succeeds | shell / node (stub setkey rc 3; without the defer → EStorage) |
| join on a radio switched off by hand | refused up front (`EApply`), nothing changed | Go + shell (setkey with the radio off returns rc 3 — the premise) |
| commit landed in p5, overlay write failed, p5 flaps, then owner.add | Resolve + rebuild before the commit | Go killpoint |
| p5 unreadable at boot / after a commit | `.txn` kept, retried next boot | Go (`TestProbeV4P5Flap` as negative control) |
| admin handover, then reboot with `.txn` | decode without re-verify → Finish ok | Go (rotating chain; today's `parseNet` fails it) |
| dead HaLow (Finish always fails) | owner.add/remove work; saving verbs `EState` | Go |
| setkey rc 2 | `.txn` removed, nothing else | Go |
| power loss between Save and RemoveTxn | `.txn` → Finish again (idempotent), p5 already saved | Go |
| T8 shipped stuck slot | the fixed image goes to the other slot (`.txn` is per slot). Runbook: real previous key → `rm .txn` + `--save` on the old image; fresh card (restore was refused) → the app re-pushes the network (never `rm` + `--save`); verdict `unknown(txn-generation)` → `rm .txn`, restart the helper, then the app re-pushes | stated |
| downgrade / crash loop / clean stop | old behaviour in that slot / re-read `.txn` at the next start | Go |
| platforms | Pi 4 (04); Pi 3A+ unsupported (owner decision 2026-10-23) | — |

## 9. Security
Key: decoded from the root-only record into `halow-setkey`'s stdin, or from the root-only `.txn` snapshot (the shipped
`.txn` already holds the previous key); never on argv or in logs (rc and key names only). Skipping the signature check
on the stored record is safe: only the helper writes it (0700), after verifying; `Sign1Payload` skips the signature of
the stored net_config AND net_secrets, while the secrets' DAC-target check and net_id / version binding stay
(`node.go:890-905`); physical access to p5 / the rootfs could always rewrite the record (not encrypted) — no change in
exposure (review A r5 m6); a local unprivileged process cannot
write it or `.txn`, the marker (`-O`), or the flock file. Remote (BLE): only owner-signed verbs change anything; no new
verb. The placeholder is never committed with the radio enabled (`--forget-mesh`, one commit). Fail mode: Finish fails →
saves stay blocked (the live values may be wrong), commit-only owner verbs still work, CRIT + `halow-status`.

## 10. Round-4 findings → v5
A-B1 / B-M3 admin handover → §2 decode without re-verify · A-M1 / B-M2a legacy join → §2 snapshot (owner decision) ·
B-M2b factory-keyed claimed node → §2 `Left` flag instead of RadioManaged · B-M1 / A-M2 p5 unread → §3 Finish only after
a p5 read; `Resolve()`; generation branch removed · A-M3 retries refused → §4.1 Finish first + "already" = success ·
A-M4 dead radio lockout → §4.1 commit-only verbs proceed · A-M5 / B-6 RemoveTxn-before-Save window → §3 `--save --txn`
before RemoveTxn · B-M4 T8 runbook → §8 · A-m1 / B-7 double setkey → §3 no re-apply when live · A-m2 hand-made changes
→ §6 stated · A-m3 prov-state → §3 · A-m4 / B-10 chanfix → §6 · B-5 boot.Run change stated → §3 · B-8 structural →
§4.1 · B-9 mutant scope → §8 · B-10 halow-status non-root → §4 · B-M2 rc 2 → §4.2 · A-m5 app timeout → P2 note.

## 11. Tests (negative control = the same test on the shipped code)
Go (release build): every §8 Go row. Shell: `--forget-mesh` (stub iw/ubus/uci; one commit; never placeholder + enabled;
keyguard mark merged), flock, chanfix lock, config-save `--save --txn` and the sequence check. Node (regular suite):
powerloss txn-1..5 (assert the Finish line, `.txn` gone, live mesh id / channel = record, `--check` fresh, saves work),
**prov-powerloss-legacyjoin-254**, **prov-powerloss-rejoin-254** (+ mutant), prov-leave-ota-254 (`mesh_expect=0`, p5
holds the placeholder). Side effects listed in each unit (04 off the mesh; 02 unreachable through 04 while forgotten).

## 12. Round-5 findings → v6
A/B r5 MAJOR-1 `Left` breaks older readers → §2 key 12 only when true; §8 row · A/B r5 MAJOR-2 no marker at boot → §3
Finish writes the marker from `.txn`; save rc 0/6 · B r5 MAJOR-3 / A r5 m7 handover breaks `netUpdate` and `psks.get` →
§2 same decode at both sites · A r5 m1 / B r5 m6 operator radio off by hand → §2 restore key + `disabled` as it was ·
A r5 m2 / B r5 m8 overlay stale after p5 picked → §3 rebuild overlay, verb reloads · A r5 m3 / B r5 m7 app "already" →
§4.1 `info.state` net_id / version / left · A r5 m4 leave forget failed → §4.1 `EApply` · A r5 m5 commit-only verbs →
§4.1 no Finish · A r5 m6 Sign1Payload wording → §9 · A r5 m8 radio name → §6 · B r5 m4 rejoin mutant scope → §8 ·
B r5 m5 legacyjoin discriminators → §8. Recorded in #254 (pre-existing, fixed here): the handover failure of
`network/update` and `psks.get` exists on `origin/main` today.

## 13. Round-6 findings → v7 (round 7: A APPROVE; its two MINOR wording fixes applied in §2)
A r6 M1 join on a radio switched off by hand → §4.2 refused up front; §2 `disabled` never written by a restore ·
B r6 MAJOR-1 leftover marker blocks commit-only verbs → §3 marker cleared on every Finish exit · A r6 m1 commit-only
verb on a stale overlay → §4.1 Resolve + rebuild · A r6 m2 §8 row → restated · A r6 m3 `Left` canonical form → §2 ·
A r6 m4 / B r6 m3 `info.state` linkability → §4.1 owner-authenticated only · B r6 m2 `disabled` writer → §2 none
(asserted) · B r6 m4 wording → §7 cross-reference; rejoin's negative control is the §8 procedure.

## 14. Round 7 → final
A: APPROVE (two MINOR wording fixes applied in §2). B: APPROVE-WITH-CHANGES, no BLOCKER / MAJOR; its two MINORs:
- **`Encode` enforces the `Left` rule too** (key 12 only when true, and only with `State == claimed` and `Net == nil`;
  otherwise an error → the verb fails with `EApply` before anything is written). Without it a slip would commit a record
  that every later read rejects (`commitTxn` writes p5 first, `txn.go:31-41`). Negative control: a Go test committing a
  member record with `Left = true` — refused, p5 unchanged.
- **Who enforces "net fields only for the owner"**: the helper cannot see the BLE session role (`node.go:146-160`;
  `info.state` takes no args). So `net_id` / `version` / `left` come from a separate helper verb **`info.net`**, and the
  P2 provd contract routes it only for the owner role (roles live in provd, `219-protocol.md:88-100`); `info.state` is
  unchanged. Negative control (P2): an anonymous session asking for the net fields gets nothing. Until P2 the harness
  reads them over the root socket.
- §4.2 also states: a `network/update` on a node whose radio is switched off by hand is refused the same way (updates
  enter through `net.apply`).
Design status: **approved** (round 7). Implementation follows §11 with the tests in §8.
