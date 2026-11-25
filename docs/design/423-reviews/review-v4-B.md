# Review v4-B of `docs/design/security-architecture.md` (#423, v4)

Reviewer B, independent, L3, round 4. Read-only: diff e4c9930..2978d94, then the whole v4 document, and the source
behind the new citations. No node was touched. I did not read any review-*-A.md.

## Verdict

**APPROVE — 0 BLOCKER / 0 MAJOR / 3 MINOR** (new, for the register).

## 1. My round-3 M1 (automatic-reset trigger) — closed

- §8 now states two requirements that can be tested: nobody on the radio side and no non-root process can *request*
  a reset (root-only channel, not a verb on the socket provd uses); failures a peer can cause (abnormal boots, health
  items that need neighbours or radio traffic) do not count towards level 4. The shipped neighbour requirement is
  cited correctly (`batman-autocommit:451-464`).
- The residual risk is stated honestly: it cannot be excluded completely; someone who can make the node fail locally
  again and again may still push it to level 4, after which the node is off its network until the owner's phone is
  there; #402 must measure and state it. I have nothing to add to it.
- §13 has the row to change #402's trigger list; test 9 has four concrete parts (K panics, K boots without
  neighbours, request as the provd user, fall-back after the reset does not rejoin the old network).

## 2. §6 change (the other reviewer's MAJOR) — sound

- "v2.0 tickets do not change the record key set": consistent with what I checked in round 3 (`255-608b-impl.md` adds
  no record key; the two reset actions map onto existing fields: `leave` already yields claimed / no network / key 12,
  `node.go:1316-1325`). The added v2.0 regression ("a record written by a v2.0 image is readable by v1.6") is the
  right negative control.
- Condition 7 (after the record has the new version, refuse to install an image that cannot read it): no lock-out.
  Every image built from the conversion release onward reads the record, so newer images always install; only older
  ones are refused, which is the intent. It does not conflict with `release-min-serial` (an additional refusal at
  install time) or with A/B behaviour (nothing changes at boot). See MINOR 1 for where the capability must be read.

## 3. Round-3 MINORs 1–12

All handled as the register says, and I found no error or contradiction introduced by the fixes. "BLE health only
warns" is recorded as open in the register; that is accurate (`batman-autocommit:566-575` — I read those lines in
round 3: it is warn-only, "not blocking (P-U5)"), so it can be closed as a K14 row whenever the table is next edited.

## 4. Rework check with the v4 text

Unchanged from round 3: nothing fixed in v2.0 (chip configuration, certificate, QR, record format, partition layout,
boot signing key, provisioning steps, factory-reset verb, automatic-reset behaviour) has to be redone for the trust
model or the CM4. The v4 sentence "v2.0 tickets do not change the key set" makes the record-format part stronger than
it was.

## New MINORs (register)

1. **§6 condition 7 / condition 4 — where the "highest record version I read" line is read from.** It has to be read
   from the staged image itself, not added as a key to the release object: the release object is strictly parsed
   (`release.go:262-263`), so a new key there would need a new object version (F2) that helpers in the field refuse.
   The text says "映像裡放一行", which is the right place; add "not in the release object" so the conversion ticket
   does not pick the other option.
2. **§8 "第 1 列清網路沿用已出貨的離開網路交易".** `leave` refuses unless the record state is `member`
   (`node.go:1317-1319`) and it reads the current wireless settings first (`:1330-1333`); on a node whose
   configuration is what is broken, that read may fail. #402's design has to say what the reset does when the leave
   transaction cannot run (and for a node that is `claimed` with no network there is nothing to clear).
3. **§8 fail-open table, dev-open row.** The same marker also relaxes the legacy claim gate in the helper
   (`node.go:580-585`, `n.Sys.DevOpen()`); one more citation in that row.

## Citations checked (new in v4)

| Item | Result |
|---|---|
| `node.go:1312-1322` (leave transaction) | held |
| `node.go:571-576` (claim proof for legacy too) | held |
| `boot.go:190-232` (record absent → unclaimed / legacy) | held |
| `feed/batman-provision/files/usr/bin/batman-autocommit:451-464` | held |
| `feed/batman-provision/files/etc/uci-defaults/96-batman-config-migrate:84-93` (dev-open marker) | held (lines 84, 90) |
| `254-stage1-impl.md:137` (two writers of prov-state, same rule, different boot stages) | held |
| `release.go:162` | held |
| V3, V4 | still unverified, marked so in the document |
