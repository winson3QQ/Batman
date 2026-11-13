# #254 PR-P3 design v7 — review B

Design: `docs/design/254-p3-impl.md` @ bfb6703 (branch feat/254-p3, base main 2ecf1cb). Read in full. Sources: Batman-p3 tree, firmware-2710 build_dir (kernel 6.6.138 bcm2710 tree, procd 2026.03.14, nftables 1.1.1). Nodes 04 (10.41.1.3) and 02 (10.41.1.1), both `1.5.14-wsl.22`: read-only only (show / list / cat / grep / type). Nothing was written on either node, not even in /tmp.

**Verdict: APPROVE-WITH-CHANGES. 0 BLOCKER, 0 MAJOR, 12 MINOR. The design has converged and can be frozen.** The two v6 MAJORs (B6-M1 country channel deadlock, B6-M2 SIGPIPE) and A6-M1 (VLAN) are fixed, and I checked the fixes against source. I found no mechanism that fails to work, fails open, or loses a previous state in the field. Each MINOR below is a contract or test detail that the implementation PR can fix with its own test. One condition carries over from D22: the §9-4 probe (positive arm + VLAN arm) must finish before H4 is frozen, and if its fallback is taken, the fallback delta needs its own review (m2).

---

## Verified (✅ = I checked it myself, with evidence)

**The new HTTP source rule (bridge mark + inet input drop)**
- ✅ **The mark set at bridge LOCAL_IN reaches the IP input hook (the positive path; the design marks it ⚠️ untested).**
  - `net/bridge/br_input.c:59-72` `br_pass_frame_up`: `indev = skb->dev; skb->dev = brdev; … NF_HOOK(NFPROTO_BRIDGE, NF_BR_LOCAL_IN, …, indev, …, br_netif_receive_skb)`. So `iifname` is the port, and the same skb then goes to `netif_receive_skb`.
  - Nothing on that path clears `skb->mark`. `skb_scrub_packet` clears the mark only when `xnet` is true (`net/core/skbuff.c:5876-5896`). `br_nf_local_in` (`br_netfilter_hooks.c:602-630`, priority LAST) touches conntrack only.
  - The source supports the design, so if the probe fails the cause will be something else and must be found, not assumed.
- ✅ **Containers cannot bring a forged mark in.** veth → `____dev_forward_skb` → `skb_scrub_packet(skb, !net_eq(...))` (`include/linux/netdevice.h:4111`), which clears the mark across netns. Only a host-netns process with CAP_NET_ADMIN (SO_MARK) can set it, and that process is root-equivalent.
- ✅ **"No other fwmark user" holds on 04 too.** The design cites 02 only. 04 has 0 hits for `mark` in both `nft list ruleset` and `iptables-save` (iptables is `nf_tables` 1.8.10). `ip rule` has only local / main / default. `tcp_fwmark_accept`, `fwmark_reflect` and `src_valid_mark` are all 0. So the bit has no routing side effects.
- ✅ **02 after the F75 probe:** `nft list tables` = ip filter/nat, ip6 filter/nat, inet fw4. No leftover table, no mark rule, no `ruleset-post/` directory. The cleanup claim holds.
- ✅ **04 bridge ports:** br-ahwlan = eth0, phy1-ap0, bat0; br-ots = 5 veth; `vlan_filtering 0`. The premise check has the inputs it needs.
- ✅ **procd stops the helper by pid only** (`procd service/instance.c:802,898,916`: `kill(in->proc.pid, …)`), and the helper's SIGTERM handler is just `os.Exit(0)` (`cmd/batman-provhelper/main.go:621-623`; it does not kill children). After the `trap '' PIPE` change, a setkey started by the helper therefore really survives a helper stop or crash. `provstore.Exec` kills the group only on its own timeout (`exec.go:37-42`).
- ✅ **`trap '' PIPE` is enough for setkey.** `halow-setkey` has no `set -e`, and `echo` / `printf` are ash builtins on 04 (`type`). A failed write returns 1 and the script goes on. The persist step captures `config-save` output through `$(…)`, which is its own pipe.
- ✅ **`uci batch` keeps the passphrase out of argv.** `printf` is a builtin on 04, so `printf … | uci batch` leaves the secret only in the shell's memory and in a pipe.
- ✅ **B6-M1 fix: the channel is validated at join.** P2 always passes `--channel`: `node.go:981` `p.channel = fmt.Sprint(chU)` feeds `SetKeyNoPersist` → `--channel` (`main.go:146-158`). setkey checks the channel against `uci get wireless.$RADIO.country` (`halow-setkey:89-99`) and reads the frequency back (`:349-374`). The join precheck `CheckRestorable` is skipped while the key is the placeholder (`node.go:1110-1118`), so a fresh or left node on channel 40 / `DE` is not refused there either. The B6-M1 deadlock is gone.
- ✅ **regdb on 04 has `DE` and `EU` as separate rows** (52 codes, including AT…XB). The `DE` test in `prov-country-join-254` is runnable.
- ✅ **96 `valid_batch` accepts an SSID with spaces.** `$2` is split at `=`, and the UNSAFE set is the same (`96-batman-config-migrate:33-46`, `batman-config-save:53,453-462`). The new PRESERVE key cannot break the p5 restore.

---

## MINOR

1. **The VLAN arm and its negative control as written do not discriminate. F76 is only half right.**
   - The kernel removes a single 802.1Q tag *before* the bridge rx_handler: `net/core/dev.c:5528-5531` `if (eth_type_vlan(skb->protocol)) skb = skb_vlan_untag(skb);`. The bridge hook then sees `h_proto = IPv4`, so the v6 rule (bridge `tcp dport`) **does** drop a singly tagged SYN.
   - The frame that actually got past v6 is a stacked tag with VID 0 outside. The bridge sees `h_proto = 0x8100`, which leaves L4 unspecified (`nft_chain_filter.c:239-248`). On the br-ahwlan round, `dev.c:5608-5631` clears the VID 0 tag and strips the inner tag. A frame with VID ≠ 0 becomes `PACKET_OTHERHOST` and is dropped anyway.
   - Effect: if H4 sends single-tagged frames, the "load the v6 rule → VLAN arm FAIL" negative control passes, and the arm proves nothing.
   - Fix: the VLAN arm sends a stacked VID 0 / VID 0 frame (outer 0x8100 or 0x88a8), from eth0 and from a docker0 container (NET_RAW is enough). Before trusting the arm, show that the v6 rule lets it through. Correct F76 to say "stacked tags (VID 0 outside)". v7's mark approach drops every case regardless.
2. **§9-4 fallback: write down what changes if it is taken.** Falling back to the bridge-layer rule loses the lo protection: lo never passes the bridge hook, so the §7 "本機行程(lo)" row goes back to an honest boundary. Also, `ether type {8021q, 8021ad} drop` on non-phy ports must be at bridge input. Fix: say in §9-4 that taking the fallback flips the §7 lo row and the `prov-http-254` lo arm, and that the delta goes to a short review before H4 is frozen. Also cite the kernel evidence above as the reason the positive arm is expected to pass.
3. **The mark bit is a new shared resource, but §4 and §5.3 do not list it.**
   - §4 and §5.3 name only `bridge batman_http`. `inet batman_http_in` and bit 0x01000000 of `skb->mark` are missing.
   - Today no other writer exists (✅ above). But a later package that sets that bit on every packet (a QoS / pbr / CNI-style mark with a broad mask) would make the drop fail open, silently.
   - Fix: add both to §4 (owner = `batman-http.nft` through fw4; readers = kernel, helper). In the helper's 4 s check, also refuse `http.2` when any other rule in the ruleset writes `meta mark` / `ct mark` with that bit (one `nft -j list ruleset` scan). Add a Go test with a fake ruleset.
4. **Test spec: the `prov-http-254` mesh arm asserts something the network cannot guarantee.** The arm says a host on eth0 using the phone's MAC + IP (with ARP poisoning) runs at 50 conn/s, and "AP 上的擁有者完成上傳" (the owner on the AP finishes the upload) in the same arm. A cloned source MAC makes the br-ahwlan FDB move the phone's MAC to eth0. The node's SYN-ACKs and ACKs to the real phone then leave through eth0, and the upload stalls. That is a generic L2-poisoning DoS on a flat bridge, not a P3 property. The arm would FAIL or flap, and then need an attribution. Fix: split it.
   - (a) MAC + ARP spoofing from eth0 → TCP to 8095 is never established, and the drop counter grows.
   - (b) IP spoofing *without* cloning the MAC, plus 50 conn/s → poll has no ERate, BLE stays advertising, and the AP owner finishes.

   Write the MAC-clone DoS into §7 as an honest boundary ("anyone on the mesh L2 can disturb the AP owner's traffic").
5. **setkey exit codes for the new flags still collide with the existing rc 2.** Today rc 2 also means:
   - settle-gate timeout (`halow-setkey:150-152`);
   - run dir / flock unusable (`:129-131`);
   - `.txn` present while persisting (`:139-141`).

   In §3.3 these map to reason 13 ("value not valid"), so a transient netifd reconfiguration would be shown to the user as a bad value. Fix: for the new flags, give settle-timeout and run-dir the same code as lock-busy (5 → `E_BUSY`), and `.txn` a code of its own (→ reason 12). Add a test: a stub `wl_wait_settled` that never settles → `E_BUSY`.
6. **The "rollback also failed" outcome is undefined.** §3.3 lists 3 = "readback failed, **restored**". It has no code for "readback failed and the restore did not verify either". Two cases:
   - On a joined node, the app would say "restored" while the AP runs on neither the old nor the new settings.
   - On a fresh node, rollback = placeholder + `disabled=1`, verified "AP 不在空中" (AP not on the air). If that check fails, a hostapd may be on the air with the **public** placeholder `CHANGE-ME-NOW` until keyguard blocks it at the next boot. This is the same pattern as `--forget-mesh`, which has an escalation (`:237-267`); the AP path has none.

   Fix: a distinct rc (for example 6 = "restore unverified, outcome unknown") → `E_STORAGE`-class / outcome-unknown, so the app re-reads. For the fresh-node case, add an escalation of `wifi down radio0` / a radio0 `disabled` re-check, plus a seam test (readback-skip + rollback-verify-fail) asserting that no AP beacons with the placeholder.
7. **An SSID that cannot be saved still makes `--save` return rc 6, which breaks key 2.** §3.3 says an SSID with UNSAFE characters is "不持久化、不算 stale" (not persisted, not counted as stale). But `--save` returns 6 whenever `REJECTED` is non-empty (`batman-config-save:461`; the `--check` path exits 5 on any REJECTED, `:486-488`). setkey's persist maps 6 to "PARTIAL", rc 3 (`halow-setkey:168`), which v7's new codes would turn into 4 / `E_STORAGE`. So on such a node every key 2 change is rolled back. Fix: the SSID-only rejection gives rc 0 from both `--save` and `--check` (it is reported in `status` only). Test: SSID `Tom's AP` → key 2 succeeds and `--check` reports fresh. Also, `:478` cited in §3.3 for the empty-value rule is the wrong line (it is around `:459`).
8. **The first P3 boot after `sysupgrade` is a trial, so the "save once for new PRESERVE keys" does not run.**
   - §3.3 saves "在非試用的開機時" (at a non-trial boot) and at `update.check`. Every boot right after an A/B write is a trial (F20, F19 arm). So an unjoined node stays stale until its next reboot or an app `update.check`.
   - Until then, an operator's next `ssh sysupgrade` is refused by `precheck-node` (p5 freshness).
   - The upgrade arm "P2 未入網節點 sysupgrade 到 P3 → `--check` fresh" passes only if the test reboots first.

   Fix: also save when the helper's trial cache flips from trial to committed (`newTrialCache` already polls `is-trial` every 5 s, `main.go:596`), and assert "fresh within 30 s after COMMITTED, with no reboot".
9. **The bad-slot evidence still misreports a repeated failure** (the first half of A6-m5; Appendix C answered only the disarm half). autocommit writes `slot=$SLOT version=$(version)` (`batman-autocommit:195,244`). A retry of the same version that fails again writes identical content, so "與 `bad_slot_at_apply` 不同" (differs from `bad_slot_at_apply`) is false, and the result is 6 + 18 ("did not boot") instead of 6 ("unhealthy, reverted"). Related: if `batman-slot reboot committed` returns non-zero after `rebooting: true`, the tryboot flag stays armed in the same boot. Fixes:
   - (a) Compare the `aclog` `TRIAL-REVERTED boot=<id8> slot=… version=…` line of the boot after apply, or have autocommit append a boot id to bad-slot. If you do that, keep the `:361` grep anchored on the first two fields.
   - (b) A failed reboot command → `disarm` + phase 3 + reason 15.

   Test: install the same bad version twice → 6 both times.
10. **The `/proc/*/cmdline` test cannot fail.** Sampling every 10 ms misses a `uci set` that lives for 1–3 ms, so the negative control (the old `uci set …key=$AP`) would usually pass, and the assertion proves nothing. Fix: in the prov_test image, wrap `uci` (via a seam) with a shim that records argv, and assert that no argv contains the passphrase. The negative control is the current `--ap <psk>` / `uci set` path, which the shim catches deterministically.
11. **Leftover inconsistencies in the document.**
    - §5.1 `update.apply` arm failure still says `E_REJECTED{2: 11 / 12 / 1 / 5}`. §3.7.4 and Appendix C say 17 was added.
    - §3.4 key 15 does not list `uci_staged` (§5.1) or "SSID 無法保存" (SSID cannot be saved, §3.3).
    - §2's `http` field and §5.3 still say "nft 表 `bridge batman_http`" (one table), while §3.8.1 checks two.
    - Whether `update.check` holds `n.mu` (it runs `precheck-node` and `bootcfg-sum` up to 30 s) is not stated. §3.1.5 covers only prepare.

    Fix each in place.
12. **The `phy*` premise does not require the AP to be bridged.** The helper's check makes every `phy*` port the `default_radio0` iface. If radio0's AP is not a port of any bridge (a routed AP set by an operator or openmanetd), no frame gets marked: provd listens and the owner is silently dropped. This fails closed but cannot be diagnosed. Fix: also require that the `default_radio0` ifname is a bridge port; otherwise withhold `http.2` and report it in `status`. Add a Go test with a fake brif list.

---

## F75: what the probe proves, and what is left

- **It proves:**
  - Both rules load on the shipped userland (nft 1.1.1, wsl.22) without `kmod-nft-bridge`.
  - A SYN that enters through bat0 is dropped (timeout instead of RST, counter 7).
  - lo is dropped.
  - Removing the tables restores the baseline (and 02 is clean now, ✅).
- **It does not prove:**
  - (a) That the bridge rule runs at all. Nothing was marked and nothing was observed passing, so the same outcome would appear with a no-op bridge chain.
  - (b) The positive path.
  - (c) Loading through the fw4 `ruleset-post` include, and the `delete table` re-create on `fw4 reload`.
  - (d) The VLAN arm.
  - (e) bcm2710.
- **What covers each gap:** (b) and (d) are D22 / §9-4. Source evidence supports (b), and m1 fixes the test for (d). (c) is covered by the rc `nft -c` gate and the `prov-http-254` "reload → one copy each" arm. (e) is not supported for now (CM4 decision), so this is acceptable.
- **Add to the §9-4 probe:** the bridge chain counter grows for an AP client while it connects. That closes (a).

## Judgement on the §9 deferrals

| # | Judgement |
|---|---|
| 1 U5 | ✅ Key 1 stays `rename-pending` (§3.3, §5.1); no unverified rename ships. |
| 2 YubiKey | ✅ The node depends only on ES256 + low-s. |
| 3 country on the chip | ✅ Closed by D21. It is an honest boundary, not harmful: the join readback compares the chip frequency with the regdb, so a chip that did not switch tables fails the join and is restored. A brief emission before the readback is the boundary the owner accepted. |
| 4 HTTP rule probe | ✅ Only with the conditions in m1, m2 and the counter above, and only before H4 is frozen. If the probe fails, the result is fail-closed (no HTTP; BLE still works), not exposure. |
| 6 tmpfs size | ✅ |
| 7 setkey flags | ⚠️ Acceptable, but the rc gaps (m5, m6) are interface definitions; settle them in the implementation PR's design note before coding. |
| 8 coexistence | ✅ A BLE drop during key 20 is covered by §5.2 (re-handshake, `settings/get`). |
| 9 reflash 02 / 04 | ✅ |

## Check of the v6 fixes (Appendix C)

- **A6-M1:** fixed, and stronger than needed (✅ kernel evidence above). Test discrimination: m1.
- **B6-M1:** fixed (✅ the join path validates; the `DE` row exists).
- **B6-M2 / A6-m1:** fixed (✅ trap is enough; procd kills the pid only).
- **A6-m3 answer** (pending + same boot_id needed for phase 3 and arm): ✅ correct. A pre-P3 `batman-slot` only runs in another boot, where pending is gone, and P3's `begin_write` deletes VERIFIED.
- **A6-m5:** half answered (m9).
- **B6 `update.apply` 17:** only partly written in (m11).
- **B6 cmdline:** `uci batch` ✅, but the test does not discriminate (m10).
- **The other Appendix C rows** (phy* scope, ≤ 8 s, reasons 19 / 20, fd-before-close, provd-stable "any connection", `delete table`, `auto_includes`, key 20 plink on a joined node, F74 citation): spot-checked, all written in.
- **D1–D22:** no decision found harmful. D20 / D21 are honest boundaries and the text says so.

## Convergence

The architecture is unchanged since v5, and every external-behaviour premise it relies on now has source or live evidence:
- fw4-loaded rules plus the helper-gated `http.2`;
- the Go white-list tar parse;
- `batman-slot write` / `arm`;
- the two-tier keys;
- setkey `--rollback` under `trap`.

v7's three local fixes are correct. None of the 12 MINORs needs a new mechanism. **Freeze v7**, carry m1–m12 into the implementation PR with their tests, and finish §9-4 (with m1, m2 and the counter) before H4 is frozen.
