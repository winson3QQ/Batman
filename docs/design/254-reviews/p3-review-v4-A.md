# #254 PR-P3 design v4 review — reviewer A

Target: `docs/design/254-p3-impl.md` v4 (feat/254-p3 @ 5d5ebfd, base main 2ecf1cb). I reviewed the whole document, not only the v3→v4 delta.
Method: source in the same tree (feed/batman-prov/src, feed/batman-provision/files, scripts/), the firmware-2710 kernel tree, and node 04 (1.5.14-wsl.22), **read-only** (no writes, no uci set, no restarts, no module loads; output piped back only). The repo was not edited, nothing was pushed, and there are no GitHub comments.

**Verdict: REJECT (narrow; converging).** 0 BLOCKER, 4 MAJOR, 13 MINOR.
The v3 MAJORs are addressed in the right direction:
- a port-based L2 filter replaces the IP→MAC check (B3-M1);
- a separate `ro` connection, with ctl kept strictly read-only and `bulk.done` removed (B3-M2);
- a placeholder-aware rollback in setkey (B3-M3);
- a uci+regdb-only check on blocked radios (B3-M4);
- the D18 autocommit gate (B3-M5).

What is left:
- the new nft filter has no runtime owner, and it fails **open** when the table is missing (M1);
- the claim "≤ 300 s including rollback" for key 20 / key 2 is asserted but not computed. The existing constants already use up most of the budget, and a helper timeout kills setkey mid-rollback (M2);
- the contract text contradicts itself in 10 places, and H4 will write its tests from that text (M3);
- most negative controls in §8 name design variants that were never built, so they cannot run (M4).

All four are local fixes, and none needs a new subsystem, so one more round should converge.

---

## MAJOR

### M1. D19 nft bridge filter: no runtime owner, `fw4 flush` deletes it, and a missing table or rule fails OPEN (provd still listens)
- **Scenario**: HTTP is listening (upload window, or the fallback while BLE is broken), and the `bridge batman_http` table is gone. It can disappear in three ways:
  - (a) someone (or a script) ran `/etc/init.d/firewall stop`. Its `stop_service` is `fw4 flush`, which deletes **every** nft table of every family, not only `inet fw4`;
  - (b) the table never loaded on a build (missing module, nft syntax error, a bcm2710 build difference);
  - (c) the load at boot raced something.

  Port 8095 on `br-ahwlan` is then reachable from the whole mesh again. That is the exhaustion scenario D19 exists to stop (v1 B1 / v2 M3, M5 / v3 M1). §5.3 calls the filter fail-closed, but that row only covers "the set is empty". Nothing covers "the table, chain or rule is absent": the helper still hands out `http.2` and provd still binds.
- **Evidence**:
  - 04 `/etc/init.d/firewall` has `stop_service() { fw4 flush }`. In 04 `/sbin/fw4:61-67`, `flush()` runs `nft list tables | while read …; do nft delete table "$family" "$table"; done`. (By contrast, `restart` deletes only `inet fw4`, via `stop()` in `/sbin/fw4`.)
  - Ownership table §4, row "nft bridge 表 `batman_http`", says "表 = image(開機載入)". An image is not a runtime owner, and no process recreates the table. fw4 is a second writer (it deletes the table) and is not listed.
  - 04 `nft list tables` shows `ip filter, ip nat, ip6 filter, ip6 nat, inet fw4`. A flush removes docker's iptables-nft tables along with everything else.
  - The module assumption is unverified, which matters under "only the necessary changes":
    - firmware-2710 bcm2711 `.config:1325` has `CONFIG_NF_TABLES_BRIDGE=m`, and `:1326` has `# CONFIG_NFT_BRIDGE_META is not set`.
    - `net/netfilter/nft_chain_filter.c:229` registers the bridge filter chain under `#if IS_ENABLED(CONFIG_NF_TABLES_BRIDGE)`, that is, inside `nf_tables.ko` itself.
    - `kmod-nft-bridge` (`package/kernel/linux/modules/netfilter.mk:1166-1176`, `include/netfilter.mk:332`) ships only `nft_meta_bridge` (ibrname etc.), which an `iifname` match does not need.
    - So the package may be unnecessary, or it may not be; nobody has probed it. ⚠️ I could not probe it myself, because creating a table on 04 is a write.
  - A bridge-family rule does not cover non-bridged ingress at all: lo, docker0-routed traffic, tailscale0 (04 has `uci show tailscale`) and the USB gadget (`usbgadget` preset `ncm`). Today only fw4's REJECT for unzoned input (`firewall.@defaults[0].input='REJECT'`) and the zone policies cover these. The design does not say it relies on that.
- **Fix** (small, and it removes a writer):
  1. Load the table **through fw4**: ship it as `/usr/share/nftables.d/ruleset-post/batman-http.nft`. fw4 includes that file at top level on every start, restart and reload (04 `ruleset.uc:472 fw4.includes('ruleset-append')`). fw4 then becomes the single loader, and the `firewall stop` gap is stated as an honest boundary.
  2. Consider dropping the `@ap_ports` set that the helper maintains. It means a 5 s `ubus` + `nft` subprocess loop forever, a new writer, and a drift window after `wifi reload`. A static prefix match `iifname != "phy*" drop` on the bridge input hook would replace it: on this platform the only `phy*` bridge ports are mac80211 radio0 interfaces (04 `bridge link show`: eth0, phy1-ap0 and bat0 on br-ahwlan; the morse mesh is `wlh0`, which is not a bridge port). If an exact match is required, keep the set, but say why.
  3. **Fail closed where `http.2` is published**: the helper puts `http.2` in the poll reply only after it has verified, in the same tick, that the chain and the drop rule (and the set, if kept) exist (`nft -j list chain bridge batman_http input`). If they are missing, there is no `http.2`, so provd does not bind. Add the contract row "table/rule absent → no listen".
  4. Add lifecycle rows:
     - `firewall reload/restart`: fw4 re-creates the table;
     - `firewall stop`: the listen is withdrawn within one poll;
     - a build without bridge support: no listen, plus a `health` WARN.
  5. Probe before implementing, on the bench (not on 04 live): a bridge table plus an `iifname` rule, with and without `kmod-nft-bridge`. Record the result in the F table.
- **Negative test**: on the P3 image, run `nft delete table bridge batman_http` while the upload window is open. Within one poll provd stops listening, and a mesh host cannot connect. Negative control: the same image with the verification seam forced to "ok"; the mesh host connects.

### M2. key 20 / key 2: "整次呼叫(含還原)≤ 300 s" is asserted, not computed. The helper kills setkey at 300 s, which can land mid-rollback and leave neither the old state nor the new one
- **Scenario**:
  1. The owner pairs (key 20) while `99-batman-chanfix` or an operator holds `halow-setkey.lock` for a while, or netifd is slow.
  2. setkey waits up to LOCKWAIT, settles, commits, waits for the read-back, and fails.
  3. It runs `--rollback`: another commit, reload and read-back, plus, on a fresh node, the placeholder re-block with its own wait. Then it persists.
  4. The helper's subprocess deadline fires, and setkey is killed between "new committed" and "old restored".

  No `.txn` covers AP changes, so nothing finishes the change later. The result:
  - the AP may be up or down, with unknown credentials;
  - the MARK may be cleared;
  - p5 ≠ live, so OTA is gated as stale.

  This violates "a failed change goes back to the previous state".
- **Evidence**:
  - The helper's deadline: `cmd/batman-provhelper/main.go:84-85` (`halow-setkey` → 300 s; timeout = RCTimeout, "outcome unknown").
  - setkey's constants: `halow-setkey:37-40` (LOCKWAIT=90, FORGET_WAIT=30, SETTLE_WAIT=30, READBACK_WAIT=60). The persist step is `batman-config-save --save` (`:165`), whose lock wait is 10 s (`batman-config-save:244`).
  - Worst case before any new radio0 wait, which comes to about 300 s:

    | Step | s |
    |---|---|
    | lock wait | 90 |
    | settle | 30 |
    | apply read-back | 60 |
    | persist | ~15 |
    | rollback read-back | 60 |
    | placeholder re-block (fresh node) | 30 |
    | persist | ~15 |
    | **total** | **≈ 300** |

  - The new radio0/hostapd read-back in §3.3 has no stated bound at all.
  - B3-M2(d) asked for exactly this budget; §14 answers with the sentence, not the arithmetic.
- **Fix**: for P3 verbs, the helper calls setkey with a short lock wait (a new `--lockwait N`, or an environment variable). The design writes the budget per constant (lock + settle + apply read-back + radio0 read-back + rollback + persist), with an explicit margin under 300 s, and the radio0 read-back gets its own constant. If the budget cannot fit, the rollback stays before the owner's request is answered (it already is), and the helper's deadline for `--rollback` calls is made longer than the computed worst case, with `HelperWait` raised to match. It must never be shorter.
- **Negative test**: hold `halow-setkey.lock` from another process for LOCKWAIT−5 s, and add a wbox fault that makes hostapd fail. key 20 returns reason 13 or `E_STORAGE` within the budget, and the AP is back in its previous state (blocked with the placeholder on a fresh node). Negative control: the same test with today's LOCKWAIT=90; the helper times out and the state is mixed.

### M3. The contract text contradicts itself, and H4 is written from this text first (D1)
Each of these gives H4 two different expected results, or points at a mechanism that was removed:
1. Legacy node, key 2:
   - §3.3 says "legacy 節點的 key 2、20 → `E_UNSUPPORTED{7}`", and the same row is in §5.1;
   - the §3.3 bullet says "legacy 節點**未入網時可以改國家**".

   Which one wins for key 2 on a legacy node that has not joined?
2. Upgrade to P3:
   - §6 says "升級到 P3 第一次開機 … helper `--boot` 看到版本變了執行一次 `--save`" (and so does §13 B2-m7);
   - §3.3 and §14 B3-m6 say "`--check` 視為 fresh … 不需要記上次版本".
3. Who opens HTTP:
   - §7 says "被入侵的 provd 自己開 HTTP: HTTP 開關由 helper 決定";
   - §2 and §3.8.1 say "備援由 provd 自己決定".
4. Deleting the upload file:
   - §6 says "provd crash … 上傳檔下次 provd 啟動刪";
   - the §4 cleanup table says "provd 重啟: 不刪(helper 是唯一刪除者)".
5. Deleting the diag bundle:
   - the §4 cleanup table says "provd 重啟 → session 全斷 → helper 刪";
   - §3.5 and §14 B3-m4 say "純到期,不靠 provd 通知".
6. Upload from the mesh (three different observable results):
   - §7 says "經 mesh → 403";
   - §8 `prov-upload-254` says "經 mesh → 17";
   - §5.1 says "nft 丟棄,到不了 provd;reason 17 保留";
   - §3.11-2 says "節點會以 reason 17 拒絕".

   With D19 the only real result is "TCP connect times out".
7. §8 `prov-http-254` says "mesh / eth 來源被 accept 時關閉". That is the accept-time check from v3, which v4 removed.
8. §6 says "依賴重啟: hostapd … client 快取 5 s 內更新". That is the v3 AP-client cache, which was removed; the mechanism is now `@ap_ports`.
9. §6 says "換 IP … 允許清單更新", and §3.8.1 says "`LocalAddr` 檢查保留". That is v2's allow-list mechanism. Say whether a LocalAddr check still exists and what it rejects.
10. §3.7.3 says "helper 啟動時 disarm tryboot(`batman-slot` 既有的 disarm 路徑)". There is no such CLI verb (see m5).
- **Fix**: one pass that makes §5, §6, §7 and §8 agree with §2–§3, and marks the §12–§13 rows that are superseded. Then H4 has one answer per path.

### M4. Most negative controls in §8 cannot be run: they name design variants that were never built
- **Evidence**: the controls in §8 and §7 are:
  - "負對照 = v3 的 IP→MAC 版本放行";
  - "v3 要求 radio up 的版本被還原";
  - "v3 版本 AP 開著";
  - "只寫 uci 的版本 FAIL";
  - "只看兩個欄位的版本不聽";
  - "不收候選的版本失敗";
  - "現行 autocommit commit 壞 provd 的版本".

  Only the last one exists as an artifact, along with "wsl.22 全部 `E_UNSUPPORTED`" and "現行 `batman-slot`". v1–v3 were designs and were never code.
- **Why it matters**: the owner's rule is that each claimed fix shows a test that fails **without the change**. A control that needs a never-built variant will be skipped in practice; the project's own history shows this (trimmed validation, `feedback_full_validation_no_trimming`).
- **Fix**: rewrite each control as one of:
  - (a) the shipped baseline (wsl.22, or the current main scripts);
  - (b) a test seam on the P3 build that disables exactly one guard, in the `BATMAN_FAULT_INJECT=` style that `batman-slot` already uses with `fault …` (`batman-slot:75`). Examples: "nft rule removed", "setkey `--rollback` skipped", "radio0 read-back skipped", "HealthOK uses only bluetoothd+hci0".

  List the seams in §10, and require the release gates to show they are absent from release images (the existing wbox / prov_test split).

---

## MINOR

m1. **The "fresh" rule for `--check` (§3.3) cannot be implemented as written, and it is not needed.**
- The rule says "live 值等於 `/rom` 預設". 04 has no `/rom/etc/config/wireless` (that file is generated at first boot), and the AP SSID comes from `99-halow-identity:19-21` (= hostname). So no real node ever equals a /rom default.
- `--check` compares whole files (`batman-config-save:474`, `cmp -s overrides.uci`), so the rule would be a new per-key comparator.
- It is unnecessary:
  - joinwatch runs `--on-join` every tick while the node is joined (`joinwatch:150`);
  - key 20 runs `--save` through setkey (`halow-setkey:165`), and pairing is required before an upload anyway.
- Drop the rule. State instead that an unjoined, never-paired node sees "p5 stale" after an ssh upgrade until it is paired.
- §6 "降級 … 無害" is also not exact: the old image's whole-file `cmp` reports `stale: identity-or-schema` until its next `--save` or `--on-join`. Joined nodes self-heal within a tick; unjoined ones block OTA until someone runs `--save` over ssh. Say so.

m2. **D15 does not require writing `radio0.country` and adding it to PRESERVE.**
- D15 is about the HaLow regulatory country.
- The effect on brcmfmac 5 GHz is unverified. 04 has `radio0.channel='36'` and `htmode='VHT80'`, and no country today.
- A country hint can remove channels and make radio0 fail to come up, which would send every country change down the rollback path.
- Either drop radio0 from key 2 (only the necessary changes), or probe on a bench Pi 4 first and record the result.

m3. **key 20 (and key 2, if radio0 stays in it) sent over the HTTP fallback cuts the channel that carries the request.**
- In fallback, BLE is broken by definition. The reload drops the phone's AP association, so the reply is lost. If a rollback happened, the app does not know which password is live.
- The contract should say one of:
  - key 20 is allowed only over BLE; or
  - §3.11 says the app retries association with the new credentials, then the old ones, and re-reads `settings/get`.
- Also note CYW43455 Wi-Fi/BT coexistence: reconfiguring radio0 may drop the BLE link too. Measure it in H4.

m4. **§3.6 "sign.peer 只會被短的 owner-op 擋住數秒" is false.**
- Every verb that is not read-only takes `n.mu.Lock()` (`node/node.go:189`). That includes `settings.set` (up to 300 s) and the `sign.static` / `psks.get` calls that every new handshake needs.
- So during key 20 / key 2, no new BLE or HTTP session can be established for up to 300 s. P2's `net.apply` already behaves this way; P3 adds more such verbs.
- State it in §3.6 and §6, and in the app requirements ("node busy, up to 5 min").

m5. **The new `batman-slot` CLI surface is not listed.**
- `disarm_tryboot` is internal only (`batman-slot:392`); the CLI has no `disarm` verb (`:895-915`).
- `reboot` must be called as `reboot committed` (`:889-891`). When the tryboot flag is set, it falls back to a plain `reboot` (`:871`, `:877-880`). That is what apply needs, but say that this is the command.
- Add `disarm`, `write`, `arm` and the boot-config read for key 8 (m13) to §5.3 and §10.

m6. **pending (30 min) can expire during an upload that stays within the rules.** At the minimum rate of 64 KiB/s (§3.8.1), 126 MB takes about 33 min, which is longer than the 30 min pending. `update.prepare` then returns reason 15 after a full upload. Either make the pending lifetime ≥ window + payload / minimum rate, or raise the minimum rate (for example 256 KiB/s, about 8 min).

m7. **Power loss after "write update-last" but before a successful arm** (the B3-m8 ordering). On the next boot, current = `from_slot` and boot_id ≠ `apply_boot_id`, so the node reports phase 6 "已退回" although nothing was tried. Record that the arm succeeded (a second write after `arm` returns rc 0, or check for the `SLOT ARM` line in `ota-trace.log`), and report 3 or 0 instead.

m8. **Lifecycle rows are missing for the new resources:**
- power loss during `settings.set`: uci is committed and the MARK changed, but nothing is persisted yet, so the node is not in its previous state. At least say what the next boot shows;
- helper restart while a setkey child is still running: the orphan holds the lock and the outcome is unknown;
- `service batman-provd restart` re-runs `start_service`, which mounts a second tmpfs over the first. That hides a payload that still uses RAM; the init script must check "already mounted";
- firewall stop / restart (see M1).

m9. **Bulk tmpfs mount options.** Specify `nodev,nosuid,noexec`, mode 0700 provd:provd, and the `size=` value. It is provd's only rw mount (F11), so state it in full.

m10. **The helper's `E_UNSUPPORTED{1: typ, 2: 7}` has no mapping.**
- `mapHelper` turns `hEUnsupported` into `{1: typ}` only (`provd/session.go:567-568`). §3.1.6 adds `reason` only for codes 24/25.
- Say that `reason` is also passed through for `hEUnsupported` (settings keys 10–13, legacy nodes, `status` scope 1), and add Go tests.

m11. **A lost HTTP response, without the idempotency cache.**
- Protocol §4.2 (`219-protocol.md:155-158`) tells the phone to resend with the same `idem_key`. P3 has no cache, and a resent Noise message fails AEAD, which aborts the session.
- §5.2 should say that every lost `/msg` response means a new handshake, a new `auth/owner`, and then the §5.2 re-read rule.
- `219-protocol.md` §4.2 should be edited to match. §10 lists it only as "刻意不做冪等快取的理由".

m12. **Closing `/cgi-bin/bundle` changes things for today's fleet.**
- All current nodes are legacy, and 04 has no dev-open (`ls /etc/batman-dev-open` → No such file). After P3, the report download on the status page returns 403 on every deployed node.
- That is fine as a decision, but say it in §6 (upgrade row) and in the release note, with the replacement: ssh, or the app's `diag/bundle` for nodes that have an owner.

m13. **The key 8 check reads the target slot's boot partition during `update.check`, and the mechanism is not specified.**
- Mounting the target FAT outside `batman-slot.lock` races a sysupgrade writer.
- Do it through a read-only `batman-slot` verb under its lock, and re-check at `arm`.

---

## Verified (✅, evidence)

- **F26 / F53 / F54**: 04 `ls -l /tmp/run` shows `batman` root 0700 and `batman-prov` root:provd 0750. `/opt/batdata/state/prov-state` = `20320ba1-… helper legacy legacy - today`.
- **CGI runs as root**: 04 `ps` shows `/usr/sbin/uhttpd … -x /cgi-bin` running as root, so §3.5 can read a 0600 file on p6.
- **Bridge ports**: 04 `bridge link show` shows eth0, phy1-ap0 and bat0 on br-ahwlan. The AP ifname from `network.wireless status` is `phy1-ap0`. The morse mesh is `wlh0`, which is not bridged.
- **No nft bridge table today**: `br_netfilter` is loaded (04 `lsmod`) with `bridge-nf-call-iptables=1`, and `nft list tables` shows no bridge table.
- **ctl / ops split and the `ro` connection**:
  - Today ctl is read-only and carries only the poll (`provd/server.go:343-412`). The PSK refresh and the keepalive run on ops, and only when ops is free (`:418-455`). The `ro` connection design is consistent with this.
  - The helper's read-only quota is 5/s burst 20 per connection and 10/s burst 40 helper-wide (`node/readonly.go:21-24`). ctl (~1/s) plus ro (≤ 5/s) stays under the global bucket.
  - `sock.MaxConns = 4` (`sock/sock.go:28`), so ctl + ops + ro + provclient fits exactly, with no spare. The design should say so.
- **arm is a one-shot flag**: `batman-slot` arm sets a one-shot vcmailbox flag (`batman-slot:716-738`). "Armed but not rebooted" is a real hazard, so B3-m8's disarm-on-start is justified.
- **SHA256SUMS covers overlays**: `build-ab-payload.sh:83` lists every `boot/` file, overlays included, in SHA256SUMS. "Copy only listed boot files" therefore does not drop overlays. The current order `root.squashfs boot metadata SHA256SUMS` (`:85`) is confirmed (F27).
- **provd survives a missing bluetoothd**: provd does not exit when bluetoothd is missing. Only `/tmp/run/dbus` must exist (`cmd/batman-provd/main.go:67-79`), and `preflight` checks only the advertisement length (`bluez.go:70-80`). So D18 (b) does not turn the known BT-UART wedge into a guaranteed revert.
- **D18 fits the trial window**: autocommit's dwell is NEED=3 × POLL=10 s, and MIN_WINDOW is 300 s (`batman-autocommit:31-34`). A 60 s `provd-stable` requirement fits in the trial window.
- **halow-setkey behaves as the design states**: the `--mesh -` stdin convention (`:64-65`), the placeholder refusal (`:83`), and the keyguard release before commit (`:262-276`).

## Convergence

Yes, this is converging. v4 removed mechanisms instead of adding them: the IP→MAC check, the per-accept helper query, `bulk.done` and the version-tracking resource are gone. The remaining MAJORs are:
- a missing fail-closed condition on the new filter;
- an unproven time budget;
- text consistency;
- the feasibility of the test controls.

Fixing M1–M4 is document-level work plus one small check on the helper before it publishes `http.2`. If no new mechanism is added, I expect the next round to be APPROVE-WITH-CHANGES.
