# Review v9 (reviewer B) — `docs/design/254-v16-ud.md` at 155fce4

I read the whole document again, and looked first at the new member join of the bench mesh (§4.4 item 4, the fallback
in item 7, the key table, the leak checks, §1.7, §7, §8) and at the `@S0@` substitution in P9 / §7.1.

Source checked:
- `node.go:1106-1123` (`netJoin`), `:1242-1311` (`applyNet`), `:560-607`, `:703-745`;
- `cmd/batman-provhelper/main.go:150-163` (`SetKeyNoPersist`), `:500-548`;
- `provstore/provstore.go:346`, `provstore/txn.go:21-40, 86-89`;
- `node/settings.go:21-22, 151-153`;
- `tests/tools/provclient/net.go:40-70, 180-240`;
- `prov-254.sh:862-890` (`pr_pc` FD3), `:930-946` (`pr_member`);
- `prov-base-254.sh:38, 100-104, 148`;
- the implementation at 155fce4: `prov-update-254.sh:255`, which filters `halow-setkey --status` to the `ap ` line, so
  no mesh id reaches the log.

Read-only: no node, no ssh.

## The join step: lifecycle

| Event | What happens | Recovery | Verdict |
|---|---|---|---|
| `CheckRestorable` refuses (the bench mesh was not set through halow-setkey) | `applyNet` returns `EApply` **before** the marker, the `.txn` or any change (`node.go:1249-1257`) | item 7 fallback: claimed, member rows INVALID | sound |
| A setkey failure | rc 2 → nothing changed, `.txn` removed. Otherwise `finish()` puts the previous wireless back from the `.txn` snapshot (`:1278-1285`). | fallback; 02 must be a neighbour again within 180 s, else NEEDS-PERSON | sound |
| Host death inside the join | none: the whole of `applyNet` runs inside the helper, which does not depend on the ssh session | §7.1 step 2 restores the snapshot | sound |
| Power loss inside the join | `.txn` lives at `/etc/batman-prov/.txn` (`provstore.go:346`, overlay, 0600, `txn.go:26`). The next boot's Finish goes forward or back, decided by p5 (`:1240-1241`). | §7.1 step 2: the overlay restore deletes extras, so `.txn` is gone with it. The p5 dd and the overlay tar bring back the original member record (own `Net`, `Admins`, generation 15, owners) and the original `/etc/config/wireless`. The compare (sha per file) and the `ud_owner_scan` compare make it explicit. | sound |
| The reload blip | halow-setkey sets only key, id and channel (`main.go:150-163`); the bandwidth in `net_config` is not applied (regdb-derived, `settings.go:151-153`). Same values → 04 rejoins the same mesh. 02 loses 04 for the reload. | `pr_end`'s "02 a neighbour, not rebooted" check stays the guard | sound; see MINOR-2 for the post-join check |
| Restore | p5 dd + verify; overlay tar + extras removed; STATEFILES (`prov-state` from `SetLastKnown`; `lock-status`; `prov-counters`; `update-last`); generation back to 15 in both copies | `pr_compare` `diffs=0` + scan vs `ud-s0` | sound |

## The secret path

**SAE key.** The producer text is only `uci -q get …` plus builtin `printf`. The values live in shell variables and a
pipe into provclient's fd 3 (`pr_pc`'s `exec 4<&0; { $fd3; } | …`). provclient encrypts `{sae, root}` on the node to
the helper's ECDH key; the `SIGN` request carries ciphertext only (`net.go:210-218`). The helper passes the key to
halow-setkey on stdin (`main.go:150-160`). No argv, no harness log, no host file. Correct.

**Mesh id.** It is in the signed `net_config`, which goes in memory to the WSL signer, and the signer prints only
`SIG`. `PROVCLIENT_NET_QUIET=1` removes both of today's prints (`NETCFG` and `mesh_id_sha=`, `net.go:234-235`), with a
negative control. The product's own `--mesh-id` argv (`main.go:154-155`) is outside the PR and is stated.

**Leak checks.** Patterns read on the node; only counts printed. Good, but see MINOR-1 for the pattern file.

**What H0 can do in the arm.** As 04's owner and sole admin of a fresh net id: root through `root_password.reset` /
`ssh_keys.set`, `network/update` and `network.leave`.
- All of it is confined to 04: the new net contains only 04, and 02's record is untouched.
- H0 cannot learn the bench SAE key from the protocol: net secrets are encrypted to the node.
- Root on 04 can read it anyway from `/etc/config/wireless`.
- §8 states this; it is acceptable on the bench.

## `@S0@`

- **Validated:** exactly `legacy|claimed|member`, else the generic line.
- **Substituted only into `PR_S0_STATE=` and a comment.**
- **Cannot carry `/`, `&` or a newline.**
- **Dry-run:** assert 10 covers a claimed start.

Host death while 04 is a member with H0 uses the same §7.1 path as any other state, and the P9 state line
(`UD-OWNERS now: … snapshot: state=<s0>`) shows the person that 04 is held by the bench key. See MINOR-3 for the source
of `s0`.

## Findings

### MINOR-1 — the leak check's 0600 pattern file holds the SAE key and nothing removes it after a host death

- The pattern file is written under `/tmp/run/batman-dv/<run>/`. Neither `pr_release` (it removes `$PCD` and the
  payload) nor the dead-man (segment 1, the journal) cleans that directory.
- A host death between writing and removing it therefore leaves a root-only copy of the bench SAE key in tmpfs until
  the next reboot.
- Little extra exposure (the key is already in the wireless config), but it is a copy the design says does not
  exist.

**Fix (either):**
- Do without the file: `printf '%s\n' "$k" "$m" | grep -cFf - <files>`. Busybox `grep -f -` reads the patterns from
  stdin, the values stay in builtins and a pipe, and no file and no argv is involved.
- Or register `rm-file /tmp/run/batman-dv/<run>/ud-leak.pat` with `undo-add` **before** writing it. `rm-file` is an
  existing action allowed under `/tmp/run/batman-dv/` (`prov-undo-lib-254.sh` `u_path_ok`).

### MINOR-2 — after the join and its reboot, assert 02 as a neighbour before any row runs

Item 5 is "reboot, `pr_find`, `pr_pc_place`". If the join "succeeded" but 04 did not come back on the bench mesh,
nothing would show it until the trial rows fail on the mesh gate. That would be a FAIL attributed to the product, though
the cause is the harness's join. Possible causes:
- a value read differently from what the live radio uses;
- a regdb channel or country mismatch;
- `RadioManaged=true` boot behaviour.

Add `nbmac $PEERMAC` (02 a neighbour within 180 s, the same check as the fallback) right after the post-join `pr_find`.
On failure: the arm goes the item-7 way (restore, member rows INVALID "mesh not rejoined") or NEEDS-PERSON. Never a row
FAIL.

### MINOR-3 — `@S0@` is taken from `prov-state` field 3, not from the record `pr_begin` judged

`pr_begin`'s `PR_S0_STATE` comes from `prov.meta` (`pr_meta_state`). §7.1 takes field 3 of the snapshot's
`prov-state`, which helper writes (`main.go:519`; `SetLastKnown`) and which can lag or be absent (e.g. a legacy node
that never wrote it). Absent or out-of-set values fall back to the generic line (fail-closed), so a legacy start can lose
the block for no good reason.

Read `prov.meta`'s `state=` from the snapshot's own overlay copy of `/etc/batman-prov/prov.meta` (or from the host's
`ud-s0/<RUN>.txt`), and cross-check it with `prov-state` where both exist. Add a dry-run case: legacy S0 with no
`prov-state`.

### MINOR-4 — the key table claims "no file"; state where the key does land

The harness puts the key in no new file of its own, but during an arm it exists in:
- the product's `.txn` (0600 overlay, written by `WriteTxn` with `prevKey`, removed by Finish or by the restore);
- `/etc/config/wireless` (pre-existing);
- p5;
- the harness's own snapshot, `/opt/batdata/dv-prov/<run>/` (`umask 077`, root 0700, `prov-base-254.sh:38, 148`), as
  for every prov unit, removed at `finish`.

Write that in the table so the "no file" claim is precise: "no file **created by the harness** beyond the snapshot,
which already held it".

### MINOR-5 — 02 sees a peer with a foreign net id during the arm: check that it only observes

04 joins a fresh net id with the bench mesh parameters, so 02's helper sees a mesh neighbour whose team / net does not
match its own record. From the source in this tree, 02's peer sampling is read-only (`peers.go`; `peersRecordWritten`
only resets the local table). Under the 02 contract, add a read-only probe of 02's helper log over the arm, so the run
proves 02 took no action (no "team" change, no `network/update`, no reboot). `pr_end` already checks "not rebooted".

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 0 MAJOR, 5 MINOR.

The join step is fail-safe:
- refusal before any change;
- Finish or an undo after a partial change;
- 02 re-checked on the fallback;
- the snapshot restore covers every later state, byte for byte, including the original member record and its `Net`.

The secret path keeps the SAE key and the mesh id out of argv, logs and host files, and the `@S0@` substitution is
validated and tested. The five MINORs are small fixes that can be made during implementation.
