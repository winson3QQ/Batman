# Review v10 — reviewer A — `docs/design/254-v16-ud.md` v10 (19c07fb)

I read the whole document. It was checked against source (`feed/` = wsl.36, the harness), against
`docs/design/254-reviews/v16ud-eud3.log`, and against `254-h23-harness.md` (F33). Read-only: no node, no ssh, nothing
committed. Product exposure items are referred to only as "local-only item N" (this repository is public).

## 1. Were the v9 findings fixed?

| v9 finding | State in v10 | Checked against |
|---|---|---|
| M1 logread leak grep blames product lines | Fixed. The mesh-id grep covers only our tags; system-daemon lines are INFO; the SAE-key grep stays global. E-UD3 confirms the premise: 3 `MESH-GROUP-STARTED` lines; the mesh id appears under `wpa_supplicant_s1g` (6) and `kernel` (1), never under a harness or batman tag. | `v16ud-eud3.log` |
| M2 compare prints raw uci values | Fixed in the right place: the mask is inside `prov-base-254.sh compare`, so every caller of the compare output is covered (m1 adds two hardening points). | `prov-254.sh:491, 495-497`; `prov-base-254.sh` (dv unit) `:36, 47, 55`; `prov-lib-254.sh:106` |
| m1 product argv | Handled as local-only item 1 (outside the PR). | — |
| m2 `CheckRestorable` premise | Settled read-only by E-UD3: `encryption=sae`; `--check-only` rc 0 with the key on stdin. | `cmd/batman-provhelper/main.go:234-265` |
| m3 join scope and reboot | Fixed: the join runs in the trial arm only; the post-join reboot is replaced by checks. | below |

## 2. Specific asks

### 2.1 The dropped reboot, against h23 F33
F33 (`254-h23-harness.md:75`) concerns the **sysupgrade** stage-1 arm `_ab_arm_mesh`:
- its caller is procd / `upgraded` / `_ab_live_sysupgrade`;
- if `joinwatch.lastjoined` exists it records `joined`, else `radio` (`platform-ab.sh:104-115`).

The rule at `:94, 229` (`net-apply` → reboot → `sysupgrade -n`, with the `mesh join required: 0 … radio_required=1`
assertion) exists so that a sysupgrade OTA records `radio` on a member that has not joined this boot.

In the v10 trial arm:
- every OTA into B is the **app path** (`update.apply` → `batman-slot arm` → `reboot committed`), which never runs
  `_ab_arm_mesh` and writes no `ota-armed.mesh`;
- the member trial therefore gets `NEED_MESH=1`, `RADIO_REQ=1` (`batman-autocommit:437-461`), as §4.4 asserts;
- the only sysupgrade OTA is `pr_brewrite`, and it runs after the restore's reboot, on the restored S0 member. That is
  the same sequence as every other prov unit, so the join without a reboot does not reach it.

The reboot can be dropped. The design's own reading is correct.

### 2.2 The four pre-row checks fail closed
Each one, on failure, leads to item 7: member rows INVALID "mesh not rejoined", or NEEDS-PERSON if 02 never returns.
None can produce a PASS. Two gaps:
- **`--check` rc 8** (lock busy while joinwatch's `--on-join` saves; joinwatch was restarted by `pr_make_legacy`) is a
  transient, not "mesh not rejoined". Retry it like the P9 rule (3 × 5 s), else INVALID. Today a busy lock makes a
  healthy join INVALID. → m2
- **`prov-state` field 6 = `radio`** does discriminate. `pr_make_legacy` restarts the helper, which rewrites
  `prov-state` for `legacy` (`MeshExpect` = `today`, `boot/boot.go:381-393`) in the same boot. Only the join's
  `refreshMeshExpect` turns field 6 back to `radio`. Its negative control should be named: the stub case "claim
  without join" → field 6 = `today` → INVALID. → m2

### 2.3 Masking coverage
I traced every DIFF path:
- `compare` prints DIFF lines for `p5.manifest`, `upper.manifest` (paths, modes, content sha256, symlink targets),
  `uci.export`, `identity` (slot, version, host-key fingerprints, ahwlan IP, dhcpconfigured, protB) and `DIFF state …`
  (`state_cmp`: sha prefixes, or the `prov-state` fields) (`prov-base-254.sh:177-210`);
- only `uci.export` carries raw secret values; the others carry paths, hashes of whole files, or non-secret fields;
- `pr_restore` (`prov-254.sh:491`) and the other readers print only what `compare` printed.

So masking `uci.export` inside `compare` covers all of them. Two hardening points remain → m1.

## 3. Findings

No BLOCKER, no MAJOR.

### MINOR

1. **Masking: name set and the replacement value.**
   - The name set (`key`, `mesh_id`, `ssid`, `sae*`, `password`, `psk*`) misses secret-bearing options that other configs
     under `/etc/config` may hold. `uci_exports` dumps **every** config (`prov-base-254.sh:91-93`). Examples:
     `private_key`, `preshared_key`, `secret`, `auth_secret`, `key1`–`key4`, `token`. It also covers only `option`
     lines, not `list` lines. Mask by pattern instead (`*key*|*secret*|*pass*|*psk*|*token*|mesh_id|ssid`), on both
     `option` and `list` lines.
   - The replacement `<sha256[:8]>` is a 32-bit verifier of a possibly human-chosen value (the AP passphrase): the same
     class as the `ap_key_sha` checklist item. Print `<changed>`, or an HMAC under a per-run random key that is never
     stored. "Which option changed" stays visible either way.
   - Offline fixtures: a `private_key` option and a `list` line.
2. **Pre-row checks** (§2.2): retry `--check` rc 8. Add stub cases:
   - rc 8 then rc 0 → the rows run;
   - claim without join → field 6 = `today` → INVALID (the field-6 check's negative control).
3. **Leak grep plumbing.** `grep -cFf -` (patterns on stdin) is assumed of the node's busybox `grep`, and is not
   probed. If unsupported, grep exits 2 with no count. Specify that an empty or non-integer count, or grep rc 2, is
   INVALID "leak check did not run", never 0 / PASS, and add a read-only probe
   (`printf 'zz\n' | grep -cFf - /etc/banner; echo rc=$?`). Same for the global SAE-key grep over the
   `pr_end` / `pr_abort` output.

## 4. Verdict: **APPROVE**

0 BLOCKER, 0 MAJOR, 3 MINOR (fixable in implementation).
- The v9 MAJORs are fixed in source terms.
- E-UD3 settles the join premise.
- Dropping the post-join reboot is correct against F33: the rule is for the sysupgrade arm, which this arm never uses
  before its restore.
- Masking inside `compare` covers every DIFF reader.
