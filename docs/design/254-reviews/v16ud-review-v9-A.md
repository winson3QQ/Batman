# Review v9 — reviewer A — `docs/design/254-v16-ud.md` v9 (155fce4)

I read the whole document, focused on §4.4: the member join of the bench mesh with `Owners=[H0]`, every hop of the
SAE key and the mesh id, `CheckRestorable`, the post-join reboot, the restore, `@S0@` and the per-row table. Checked
against:
- `feed/` (wsl.36): `node/node.go`, `cmd/batman-provhelper/main.go`, `halow-setkey`;
- the test tool `tests/tools/provclient/net.go`;
- the harness: `prov-254.sh`, `prov-base-254.sh`, `prov-update-254.sh` at this commit.

Read-only: no node, no ssh, nothing committed.

## 1. Every hop of the secret path, verified

| Hop | Verdict | Evidence |
|---|---|---|
| fd-3 producer on the node | OK. `uci`'s argv carries option names only; values sit in shell variables; `printf` is an ash builtin (E-UD1 #14); the pipe goes into provclient's fd 3. The ssh command string and the host's `pr_pc` variables hold only the command text. | `prov-254.sh:879` (`exec 4<&0; { $fd3; } \| … 3<&0 0<&4`) |
| provclient reads fd 3 as root, before the drop | OK | `net.go:47-79` |
| SAE key → `net_secrets` | OK. `{1: sae, 2: random root}` is encrypted on the node to the helper's ECDH key; the `SIGN` request for `batman/secrets` carries `{net_id, version, dh, COSE_Encrypt}`, ciphertext only. | `net.go:210-218` |
| Mesh id → `net_config` → the WSL signer | OK as designed. It is in the `SIGN cose` Sig_structure. `pr_pc` routes `SIGN` lines to the coproc and never into `out`. | `net.go:190-197`; `prov-254.sh:882-888` |
| provclient prints | Today: `RESULT … mesh_id_sha=` (64-bit hash of the id) and `NETCFG <hex>` (the whole signed config, mesh id included) (`net.go:234-235`). `PROVCLIENT_NET_QUIET` is the right fix; the offline negative control (without it the id is found in NETCFG) is sound. | — |
| Helper → halow-setkey | Key on **stdin** (`main.go:151-160`), mesh id and channel on argv. | — |
| Inside halow-setkey | [redacted in the committed copy: a local-exposure detail of a product code path, kept locally — owner rule of 4028325] → m1 | — |
| halow-setkey's own log | OK: `config updated on:<sections> channel=N` | `:462` |
| Unused values | `bw=2` and the root secret are not applied (`parseNet` reads only mesh id and channel from key 6, `node.go:1072-1086`; the root is not used anywhere in `node/`). The hard-coded `bw=2` against the bench's channel 40 (4 MHz in US) is therefore harmless. | — |
| The unit's AP check | It filters `halow-setkey --status` to `^ap ` (`prov-update-254.sh:255`), so the `mesh … id=` line never reaches the log. The design text should say so. | — |

## 2. Other focus points

- **`CheckRestorable`** (`cmd/batman-provhelper/main.go:234-265`) refuses when `wireless.<mesh>.encryption` ≠ `sae`, when
  the key is empty, or when `halow-setkey --check-only` rejects the key / id / channel. These are read-only facts →
  minor 2.
- **Post-join reboot.** It is not needed for correctness:
  - `applyNet` already writes prov-state's `mesh_expect` (`refreshMeshExpect`, `node.go:1308`);
  - every trial boot rewrites prov-state anyway;
  - a `.txn` left by a failed save is checked by reading `/etc/batman-prov/.txn`.

  It is harmless but costs four reboots → minor 3.
- **Restore of the original member record** (own `Net`, `Admins`, gen): holds. The join touches the following, and the
  pre-legacy snapshot plus `STATEFILES` cover all of it:
  - p5 and overlay: `prov.cbor` / `prov.meta`, `.txn`, uci wireless;
  - p6: `prov-state` (`refreshMeshExpect`) and the mesh markers.

  The scan compare checks the record sha.
- **`@S0@`.** Field 3 (`last_known_state`) of the snapshot's `prov-state`, validated against the three states, is right.
  The snapshot is taken before `make_legacy`.
- **Per-row table.** It holds. Member is the field case (`MeshExpect` = `radio` → `RADIO_REQ=1`, `NEED_MESH=1`); the
  owner-op gate (`node.go:784-785`) is now worded correctly.

## 3. Findings

### MAJOR

**M1. The on-node leak grep over `logread` will very likely FAIL on product lines that have nothing to do with the harness.**
- Scenario. After the join, `logread` since the arm's mark is grepped for the mesh id. The join's `wifi reload` restarts
  the mesh interface. OpenWrt's `wpa_supplicant` (started with syslog output) reports mesh events through `wpa_msg`, as in
  `<if>: MESH-GROUP-STARTED ssid="<mesh id>" id=0`, which lands in `logread`. The same happens at every boot.
- So the check counts a system daemon's line as a harness leak: a FAIL attributed to the harness, on every run. The
  rule "no FAIL without attribution" forbids that.
- The mesh id is also not a secret on air: 802.11s beacons carry the Mesh ID element in clear. The owner's requirement
  is about our logs, not the air.
- Evidence: `wpa_supplicant`'s mesh event format (upstream `mesh.c`, `MESH_GROUP_STARTED`). Not yet shown on 04: it is an
  assumption to probe.
- Fix.
  - A read-only probe first: `logread | grep -c 'MESH-GROUP-STARTED'` (a count only).
  - Restrict the logread part of the leak grep to the tags this PR or its tools produce or drive: the unit's
    `logger -t` tags, `batman-provhelper`, `batman-provd`, `halow-setkey`, `batman-config-save`, `dv-*`.
  - Report the system daemons' mesh-id lines as INFO "pre-existing, also on air", not FAIL. The SAE key grep stays over
    everything: any hit there is a FAIL wherever it comes from.

**M2. A failed restore compare prints raw uci wireless values (the bench SAE key, the mesh id, the AP key) into the unit log.**
- Scenario.
  - `prov-base-254.sh compare` diffs `uci.export`, which is a full `uci export` of every config (`:91-93, 110`). It prints
    every differing line as `DIFF uci.export - option key '<value>'` (`:177-204`).
  - `pr_restore` echoes the last 20 lines of that into the unit log (`prov-254.sh:491`).
  - Until v8 the arms did not rewrite the bench wireless. Now every arm's join does, so a wireless restore that is not
    exact ends with the bench SAE key (the `-` side, from the snapshot) and the mesh id in the host's unit log. That is
    the failure path, where people read logs closest.
- The design's leak check runs after the join, not after the final compare, and the compare is a pre-existing path, so
  nothing catches it.
- Fix.
  - In `compare`, print `uci.export` DIFF lines with the value of `key`, `mesh_id` and `ssid` options replaced by
    `<sha256[:8]>` (or `<changed>`).
  - Offline: a compare fixture with a changed key must print no key bytes.
  - Run the on-node leak grep over the final `pr_end` / `pr_abort` output as well.

### MINOR

1. **Correct the "never in an argv" row.** [redacted in the committed copy: a local-exposure detail of a product code path, kept locally — owner rule of 4028325]
2. **`CheckRestorable` can be settled read-only now**, not "unproven until the run". Add to the probe set:
   `uci -q get wireless.default_radio1.encryption` (expect `sae`), plus a shell check of the key's length (≥ 8) and
   characters (none of `` ` $ ( ) ; | & < > ' ``). That check prints only `ok` or `bad`, never the key. A `bad` changes
   the plan before 5.8 h of device time, instead of making the member rows INVALID in the run.
3. **Post-join reboot and per-arm join.** Only the trial arm needs `member` (the radio gate); refuse / write / kill rows are
   state-free (§4.4 table). Either:
   - join only in the trial arm (three fewer wifi reloads, less key handling, fewer reboots), or
   - keep the join everywhere and drop the post-join reboot, checking instead that `/etc/batman-prov/.txn` is absent and
     `--check` is fresh.

   If neither, state the reason the reboot is kept.

## 4. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 2 MAJOR, 3 MINOR.
- The member join is sound, and I verified the secret path hop by hop. The SAE key leaves the node only as ciphertext;
  the mesh id reaches the WSL signer only in memory; `PROVCLIENT_NET_QUIET` closes provclient's own prints. The restore
  and `@S0@` are correct.
- The two MAJORs are about the evidence and failure paths around it:
  - a leak check that would blame the harness for a system daemon's log line;
  - a pre-existing compare output that would print the bench key on a failed restore.
