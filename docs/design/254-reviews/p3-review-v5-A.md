# #254 PR-P3 design v5 review — reviewer A

Target: `docs/design/254-p3-impl.md` v5 (feat/254-p3 @ 1ac5fbd, base main 2ecf1cb). I reviewed the whole document, not the v4→v5 delta, and checked Appendix A against source and the live node instead of trusting it.
Method: source in the same tree (feed/batman-prov/src, feed/batman-provision/files), the firmware-2710 build tree (nftables 1.1.1 source, both kernels' built objects and `.config`), and node 04 (1.5.14-wsl.22), **read-only**: only `uci show/get`, `bridge link`, `ip -br link`, `nft list tables`, `ubus call service list`, `ps`, `/proc/<pid>/status`, `cat`/`grep`/`sed` of system files, with output piped back. Nothing was written on the node (not even /tmp), no module loads, no restarts. The repo was not edited, nothing was pushed, and there are no GitHub comments.

**Verdict: REJECT (narrow).** 0 BLOCKER, 5 MAJOR, 15 MINOR.

v5 is much more coherent than v4, and most v4 findings are really handled (see the ✅ list). What is left falls into two kinds:
- **Three mechanisms that would not work on the real node as written.** Each rests on an assumption that was taken from a review suggestion, or written from memory, without being probed:
  - the nft wildcard (M1);
  - the fw4 transaction (M2);
  - the provd pid (M3).

  All three fail closed or fail visibly in H4, but two of them would make the feature dead on arrival. One of those (M3) would also make **P3 itself impossible to install**, because every trial would revert.
- **One field path that strands nodes** (M4: country change on legacy-claimed nodes, which is today's whole fleet), plus contract contradictions on the main update path (M5).

Every fix is local (a few lines of design each). None needs a new subsystem.

---

## MAJOR

### M1. The L2 rule `iifname != "phy*-ap*"` cannot work: nft only treats a **trailing** `*` as a wildcard. The rule therefore drops the phone-AP port too, so the upload and the HTTP fallback are never reachable, and nothing notices
- **Scenario**: the owner opens the upload window (or BLE has been unhealthy for 5 min).
  1. The helper verifies that the table, the chain and the drop rule exist, and publishes `http.2`; provd binds.
  2. The phone, associated to `phy1-ap0`, sends a SYN to :8095.
  3. The bridge input rule compares `iifname` with the literal prefix `phy*-ap`, where the `*` is an ordinary character. `phy1-ap0` does not start with that prefix, so `!=` is true and the SYN is dropped.

  The result: every upload fails with a TCP timeout, and the fallback is dead. The helper's existence check (§3.8.1) passes, so nothing signals it.
- **Evidence**:
  - nftables 1.1.1 `src/evaluate.c:362-431` (`expr_evaluate_string`): only a **last** character `*` produces a `prefix_expr`, of length `datalen`. Any other `*` stays a literal byte, and a middle wildcard has no code path. Source: `firmware-2710/build_dir/target-aarch64_cortex-a53_musl/nftables-json/nftables-1.1.1/src/evaluate.c`.
  - 04 `bridge link show` shows the ports `eth0`, `phy1-ap0`, `bat0` on br-ahwlan (and veths on `br-ots`).
- **Fix**: use a prefix that nft can express, plus a read-only cross-check, so that nothing new writes state:
  - rule: `iifname != "phy*" tcp dport 8095 drop`;
  - in the same check that gates `http.2`, the helper confirms that every bridge port whose name starts with `phy` is a `mode=ap` iface of `radio0` according to `ubus call network.wireless status` (F52). Any other `phy*` port (for example a future HaLow AP iface on radio1, which would also be named `phyN-apM`) means no `http.2`, which is fail-closed. Write this into §3.8.1 and §5.3.

  Do not invent a new `ifname` option: it would add a writer to `wireless`.
- **Negative test**: the existing `prov-http-254` positive arm ("AP 上的擁有者完成上傳") becomes the regression test for this. The control is the v5 rule text loaded on a bench node: with it, the owner's SYN on `phy1-ap0` is dropped (rule counter increments).

### M2. Loading through fw4 makes `batman-http.nft` part of fw4's **single** `nft -f` transaction: any error in it means no firewall at all at boot (global fail-open), and every reload appends duplicate rules
- **Scenario**: a build where the bridge table does not load fails the whole transaction. Causes include a syntax error (M1 shows how easily this file can be wrong), a family or expression unsupported on one board, or a future kernel config change. On boot, `fw4 start` then fails as a whole: there is no `inet fw4`, so:
  - the `input REJECT` default is gone;
  - the `br-ots` DROP is gone;
  - `drop_from_dockert` is gone.

  The node runs with every port open to the mesh. The helper check only withholds `http.2`; the rest of the firewall loss is silent. On `reload`, the old fw4 stays (the transaction aborts), so the failure shows only after a reboot, which is the field case.
- **Evidence**:
  - 04 `/sbin/fw4` `start()` runs `utpl -S $MAIN | nft $VERBOSE -f $STDIN`, which is one transaction.
  - 04 `/usr/share/ucode/fw4.uc:818-821` auto-includes `/usr/share/nftables.d/ruleset-post/*.nft` into that same generated ruleset.
  - 04 `/usr/share/firewall4/templates/ruleset.uc:1-11` flushes only `table inet fw4`. A `table bridge batman_http { chain input { … } }` in an include is never flushed, so each `fw4 reload` appends another copy of the rule.
  - Kernel support is present (this partly closes §9-4): `net/netfilter/nft_chain_filter.o` contains `nft_do_chain_bridge` and `nft_chain_filter_bridge_init`, under `CONFIG_NF_TABLES_BRIDGE=m` and `CONFIG_NETFILTER_FAMILY_BRIDGE=y`, in both `build_dir/target-aarch64_cortex-a72_musl/linux-bcm27xx_bcm2711/linux-6.6.138` and `…a53…/linux-bcm27xx_bcm2710/linux-6.6.138`. So `kmod-nft-bridge` is not needed for `iifname` + `tcp dport`.
- **Fix**:
  1. Make the include idempotent: `table bridge batman_http` / `flush table bridge batman_http` / `table bridge batman_http { … }` (fw4's own idiom for `inet fw4`).
  2. Add a build/CI gate for both boards that loads the full generated ruleset with `nft -c` on a bench node (`fw4 print | nft -c -f -`). It must fail the build if the include breaks the transaction.
  3. Add an H4 assertion to the regular suite, after **every** boot: `nft list table inet fw4` exists **and** `bridge batman_http` exists. Also add a lifecycle row: "the include fails to load → today n/a; after: the whole fw4 is absent → caught by the gate and the boot assertion".
  4. Replace §9-4 ("probe whether a bridge table can be built") with "functional bench check"; the support question is answered above.
- **Negative test**: a seam that installs a deliberately invalid `ruleset-post` file in a wbox image. The gate and the boot assertion FAIL; with the valid file they PASS.

### M3. `provd-stable` identifies provd by "peer pid = procd instance pid, provd has no pid namespace". On 04 that is false, so `provd-stable` is never written and **every trial reverts**, including the ssh sysupgrade that installs P3
- **Scenario**:
  1. A P3 image is installed by ssh sysupgrade (the only way to get P3, §6), or later through the app.
  2. In the trial, autocommit's new `health_ok` (b) waits for `$RUNDIR/provd-stable`.
  3. The helper compares the ctl connection's SO_PEERCRED pid with the instance pid from `ubus call service list`. They never match.
  4. The trial is reverted at the deadline. P3 can never commit on any node.
- **Evidence**, all from 04 and read-only:
  - `ubus call service list '{"name":"batman-provd"}'` gives `"pid": 8388`.
  - `ps` shows `8388 root … {batman-provd} /sbin/ujail -t 5 -n batman-provd …` and `8414 provd … /usr/bin/batman-provd`.
  - `/proc/8414/status` has `PPid: 8388` and `NSpid: 8414 1`. `/proc/8414/ns/pid` is `pid:[4026532325]`, while `/proc/1/ns/pid` is `pid:[4026531836]`. So provd **does** run in its own pid namespace, as pid 1 inside it, and the procd instance pid is the ujail parent.
  - The helper is in the init pid namespace, so SO_PEERCRED reports 8414 ≠ 8388.

  The design's claim (§3.7.6, adopted from B4-m2) and F11's "no namespaces" summary are wrong on this point.
- **Fix**: the peer counts as provd when the `PPid` in `/proc/<peer>/status` equals the procd instance pid **and** the uid is 471 (optionally also `readlink /proc/<peer>/exe`). The procd instance pid stays the anchor (provclient's parent is not the ujail). Correct F11 to say "pid namespace: yes (ujail)". Record this 04 output in the F table.
- **Negative test**: `prov-autocommit-p3-254` "provd 穩定 60 s 後被殺 → 仍 commit" and `prov-update-254` "T 簽 → trial → commit → 5" are the regression tests. The control is the design text as written (pid equality), which never commits on 04.

### M4. Country change (key 2) on a **legacy-claimed** node rewrites the operator's live HaLow radio. That contradicts the design's own rule for key 20 and its read-back premise, and it can drop the node from the mesh it is running on. Today's whole fleet is legacy (F68)
- **Scenario**:
  1. A field node from the current fleet (legacy, meshing on an operator-configured `radio1`) is claimed by the owner's app. It is now `state = Claimed` with `RadioManaged = false`, so by §3.3 it counts as "未入網".
  2. The app sets key 2 (for example to match a new network's `net_config` country, §3.11-7).
  3. setkey changes `radio1.country` on a **live, meshing** radio. On HaLow the same channel number maps to a different centre frequency in a different country, so the node leaves its current mesh (the rest of the team stays on the old country).
  4. §3.3's read-back for key 2 checks only uci + regdb, on the stated premise "未入網節點一定是被封鎖 / disabled", so it reports success.

  §3.3 also refuses key 20 on `RadioManaged = false` precisely to respect the operator's radio. Key 2 on the same node does the opposite.
- **Evidence**:
  - `node/node.go:538-539`: `next.State = provstore.Claimed` and `next.RadioManaged = rec.State == provstore.Unclaimed // legacy claim keeps the operator's radio`.
  - `node.go:1110-1125`: a non-member join snapshots the live wireless, which is not a placeholder on legacy nodes.
  - 04 `uci show wireless`: `radio1` is up, `mesh_id='openmanet1'`, a real key, channel 40, US.
  - §3.3, key 2 row ("未入網的節點(含 legacy…)") and the read-back bullet ("未入網節點一定是").
- **Fix** (pick one; the owner decides, since D9 does not mention legacy):
  - (a) key 2 requires `RadioManaged = true`, and legacy gets `E_UNSUPPORTED{1: typ, 2: 7}`, the same rule as key 20. Then state the consequence: a legacy node whose radio country ≠ the network's country cannot join (D9) until the operator changes it with `halow-setkey`. That is an honest boundary in §3.11.
  - (b) key 2 on a radio that is **up** uses the full `--mesh/--channel` read-back (morse Operating Frequency against the regdb centre, `halow-setkey:349-374`) with `--rollback`, and the app warns "this node will leave its current mesh".

  Either way, fix the "一定是被封鎖" premise and add a `prov-settings-254` arm for a legacy-claimed node.
- **Negative test**: on a legacy-claimed bench node with a live mesh, key 2 → (a) `E_UNSUPPORTED{7}` and uci unchanged; or (b) the read-back runs on the chip and a failure restores the old country. Control: the v5 text (uci+regdb only), which returns success while the plink is gone.

### M5. Contract contradictions on the main paths. v5 was rewritten to give one answer per path, and H4 is written from this text first (D1)
1. **`update.prepare` while the upload window is open.**
   - §5.1, row "`settings.set`、`network/*`、`bulk.open`、`update.check`、`update.prepare` | worker 在跑或上傳窗開著 | `E_BUSY`", says it is busy.
   - §3.8.1 / §3.7.4 say the window stays open **until** `update.prepare` starts, and prepare closes it. So the only legitimate prepare always happens while the window is open.

   An implementation or H4 test written from §5.1 makes every update fail. (§3.1.7 says "`update.prepare`(第二個)", and §5.1 drops that qualifier.)
2. **A second `bulk.open`.** §3.1.7 and §5.1 say `E_BUSY` (§3.8.2: "沒有其他上傳窗"). §3.8.2 and §5.2 say a resend extends the same window and returns the same values. Define "second" as "a different `owner_key_id`", and say a same-owner resend extends.
3. **"唯讀動詞不跑子程序" (§3.1.4) against the read-only verbs that need subprocesses:**
   - `health.get` (the ctl poll) must carry `http.2`, which the helper gates on `nft -j list chain …` "每次 poll 前";
   - `update.status` phase 3 needs the target slot's `BATMAN-VERIFIED` (a FAT mount through `batman-slot`) and `is-trial`.

   State that each is a background cache (an nft check every 4 s off the request path; slot facts cached at helper start and after `write`/`arm`).
4. **`status` versus the CDDL.** `status-resp` requires keys 1, 2, 3 and 4 (`219-protocol.cddl:229-240`: `3 => uint`, `4 => bool`, with no `?`). §3.4 omits 4 ("超過 300 s … 省略") and, on a cold cache, returns "只回 key 1、4" (that is, it omits the required 2 and 3). Either make 3 and 4 optional in the CDDL (§10) or always send them.
5. **Who writes `update-last`.** §3.7.4 has `update.apply` writing it (`armed: false`, then `true`), but also says "下一次 `update.check` 通過時才覆寫 update-last". The phase table has no row for "worker failed" (§5.1 says phase 0 + `3: 11`). With an update-last left over from an earlier successful update, the failed new attempt matches "目前槽 = `to_slot` 且已 commit" and shows **5**. Say where the worker's failure reason lives (helper memory) and that it takes precedence, and say exactly what `update.check` does to update-last.
6. Small: §3.1.6 says "最多 5 分鐘" and §3.11-9 says "約 4 分鐘"; give one number, derived from 230 s and `HelperWait`.
- **Fix**: one pass over §3.1.7, §3.4, §3.7.4, §3.8.2, §5.1 and §5.2, plus a CDDL note in §10.

---

## MINOR

m1. **The `--rollback-only` snapshot is an unlisted interface.**
- After a helper timeout (setkey killed), "背景再跑一次 `halow-setkey --rollback-only`" has to know the previous values, which include the old AP passphrase.
- Nothing says where that snapshot lives (it should be the root-0700 RunDir), its format, who deletes it, or what happens after a reboot (tmpfs gone, which is fine, but say so).
- Add a row to §4 and §5.3, and a test in `prov-settings-254` (`setkey-norollback` plus kill-at-timeout).

m2. **Foreign staged uci changes.**
- Key 1 refuses when `/tmp/.uci/system` is non-empty (F48), but keys 2 and 20 go through `halow-setkey`, which runs a plain `uci commit wireless` (`halow-setkey:228,307,366`). That commits anyone's staged `/tmp/.uci/wireless`, and `--rollback` does not restore those changes.
- Apply the same `E_BUSY` rule to `/tmp/.uci/wireless` for keys 2 and 20. This is a pre-existing setkey property, but P3 adds a new caller.

m3. **Reason 17 has a recovery dead end on unjoined nodes.**
- After a power loss between setkey's commit and its persist (§6 row), or any other non-P3-key drift, an unjoined node returns `update.check` reason 17.
- The obvious app remedy, re-sending the same key 20, returns without doing anything ("與現值相同 → 直接回", §5.2), so no `--save` happens. Only ssh `--save` helps.
- Fix: a same-value `settings.set` runs `--check`, and runs `--save` if the result is stale.

m4. **`update.check` writes p5 before verifying anything, and has no helper-side rate limit.**
- Step 1 (`--save`) runs before the E/S signature check, on a verb that needs no owner-op.
- Every call takes `cfgsave.lock` (through `--check` / `precheck-node`) and mounts the target FAT (`bootcfg-sum`).
- The 1/10 s quota is enforced only by provd, so a compromised or buggy provd can starve `--on-join` into `cfgsave-lock.busy` (F28). That is the same harm §7 closes for `status`.
- Verify the signatures first, and add a helper-side limit (for example 1 per 10 s globally).

m5. **No deadline is stated for the worker's subprocesses.**
- The helper's `run()` gives every command other than setkey and config-save a 60 s deadline (`cmd/batman-provhelper/main.go:78-91`).
- `batman-slot write` streams ~126 MB to the SD card and then reads it back; on a slow card or a Pi 3 this approaches or exceeds 60 s.
- State the deadline for `write`, `arm` and `bootcfg-sum`, and what a timeout leaves behind (slot BAD, phase 0 plus a reason, lock taken over by the pid check at `batman-slot:78-95`).

m6. **Phase 6 can come from a stale `bad-slot`.**
- autocommit writes `bad-slot` (`slot=… version=…`) on a revert and removes it only on a later commit (`batman-autocommit:195,244,554`).
- So an earlier revert of the same slot, followed by a new app update that loses power after arm, shows 6 "已退回".
- Record the `bad-slot` content (or its absence) in update-last at apply, and report 6 only when it changed after `apply_boot_id`.

m7. **`batman-slot arm <sha>` re-checks "bootcfg-sum 仍在 key 8 清單裡", but `batman-slot` never sees S.** Define how the list is passed (a file in the helper's 0700 update dir, given as an argument).

m8. **The CDDL does not show the new `sha` argument.**
- `update/prepare` and `update/apply` are `op-only-req = {31 => owner-op, * uint => any}` (`219-protocol.cddl:96-97,425`). The `sha` in key 1 fits, but it is not written anywhere.
- `args_hash` covers the whole body (`219-protocol.md:265,272`), which is what makes the "被入侵的 provd 偷換 pending 版本" row hold. Add it to §10.

m9. **Several negative controls do not separate the guard from the feature.**
- "wsl.22" fails `prov-upload-254` and `prov-owner-254` only because the verbs do not exist. It does not show that any of these guards work:
  - non-window-owner rejection;
  - the source-IP binding of PUT;
  - the tmpfs `size=` cap;
  - `E_BUSY` during the window;
  - session cut on `owner/remove`;
  - bundle content without secrets.
- Add one-guard seams (prov_test build tag for the Go ones, the existing `seam` package, `seam/seam_provtest.go`).
- `prov-transfer-tool-254`'s control ("只寫 image 不清零") is an unbuilt variant; give it a test flag.
- The shell seams (`setkey-norollback`, `slot-copy-all`, `autocommit-noprov`) use the root-owned `/tmp/batman-fault.*` mechanism (`batman-slot:71-74`), which ships in **every** image. §8's "release gate asserts they are absent" therefore needs a build-time strip, or else the claim should be dropped.

m10. **§9-5 can be closed now.** uci-defaults run once per overlay: 04 `/etc/uci-defaults/` holds only `README`, so 96 does not run on a normal reboot. Record that as evidence in the §6 power-loss row.

m11. **provd's behaviour when a poll fails is unstated.** §3.8.1 covers a missing `http.2`. Say that a failed or stale poll (helper down, ERate) also means "close the listener", so a crashed helper cannot leave a stale `http.2` in force.

m12. **The non-bridge ingress text is inaccurate (§3.8.1, F58).**
- 04 has `firewall.docker` with `input='ACCEPT'`, so fw4 does not protect docker0.
- In fact docker0 and br-ots veth traffic **is** covered by the new bridge input rule (it passes the same hook with `iifname veth…`). Say so.
- Traffic over lo from a local process reaches 8095 directly. Add a §7 row: a local unprivileged process can take up the 2 HTTP slots during the window or the fallback. Rate it as an honest boundary or limit it per uid.

m13. **Rename (key 1) before U5.** Say explicitly that key 1 keeps returning today's `rename-pending` (`node.go:760-766`) in any rc or release until U5 has run and the rename unit passes. Otherwise an untested rename ships (this is compatible with D8).

m14. **`bootcfg-sum` while `batman-slot.lock` is held** (a concurrent sysupgrade) has no mapping in §3.7.4 or §5.1. Map it to `E_BUSY`.

m15. **The key 20 secret must also stay out of logs.** The request body carries the passphrase. Add to `prov-settings-254` an assertion that `logread`, provd/helper logs and the diag bundle do not contain it, next to the existing `/proc/*/cmdline` check. (On 04 today, read-only: the current AP and mesh keys appear 0 times in `logread`, `dmesg` and `/opt/batdata/log`/`crash`.)

---

## v4 findings: claims in Appendix A checked against the text and source

| v4 | v5 | Check |
|---|---|---|
| A4-M1 / B4-M1 table owner, fail-open | fw4 include + gate on `http.2` | ✅ direction. But see M1 (rule text) and M2 (the transaction failure mode is new) |
| A4-M2 setkey budget | 20+30+60+15+90+15 = 230 < 300 | ✅ arithmetic matches `halow-setkey:36-39`, `batman-config-save:244`, `main.go:84-85`. The snapshot for `--rollback-only` is unspecified (m1) |
| A4-M3 consistency | rewrite | ⚠️ mostly done; M5 lists what remains |
| A4-M4 controls | wsl.22 + seams | ⚠️ partly; m9 |
| B4-M2 new PRESERVE key | auto `--save` when the only stale keys are P3 keys | ✅ feasible: `diff_keys` prints every differing key name (`batman-config-save:477-482,489`). Dead end for other stale keys: m3 |
| B4-m2 provd-stable identity | pid = instance pid | ❌ false on 04 (M3) |
| A4-m1, m2, m3, m4, m5, m6 (256 KiB/s → ~8.2 min < 15 min window), m7 (`armed` + `bad-slot`; `bad-slot` exists at `batman-autocommit:195,244`), m9, m10, m11, m12, m13 | — | ✅ present in v5 (m7 has a corner case: m6) |
| B4-m1 kmod | probe deferred | ✅ answered by the build objects (M2): not needed |
| B4-m3, m4, m5, m9, m10 | — | ✅ |

Earlier rounds' fixes that I checked have not come back:
- no IP→MAC check;
- no per-accept helper query;
- no `bulk.done`;
- no `/rom` freshness rule;
- no version-tracking resource;
- no `radio0.country`.

## Other ✅ (evidence)

- **D15 premises**: the phone AP, eth0 and bat0 are the only br-ahwlan ports, and `wlh0` is not bridged (04 `bridge link show`). Every node runs dnsmasq on ahwlan, so a phone on an unjoined node's AP gets an address (04 `uci show dhcp`).
- **fw4 behaviour**: `reload`/`restart` rebuild only `inet fw4`; `flush` deletes every table (04 `/sbin/fw4`). This confirms the §6 rows.
- **Owner-op binds the whole body** (`219-protocol.md:265,272`), so the prepare/apply `sha` binding holds against a compromised provd.
- **Contracts for the shipped verbs**:
  - `secretTypes` already contains `owner/add` and `bulk/open` (`provd/session.go:73-74`);
  - `p3Types` matches §3.1 (`:68-70`).
- **Helper connection limits**: `MaxConns = 4`, and there is a 30 s idle timeout (`sock/sock.go:1-6,28`). ctl polls every 4 s, so it never idles out, and the 60 s `provd-stable` window is observable once M3 is fixed.
- **Read-only quotas**: 10/s global and 5/s per connection (`node/readonly.go:21-24`), so ctl + ro ≈ 6/s holds.
- **HealthOK** has the six fields plus freshness and ERate (`provd/server.go:480-499`). Advertising is withdrawn on `nlinks > 0 || Sessions() > 0` (`cmd/batman-provd/bluez.go:770-773`); the design already lists the change to BLE-only.
- **`/cgi-bin/bundle`** today serves halow-status, logs, dmesg and logread (`www/cgi-bin/bundle`). The helper's `DiagBundle` excludes uci wireless, shadow and identity (`main.go:393-401`). No current key appears in those sources on 04 (m15).

## Deferred probes (§9): is each deferral acceptable?

1. **U5**: acceptable only if key 1 stays `rename-pending` until U5 has run (m13).
2. **YubiKey**: acceptable. The node side depends only on ES256 (`cose.VerifySign1`), and the bench arm of `prov-update-254` covers the host side before release.
3. **morse table change on a blocked radio, then join**: acceptable (fail-visible in `prov-country-join-254`). Not acceptable for live legacy radios (M4).
4. **The kmod**: answered here (not needed). Replace it with the M2 build gate and a bench functional check.
5. **96 behaviour**: answered (m10).
6. **The tmpfs `size=` value**: acceptable (RAM budget check, fail-closed reason 8).
7. **The setkey new flags**: acceptable, provided the `--rollback-only` snapshot contract is written now (m1).
8. **CYW43455 coexistence**: acceptable as an H4 measurement (radio0 is 5 GHz, so coexistence with 2.4 GHz BT is expected to be benign, but measure it).

## Convergence

Converging, not converged. The structure (ownership table, cleanup table, error map, lifecycle matrix) is now complete enough to review against, and that is how M1–M5 were found.

M1–M3 are each a wrong fact about other code: nft's wildcard grammar, fw4's single transaction, and ujail's pid namespace. Two of the three came from review suggestions that nobody probed (my own v4 suggestion of a `phy*` prefix was also not probed against the AP-only requirement). The cheap lesson is to probe every "other code behaves like X" sentence that a fix depends on before freezing the design.

With M1–M5 fixed as above (no new mechanisms), I expect the next round to be APPROVE-WITH-CHANGES.
