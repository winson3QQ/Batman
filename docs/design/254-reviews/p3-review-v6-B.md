# #254 PR-P3 design v6 — review B

Design: `docs/design/254-p3-impl.md` @ c252b3f (branch feat/254-p3, base main 2ecf1cb). Node 04 = `1.5.14-wsl.22`, legacy. Everything on 04 was read-only (show / list / cat / grep / readlink); nothing was written there, not even in /tmp.

**Verdict: REJECT (narrow, close to converged). 0 BLOCKER, 2 MAJOR, 14 MINOR.**
Both MAJORs are the kind the v5 round warned about: a sentence saying "other code behaves like X" that the evidence contradicts. Each fix is a few lines and needs no new mechanism. Once M1 and M2 are fixed, the MINORs can go into the implementation PR, each with its test, and the design can be frozen.

---

## MAJOR

### M1. Key 2 (country) checks that "radio1's current channel is legal in the new country". Every fresh node sits on US channel 40, so it can never switch to an EU / JP / KR / IN country, and D9 then refuses the join. The country feature works only for US-plan countries.

- **Scenario**: a fresh card is claimed, and the network's `net_config` key 5 is `EU`. D9 and §3.11-7 say the app must first send `settings/set` key 2 = `EU`. §3.3 then checks "radio1 目前的頻道在新國家合法" (radio1's current channel is legal in the new country). The current channel is the image default 40, which is not an EU channel, so the request is rejected with reason 13. Without the country change, `network/join` is rejected with reason 14 (§3.3 "國家與入網"). There is no way out through the app. The same dead end exists for JP, KR and IN.
- **Evidence**:
  - The image default on a fresh card is channel 40 / country US: `meshpoint-1.8.0:21,49-50` (applied by `94-batman-baseline`).
  - The morse regdb on 04 (`/usr/share/morse-regdb/channels.csv`, column 5 = s1g_chan) lists these legal channels: `EU: 1 3 5 7 9 2 6`; `JP: 9 13 15 17 19 21 2 4 6 8 36 38`; `KR: 1 3 5 7 9 11 2 6 10 8 18 20 22 24 19 23`; `IN: 5 7 9`. Channel 40 is in none of them. Only US / AU / NZ / SG / CA / BR / AR / CO / XA have it.
  - The check is not needed. Key 2 is allowed only while radio1 is blocked (F74, D20), so nothing transmits on the "illegal" channel. At join, setkey already validates `--channel` against the radio's country in the regdb (`halow-setkey:88-100`: `channel $CHAN is not a legal S1G channel for country $CC` → exit 2) and reads the frequency back from the chip (`:349-374`).
- **Fix**: drop the "current channel legal in the new country" condition for key 2, and keep "2 uppercase letters, present in the regdb". Make the join the place that validates the channel, which it already is: if net_config's channel is not legal for the country, reject before writing anything, mapping setkey's `--check-only` to reason 13. Test (`prov-country-join-254`): fresh node (channel 40 US) → key 2 = a country whose channel plan differs (see m12) → succeeds; join with that country's legal channel → succeeds. Negative control: v6 as written (reason 13 at key 2).

### M2. §6 "helper 重啟時 setkey 子程序還在跑" (setkey still running when the helper restarts) and §3.3 claim the setkey child "holds the lock, runs to the end and does its own `--rollback`". In fact setkey is killed by SIGPIPE at its next stdout line, so the "failed change goes back to the previous state" path breaks at that point.

- **Evidence**:
  - `provstore.Exec` points the child's stdout and stderr at a `bytes.Buffer` (`provstore/exec.go`: `c.Stdout, c.Stderr = &out, &out`). Go reads that through a pipe that lives in the helper process, so when the helper dies, the read end closes.
  - On 04 the helper has `SigIgn: 0000000000000000` and `SigCgt: fffffffc7fc1feff`. SIGPIPE (bit 12) is caught, not ignored, and execve resets caught signals to the default. So setkey (busybox sh) runs with the default SIGPIPE action: its first `echo` after the helper dies terminates it.
  - `halow-setkey` has no `trap` (grep finds none) and prints progress lines between commit, readback and persist (for example `:311`, `:375`, and the `echo` in persist).
  - `Setpgid` (F72) only stops the group SIGTERM from reaching it. It says nothing about the pipe.
- **Effect**: a helper crash during key 20 or key 2 leaves an arbitrary intermediate state: new value committed but not read back or persisted (live new, p5 old → reason 17 blocks OTA), or a rollback stopped halfway. The §6 row and its test (`prov-settings-254`) assert a self-completed rollback that will not happen, so the test will either FAIL or pass vacuously.
- **Fix** (pick one, both small):
  - (a) Make the premise true. Before the lock, setkey runs `trap '' PIPE` (writes then fail with EPIPE and the script continues) and also copies its progress lines to `$RUNDIR/halow-setkey.last` so the restarted helper can read the result. Keep the §6 row.
  - (b) Rewrite the row honestly: "after a helper crash the outcome is unknown and may be half-applied → the app sends the same `settings/set` again (same value → no reload; p5 stale → `--save`, §5.2)", and drop "自己 --rollback".

  Either way, add a white-box test: kill the helper while setkey sits between commit and readback, then assert the final state is entirely the old or the new value, with p5 equal to live. Negative control: the current setkey (no trap), which shows the half-applied state.

---

## MINOR

1. **Contract for update-last is inconsistent (one answer per path)**:
   - §4's cleanup table says "update-last | 下一次 check 通過時覆寫" (overwritten at the next check that passes); §3.7.4 says "update-last 只有 update.apply 寫;update.check 不碰它" (only update.apply writes it).
   - The §5.3 format lists only `{from_slot, from_version, to_slot, to_version, sha, apply_boot_id, armed}`, without the `bad_slot_at_apply` and `rebooting` fields that §3.7.4 relies on.
   - §3.7.3 gives `arm <sha>`, while §3.7.4 calls `arm <sha> <key8 清單檔>` (key 8 list file).

   Fix: make all three match.
2. **Latent tryboot after a crash between the `arm` rc and `armed: true`.** `batman-slot arm` sets the VideoCore tryboot flag (`vcmailbox 0x00038064`, `batman-slot:716-738`). If the helper dies after a successful arm but before it rewrites `armed: true`, the startup rule only disarms when `armed: true`. The flag stays set, so the next unrelated reboot (operator, power button, watchdog) starts the trial unannounced.
   - Fix: on helper start, if `apply_boot_id` equals the current boot_id, always run `batman-slot disarm` (idempotent), whatever `armed` says.
   - Also: losing power after `rebooting: true` but before procd shutdown finishes (with docker/OTS that takes tens of seconds) is reported as "6 + 18, the new version did not boot". The app text should say "did not boot, or power was lost before the restart".
3. **`--ap -` does not keep the passphrase off command lines.** setkey writes keys with `uci -q set "wireless.$s.key=$AP"` (`halow-setkey:283,287`), so the passphrase is in uci's argv for a few milliseconds. Sampling `/proc/*/cmdline` will usually miss that, so the test is non-discriminating.
   - Fix: write the AP key through `uci batch` on stdin, and test deterministically (a uci shim in the prov_test image that records argv).
   - Negative control: the current `uci set`.
   - The §7 table should still say plainly that `/etc/config/wireless` and the hostapd conf are 0644 (F34), so a local process can read the key anyway. The cmdline fix is hygiene, not a boundary.
4. **The `phy*` premise check needs three precise conditions.**
   - (a) The bridge-family input hook applies to every bridge on the host (04 has br-ahwlan, br-ots and docker0), so the check must list `/sys/class/net/*/brif/*` on all bridges, not just one.
   - (b) "radio0 mode=ap" should be "the iface of section `default_radio0`". A second radio0 AP (guest SSID) would otherwise also reach 8095.
   - (c) The check must also require that `default_radio0`'s ifname matches `phy*` and is a port of `br-ahwlan`. If an `ifname` override (for example `wlan0`) made the premise pass with no phy port at all, the helper would hand out `http.2`, provd would listen, and the owner would be silently dropped.

   Add a Go test with fake wireless status and brif lists, plus a seam that skips the check.
5. **setkey rc contract.**
   - setkey exits 2 both for "lock busy" (`:134`) and for invalid input (`validate()`).
   - It exits 3 both for "unverified" and for "persist failed".

   So the helper cannot produce §5.1's split between `E_BUSY`, reason 13 and `E_STORAGE`. Define distinct rcs for the new flags (busy, rejected, unverified-restored, persist-failed) and list them in §5.3.
6. **Timing in the test does not add up.** "`nft delete table` → ≤ 4 s 不聽" (provd stops listening within 4 s) ignores the 4 s background nft check, the 4 s poll and the 10 s staleness rule (§3.8.1). The worst case is about 8 s (fail-closed at 10 + 4 s). Assert ≤ 12 s, or derive the number from the constants.
7. **Facts to correct (the mechanism is not affected).**
   - F74 cites `node.go:1125` as "入網才設 RadioManaged = true" (set only on join). A claim from unclaimed already sets it true at `node.go:539` (`next.RadioManaged = rec.State == provstore.Unclaimed`). That line is what keeps key 20 on a freshly claimed node from being refused.
   - §3.8.1 says "不用 br_netfilter" (br_netfilter not used). On 04, `br_netfilter` is already loaded and `bridge-nf-call-iptables = 1` / `ip6tables = 1` (docker). Bridged traffic already passes through inet hooks today. The bridge-family rule is still correct (see the verified list).
8. **Reason 7 ("parameter not supported by this hardware", `219-protocol.cddl:126`) is overloaded.** It is used for legacy key 2/20 (D20), key 20 over HTTP, `status` scope 1 and keys 10–13. The app needs different actions: "use BLE", "re-flash and re-claim", "not available". Add new reason codes (for example 19 legacy, 20 needs BLE), or write the app mapping into §3.11.
9. **`update.apply` gaps.** Its rejection mapping (§3.7.4, §5.1: 11 / 12 / 1 / 5) has no 17, although `arm` reruns `node_checks`, which includes p5 freshness. And if p6 is not mounted, the update-last write fails; apply must then refuse (fail-closed) and not arm.
10. **Order of upload-file deletion vs. the worker.** §3.8.2 deletes the upload file every poll cycle while no window is open, and prepare closes the window. Write down that the worker opens its fd *before* the window closes, and that the "outside the window" deleter skips while `updating` is set. Otherwise the deleter can race prepare (the file vanishes before the fd is opened) and the result is a spurious reason 15.
11. **provd-stable says "只看 ctl 那一條" (only the ctl connection) but nothing can tell ctl apart.** F65 says ctl, ro and ops are indistinguishable. After the PPid / uid / exe check, ctl, ro and ops all belong to provd. Write "any connection from the provd process held for 60 s"; that is also what the test can check.
12. **The country tests cannot discriminate within US-plan countries.**
    - Channel 40 is 922.0 MHz in US, AU, NZ, SG, CA, BR, AR, CO and XA alike (04 regdb). "morse 頻率 = 該國 regdb" (morse frequency matches that country's regdb), and the §9-3 probe "morse 真的換表" (morse really switches tables), cannot show a table switch with these countries.
    - They need a country with a different channel plan (EU / JP / KR), which first requires M1.
    - Transmitting EU or JP frequencies on a bench in Taiwan raises a radio-regulation question. The owner should decide how (conducted with an attenuator / shielded box / not at all). Write it into §9-3.
13. **The key 20 assertion "morse plink 不斷" (morse plink stays up) is vacuous on a fresh node**, because radio1 is blocked there and has no plink. It must run on a joined node (the D17 lost-phone re-key path, team on TAK). Also, setkey's fallback `wifi reload … || wifi` (`halow-setkey:366`) restarts every radio, morse included. The new `--ap` path should not have that fallback, or should document it.
14. **Details and wording.**
    - In the include, prefer `table bridge batman_http {}` + `delete table bridge batman_http` + redefine over flush + redefine. Flush keeps the old base-chain definition, so a later image that changes the chain's priority or policy would make the whole fw4 transaction fail (F70).
    - Write the `auto_includes '0'` option (`/usr/share/nftables.d/README` on 04: the operator can turn includes off) into §6 / §7. Its result is fail-closed (no table → no listening).
    - The rc gate can call the built-in `fw4 check` directly (`/sbin/fw4`: `print | nft -c -f`).
    - §9 is numbered 1…7, 9, 8.

---

## Verification of v6's evidence (✅ = I checked it myself)

- ✅ **F60, L2 rule kernel premise.** The bcm2711 and bcm2710 `nft_chain_filter.c:229` use `#if IS_ENABLED(CONFIG_NF_TABLES_BRIDGE)`. `nm nft_chain_filter.o` on both boards shows `nft_do_chain_bridge` and `nft_chain_filter_bridge`. On 04, `/proc/config.gz` shows `CONFIG_NF_TABLES=m`, `CONFIG_NF_TABLES_BRIDGE=m`, `CONFIG_NETFILTER_FAMILY_BRIDGE=y` and `CONFIG_BRIDGE=y`. kallsyms has no static symbols (modules are stripped; `nft_do_chain_inet` is missing too), so it proves nothing either way. The build objects are the evidence.
- ✅ **`iifname` at bridge input = the port.** `br_input.c` `br_pass_frame_up`: `indev = skb->dev; skb->dev = brdev; … NF_HOOK(NFPROTO_BRIDGE, NF_BR_LOCAL_IN, …, indev, NULL, …)`. `nft_do_chain_bridge` sets the L4 info for IPv4 / IPv6 (`ipv4/6_validate`), so `tcp dport` matches.
- ✅ **Paths that bypass the bridge are closed by fw4.** On 04, `wlh0` (802.11s, fe80 only) is not a bridge port, and the `inet fw4 input` chain is `policy drop` and jumps only for `br-lan` / `br-ahwlan` / `docker0` / `br-ots`, everything else going to `handle_reject`. docker0 currently has no ports, and container veths hit the bridge hook and are dropped. rp_filter = 0 does not matter, because the zone policy covers it.
- ✅ **F70 / F59.** `/sbin/fw4` start / reload = `utpl -S main.uc | nft -f` (a single transaction); `ruleset.uc:8-9` is `table inet fw4` / `flush table inet fw4`, with `ruleset-post` included after the table (README). `restart` checks with `nft -c` first and `start` does not. `flush` deletes every table.
- ✅ **F11.** `ubus service list` gives instance pid 8388 = `/sbin/ujail` (uid 0, PPid 1). provd 8414 has `PPid: 8388`, `Uid: 471`, `NSpid: 8414 1`, and exe `/usr/bin/batman-provd`. `/etc/init.d/batman-provd enabled` → 0.
- ✅ **Read-only verbs do not take `n.mu`** (`node/readonly.go:1-8`, `node.go` dispatch). The 230 s `settings.set` therefore does not block the ctl poll.
- ✅ **`99-halow-identity` does not overwrite a restored SSID** (`/etc/.batman-p5-restored` → exit 0). On an OTA slot the PRESERVE'd SSID survives.
- ✅ **`prov-state` format** on 04: `<boot_id> helper legacy legacy - today`; field 1 = current `boot_id`, field 3 = `legacy`; no `/etc/batman-dev-open` (F54, F68).
- ✅ **`/tmp/.uci/*` are all 0 bytes on 04**, so the "non-empty → `E_BUSY`" rule must test size, not existence (§3.3 says "非空", non-empty, which is correct).
- ✅ **CDDL `net-config` key 5 `country` is required** (`219-protocol.cddl:324`), so D9's comparison always has a value.
- ✅ **`nft -j` is available** (nftables 1.1.1, JSON). On 04, `nft list tables` = ip filter/nat, ip6 filter/nat, inet fw4 (no bridge table yet).
- ⚠️ **Not verified (a write would be needed):** that the bridge table actually loads and drops on 04, i.e. the §9-4 probe. Kernel and source evidence is sufficient for the design; the functional test stays a pre-implementation item that needs consent, as the design says.

## Judgement on the §9 deferrals

| # | Judgement |
|---|---|
| 1 U5 rename | ✅ Reasonable: key 1 stays `rename-pending`, no unverified rename ships. |
| 2 YubiKey | ✅ The node only depends on ES256 + low-s (normalising s → n−s is valid). Host side only. |
| 3 morse country table switch | ⚠️ The deferral itself is fine and the fallback paths are defined, but it cannot be run as written: M1 (a different-plan country cannot be set) and m12 (US-plan countries do not discriminate, plus the regulatory question). |
| 4 bridge rule functional test | ✅ OK to defer: kernel / source evidence is complete (above), and a write needs consent. |
| 6 tmpfs `size=` | ✅ Pi 3 is not supported for now (CM4 decision); it is on the checklist. |
| 7 setkey flags | ⚠️ Deferring is fine, but first settle the rc contract (m5), SIGPIPE (M2) and argv (m3) in the design. These are interface definitions, not implementation details. |
| 8 / 9 | ✅ |

## Check of the v5 fixes (regression)

- **A5-M1 / B5-M1 `phy*`**: correct per F69, and the bridge-hook evidence holds (see the verified list). The remaining premise details are m4.
- **A5-M2**: flush + `nft -c` + boot assertion are sufficient (m14 suggests a more robust idiom).
- **A5-M3 / B5-M2**: PPid / uid / exe verified on 04 ✅ (m11 is wording).
- **A5-M4 / B5-M4**: D20 resolves them. The F74 evidence text is wrong but the conclusion holds (m7).
- **B5-M3 `--rollback-only` removed**: correct, but the replacement sentence brings a new false premise (M2).
- **v5 MINORs**: spot-checked B5-m3/m4/m5/m8/m11/m12 — all written in. A5-m6 `bad_slot_at_apply` is in §3.7.4 but missing from §5.3 (m1).

## Convergence

The architecture (fw4-loaded bridge rule + helper-gated `http.2` + Go white-list parsing + `batman-slot write/arm` + two-tier keys) has converged and is backed by evidence. The two MAJORs are local premise errors: one condition to delete in M1, and in M2 either one `trap` or one honest sentence. After they are fixed, a re-review should reach APPROVE; the 14 MINORs can go into the implementation PR, each with its test.
