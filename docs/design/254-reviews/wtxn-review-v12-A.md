# Review of 254-wireless-txn.md v12 (§19) — reviewer A, 2026-10-30

Scope: the whole design read against §19; findings centre on §19. Read-only: product sources in
`Batman-p1b`, harness in `Batman-h23`, the 04 captures under `scratchpad/core/runs/`, the node-side probe scripts.
No node was touched.

## 0. What I verified (evidence I relied on)

- The finding is real and well captured. `wl.log` (repro 2) uptime 86→100: `86 up=true pend=false meshdev=wlh0 key=123456`
  → `87 up=false pend=true txn=1 key=635042` (join's reload) → `88 meshdev= txn=0` (join's setkey returned rc 0 and
  the join finished while netifd was still `pend=true`) → `89 dis=true mark=[ radio1] key=CHANGE txn=1 setkey=1`
  (forget's reload landed in the pending setup) → `100.. up=false dis=true pend=false meshdev=wlh0` (the orphan).
  `logread.log:47-78`: `radio1 (15011): Configuring morse device` at :42, forget at :42, `MESH-GROUP-STARTED` at :42,
  `Wireless device 'radio1' is now down` at :52 with wlh0 / pid 15225 surviving. The helper lines (`:88-121`) match §19.1.
- The join's early rc 0 is explained by the code: the `--channel` read-back (`halow-setkey:244-253`) accepts the first
  `morse_cli` answer from any mesh netdev; the non-channel path (`:268-271`) checks uci only. Neither consults netifd.
- The escalation evidence (repro 4, `prov-reproforget4-254-w15c.log:34-41`): E1 `wifi down` no change; E2 `pgrep -f
  "wpa_supplicant_s1g.*-i wlh0"` → 15409, kill → process gone, netdev stays; E3 `iw dev wlh0 del` → gone; E4 forget
  rc 0. busybox `pgrep -f` works on the node (E2). `splist=[ wlh0 ]` stays after E4.
- "4 of 5 after the wsl.9 B trial": batch 1, batch 2, repro 2 (its script does `pr_ota_b` + `back_to_a` despite the
  header comment "No OTA"), repro 4 = opened; repro 3 = not. Repro 1 (plain reboot) = not. Consistent with §19.1.
- Helper: `main.go:81-90` (300 s for halow-setkey), `node.go:1212-1218` (leave → `ForgetMesh` err → `EApply 21`,
  `.txn` kept), `wtxn.go:286-359` (`finish`: forget never "satisfied", rc 3 → CRIT, `.txn` kept), `wtxn.go:209-221`
  (`satisfied` for a network = uci + `LiveMeshUp`, which is `wpa_cli_s1g status`, `meshjoin.sh:30-41` — NOT netifd).
- Client timeout: `tests/tools/provclient/main.go:355` default **30 s**; `PROVCLIENT_TIMEOUT_S=120` is passed only to
  `leave` (`prov-downgrade-left-254.sh:39,42`, `prov-leave-ota-254.sh:29`, `prov-powerloss-rejoin-254.sh:34`), never
  to `net-apply` (`prov-downgrade-left-254.sh:38`, `prov-netjoin-254.sh:77`).
- `ubus call network.wireless status` carries the mesh key in clear (`wstatus.json`: `"key": "CHANGE-ME-NOW"`,
  radio0 `"key": "vLsDN0L3"`); the morse radio is `phy#0` on 04 (`iw dev` in the repro-2 log line 25; splist
  `wireless._phy0`), the other radio `phy#1` = `phy1-ap0`. The stub (`lib-wireless-stubs.sh:53-54`) has the phys the
  other way round, which is harmless only as long as setkey never hard-codes a phy number.
- The stub ubus already prints `"pending": false` (`lib-wireless-stubs.sh:67`) but nothing reads it today.

## 1. Timeline with the fix (does §19.2 close the window?)

Join (setkey, lock held): settle wait → `pending=false` at once on an idle radio → commit → `wifi reload` → netifd
teardown (1–3 s) + setup → netifd reports `up=true pending=false` only after `morse.sh` has run `wireless_set_up`,
i.e. after `wpa_supplicant_s1g` was started → setkey rc 0 at ≈ :43 instead of :42 → `net.apply code=0` → the app's
leave → forget: settle wait sees `pending=false` → commit `disabled=1` → `wifi reload` lands on an idle, up radio →
clean teardown (the "two reloads on an up radio" and "forget 0–2 s after setup done" probes never orphaned, §19.1).
**Yes, the window of §19.1 is closed for the helper's own sequence**, with one assumption that must be stated as such:
netifd's `pending` is `state == SETUP || state == TEARDOWN` and `up` is set only on the script's `wireless_set_up`
(⚠️ netifd `wireless.c` semantics — from memory of upstream, not from a file in this tree; a read-only probe on 04:
`ubus call network.wireless status` at 5 Hz across one `wifi reload`, confirming `pending=true` from the reload until
`up=true`, and that `up` never flips true before `wlh0` exists). 60 s is enough for the cases seen (teardown 3 s +
setup ≈ 1 s); a slower node gets rc 3 = fail-closed, acceptable.

What the fix does NOT close: a reload by anyone outside the lock during netifd's setup (operator `wifi`, mesh11sd —
see m11). That is the stated residual of §6 and is acceptable, provided the escalation then catches the orphan at the
next forget (M3 makes that condition general enough).

## 2. Findings

### MAJOR-1 — "every write mode" read-back `up=true` breaks writes that leave the morse radio blocked
Scenario (supported today): a fresh card; the operator sets the onboarding-AP key first, `halow-setkey --ap <psk>`,
while the mesh key is still the placeholder (keyguard keeps the morse radio `disabled=1`, in the mark;
`halow-setkey:220-237` prints "still blocked"). Today the non-channel read-back is uci-only (`:268-271`) → rc 0 →
persisted. With §19.2 as written ("every write mode … rc 0 only when netifd reports the radio `up=true`") the morse
radio stays `up=false disabled=true` → rc 3 after 60 s → **not persisted** → the AP key is lost at the next OTA. Same
for `--mesh-id` alone with a placeholder key, and for any write whose `$changed` does not include the morse radio.
Fix: the netifd `up=true pending=false` condition applies only when the write touches the morse radio AND that radio
is enabled after the release step (not in the mark, uci `disabled` unset). Otherwise today's read-back. The shell
test adds: `--ap` only with the morse radio blocked → rc 0, no wait; `--mesh-id` only with a placeholder key → rc 0.
Negative control: the §19 copy without the scoping → rc 3.

### MAJOR-2 — the settle wait's "reload anyway when still pending at 30 s" is a fail-open that recreates the bug
The orphan of §19.1 is exactly "a reload landed while netifd's setup was pending". §19.2 reinstates that path after
30 s and justifies it with "the change in flight is netifd's own". That it is netifd's own does not make the reload
safe; the repro's pending setup was netifd's own too.
Worst scenario: a join whose read-back times out (rc 3, `unverified` set) → Finish → `SetKeyNoPersist(previous)` →
netifd still pending (slow setup of the JOIN's config) → 30 s → reload anyway → the join's `wpa_supplicant_s1g` +
`wlh0` orphaned **with the new network's key on the air** while uci holds the previous key and `.txn` is removed
(Finish "applied") — the opposite of §19.3's "nothing of the network stays on the air", and nothing in the design
would ever remove it (the escalation runs only in `--forget-mesh`, see M3). What actually happens to the second
`wlh0` (name collision at `iw phy … interface add`, `retry_setup_failed`) is ⚠️ unverified either way.
Fix (fail-closed, nothing changed): at the settle deadline the write modes exit **rc 2** before `uci commit`
("netifd still configuring the radio after 30 s — nothing changed, retry"). The helper already handles rc 2
(`node.go:1157-1160`: RemoveTxn + `EApply`; Finish: rc 2 is a failure, `.txn` kept, backoff). For `--forget-mesh` the
same rc 2 (leave → `EApply 21`, retry; Finish → CRIT, retried per backoff). State the boot case explicitly: boot
Finish after `waitRadioUp` meets a still-pending netifd → rc 2 → `.txn` kept → next verb / boot (today's dead-radio
path, bounded). chanfix keeps its fail-open (it already has one, `99-batman-chanfix:41-44`) — say so.
Also missing: the contract when `ubus` fails or the JSON is malformed (no `pending` field): treat as pending (wait),
rc 2 at the deadline; in the read-back treat as "not up" → rc 3. Stub case: ubus exits 1.

### MAJOR-3 — "the morse phy" is undefined and the orphan condition is too narrow
§19.3 says "for each mesh netdev on the morse phy (`iw dev`, the phy of `morse_radio()`'s netdevs)". When netifd
reports the radio down there ARE no netifd netdevs for it; the orphan is the only one. The first orphan probe failed
on exactly this (`prov-reproorphan-254-w15c.log:7`: `O0 morse phy = []`, looked up by a `morse0` netdev). The current
`mesh_netdev()` (`halow-setkey:72`) picks any `type mesh point` on any phy. The design must define the lookup:
uci `wireless.<radio>.path` ↔ `readlink /sys/class/ieee80211/phyN/device` (how netifd's `mac80211.sh` maps it;
⚠️ unverified for the morse driver — read-only probe on 04: `for p in /sys/class/ieee80211/*; do echo $p
$(readlink -f $p/device); done` against `uci get wireless.radio1.path`), with `/sys/class/net/<dev>/phy80211` for the
netdev side. Fallback when the path cannot be resolved: no escalation, rc 3 (fail-closed), logged.
Narrowness: the condition "netifd reports `up=false disabled=true` AND a mesh netdev exists" catches only the forget
case. The general invariant the principle implies is: **a mesh netdev on the morse phy that netifd's status does not
list (`interfaces[].ifname` of that radio; `wstatus.json` shows the field for radio0) is an orphan**. Define the
orphan that way; it keeps the "never while pending" guard, still never touches `phy1-ap0`, and makes the M2 scenario
recoverable at the next forget. Whether a write mode should escalate on its own failure path is a design decision —
state it either way.

### MAJOR-4 — §19.4's timing contract is wrong for the harness and understated for the app
- "DV uses 120 s" holds for `leave` only. `net-apply` runs with provclient's default **30 s** (`provclient/main.go:355`;
  `prov-downgrade-left-254.sh:38`, `prov-netjoin-254.sh:77`, `prov-reproforget2-254.sh:27`). After §19 a join is
  normally ≈ 5 s, but on the slow boot of §19.1 (3 s teardown) plus the new `up=true` wait it approaches, and on a loaded
  node exceeds, 30 s: the client times out, the unit FAILs "join", the helper finishes the join anyway and the next
  verb finds `info.state` member — a false FAIL that would be ❓ unattributed. Fix: `PROVCLIENT_TIMEOUT_S` on every
  `net-apply` and `leave` in the DV units (≥ 200 s, see below), in the harness PR (one validation set, #290).
- The worst cases omit the writer lock: a verb may wait LOCKWAIT 90 s (`halow-setkey:36,128-131`) before any settle
  wait, and a Finish-before-verb (§4.1) adds a whole forget (90 + 30 + 30 + ~15 s) + a p5 save. So `network.leave`
  ≈ 165 s + save, `net.apply` ≈ 180 s (+ a preceding Finish). The P2 contract should carry these numbers and the app
  must treat a timeout as "unknown, re-read `info.net`" (already §4.1's rule — cross-reference it). The helper's
  300 s per subprocess is still enough (max ≈ 180 s per setkey call).

### MAJOR-5 — the evidence cited for "the next `wifi reload` rebuilds from uci" after an escalation does not exist
§19.3: "as repro 4's restore and the S0 restores showed". Repro 4's restore was the S0 overlay restore + **reboot**
(`prov-reproforget4-254-w15c.log:41-56`: `P5-RESTORED … OVERLAY-RESTORED (reboot now)`); no setkey write ran on the
escalated radio with `/var/state` splist still naming `wlh0`. The only setkey restore after an escalation is O5 of the
orphan probe, which was **rc 3** ("the radio did not report 922000 kHz within 60s", `prov-reproorphan-254-w15c.log:21`),
attributed to `wifi down`'s sticky state — plausible, no flip test. So the re-join after an escalation (netifd's
`morse_interface_cleanup` iterating a splist entry whose netdev and supplicant are gone) is ⚠️ unverified. Fix: mark it
unverified in §19.3; `prov-forget-orphan-254` must end with a setkey restore (no `wifi down` anywhere in the unit),
asserting netifd `up=true pending=false`, `meshjoin_radio_up`, and 02 a neighbour; its log is the evidence.

### MAJOR-6 — a PASS of `prov-leave-after-join-254` on a run where the window did not open is a non-result
§19.6 admits "a PASS on a run where the window did not open proves less". Under the project's rule (a test that finds
nothing to check never reports clean) it proves nothing about the fix: 1 of 5 runs on wsl.15 passed for the same
reason (repro 3). Fix: the unit asserts the window opened (sampler: netifd `pending=true` at the moment the leave's
forget starts, or `logread`: the join's `Configuring morse device` after the forget's `forget mesh:` line); if it did
not open, report **INVALID**, not PASS, and the suite judges INVALID as not-PASS (`cl_judge` already requires the PASS
line). Optionally retry the join→leave pair up to 3 times in one run (each after a `back_to_a` reboot, the condition
that opened it 4/5) before declaring INVALID. State the expected INVALID rate (≈ 1 in 5) so a run of INVALIDs is a
finding, not noise.

### MINOR-7 — the helper's own "already" judgement contradicts the §19 principle
`satisfied()` for a network (`wtxn.go:209-221`) = uci + `LiveMeshUp` = `wpa_cli_s1g … status` on `wlh0`
(`meshjoin.sh:37-40`), i.e. the supplicant's view, which on the §19.1 orphan says `mode=mesh wpa_state=COMPLETED
ssid=<id>` (joinwatch line 126: `radio=up type=mesh point mesh=dvd-3f4c8f1c`) while netifd says down+disabled. §19.4
"the helper does not change" leaves this inconsistency. Today no path reaches it with an orphan and a `wantNet`
Finish (M2 fixed), so MINOR: either add netifd `up=true pending=false` to `satisfied()` / `LiveMeshUp` (a `RadioUp()`
in `Sys`, one stub test) or state in §15.4 why the supplicant's view suffices.

### MINOR-8 — kill-by-argv: tighten, and state the root-operator contract
- `pgrep -f "wpa_supplicant_s1g .*-i <dev>( |$)"` matches any process whose argv contains that text (busybox `pgrep`
  uses ERE — ⚠️ unverified for the `( |$)` group; the probe used `wpa_supplicant_s1g.*-i wlh0` without it). An
  unprivileged process can give itself that argv (`exec -a`) and make root `kill` it — harmless (its own process), but
  the claim in §19.3 "a non-root process cannot … start wpa_supplicant_s1g" is the wrong argument. Fix: require
  `/proc/<pid>/comm == wpa_supplicant_s1g` (or `exe` → `/usr/sbin/wpa_supplicant_s1g`) in addition to the argv match;
  the stub gets a decoy process with the argv and the wrong comm, which must survive (mutant: comm check removed).
- "wait ≤ 3 s" after `kill`: say what happens when it is still alive (the supplicant deinits the driver): SIGKILL,
  2 s more, then `iw dev del` — and that the pid is re-checked by comm before the second signal (pid reuse).
- Ownership statement to add: with `disabled=1` committed and netifd reporting the radio released, any root-made mesh
  netdev on the morse phy (an operator's `iw` test) is removed by a forget. That is the intended contract; say it.

### MINOR-9 — the key in netifd's status output; what the new log lines may contain
`ubus call network.wireless status` includes `"key"` in clear (`wstatus.json`). §19.2 "reload anyway and log it" and
§19.6 "the unit logs netifd's `pending`" must log extracted fields only (`jsonfilter -e @.<radio>.pending`), never the
status blob, on the node and in the host run dir. The existing sampler already writes `key=<first 6 chars>` and the
full `wstatus.json` into the host run dir (test keys; `repro-sampler.sh:10`) — fine for a scratch probe, not for a DV
unit: `prov-netjoin-254`'s canary (`:89-90`) checks node logs only. Add the host run dir to that canary for the two
new units. The escalation line `forgotten after escalation (orphan <dev>, s1g <pid>)` is clean.

### MINOR-10 — text in §1–§18 that §19 overtakes
- §6 and `halow-setkey:37`: "both within 2 s (radiooff.sh)" is now known to be the idle-node case only; cite §19.1.
- §4.3 / §16.1 worst case per Finish attempt: setkey's own time is now up to ≈ 180 s; the 13 min bound still holds.
- §8: add rows "leave at once after a join (netifd setup pending)" → `prov-leave-after-join-254`, and "orphan mesh
  netdev after a forget" → `prov-forget-orphan-254` + shell (c)/(d); "restart of netifd / crash of
  wpa_supplicant_s1g" marked out of scope with the reason (netifd rebuilds; `retry_setup_failed` → rc 3).
- §19.5 chanfix: "kept identical by hand" is a standing hazard; put the settle wait in a sourced function
  (`/usr/lib/batman/wifi-settle.sh`) or extend `check-provisioning-sync.sh` to diff the two copies.
- §15.6 "Ownership": add netifd (owner of radio state, netdevs and `wpa_supplicant_s1g`) and the single exception
  §19.3 grants setkey, with its precondition.

### MINOR-11 — other reload writers not inventoried (⚠️ unverified)
joinwatch reports `mesh11sd=1` on 04 (`logread.log:126`). If mesh11sd ever runs `wifi`/`ubus call network reload`
(it manipulates mesh params and can react to config changes), it is a reload outside the lock, like the operator's.
Read-only probe: `grep -l 'wifi\|network reload' /etc/init.d/mesh11sd /usr/sbin/mesh11sd` and its config. List the
result in §19.5 either way. Also: netifd's `retry_setup_failed=true` (field present in `wstatus.json`) means the
read-back will never see `up=true`; fail fast (rc 3) instead of waiting 60 s — optional, but state the behaviour.

### MINOR-12 — stub test gaps for the new code
Add: (e) the OTHER radio pending (`radio0`) must not delay anything; (f) `ubus` failing / no `pending` field → the
M2 contract; (g) an orphan on the other phy's netdev must NOT be killed or deleted (the stub prints `phy0-ap0`
under `phy#0`; after M3 the phy lookup must be stubbed too: `/sys/class/net/<dev>/phy80211` paths under `$ST`);
(h) the decoy process of m8; (i) `kill` and `iw dev … del` are stubs that record, never act (a real `kill` from a test
is a hazard). Mutants to add to §19.6: the comm check removed; the phy check removed (escalation hits the other
phy's netdev in (g)).

### MINOR-13 — forget with netifd `up=true` → rc 3: right, but say what the user sees
Agree with no escalation while netifd still owns the radio (fighting netifd is worse than waiting). The consequence:
the old key stays on the air while p5 says left, `.txn` stays, the app gets `EApply 21` "retry", then `EState 22` per
backoff; `halow-status` says "unfinished network change". Add to §4.1 / the runbook: after two retries over ~5 min,
reboot the node (netifd rebuilds from uci: radio disabled, placeholder). That is the user-visible exit; today it is
implied, not stated.

## 3. Ownership / contract / lifecycle check (short)

- Ownership: netifd owns the radio state, the netdevs and the supplicant; setkey's §19.3 exception is acceptable only
  with the precondition "netifd has released the radio (down+disabled, not pending) and the netdev is not in netifd's
  interface list" (M3). Two writers remain by design outside the lock (operator `wifi`, possibly mesh11sd — m11).
  The TOCTOU between the status read and the kill is bounded by `disabled=1` already committed (netifd will not set
  the radio up on a reload) — state that as the reason the window is safe.
- Contracts: setkey rc 0/2/3 unchanged in meaning (good); the new rc 2 at the settle deadline (M2) fits "nothing
  changed". Missing/malformed ubus JSON: unspecified (M2). `iw dev` / `/proc/<pid>/cmdline`: root-written, but argv is
  user-controlled text (m8).
- Lifecycle: install/upgrade/downgrade/rollback — setkey is a slot-local script, no format change; an older setkey
  behaves as before (fine, stated). Crash/power loss mid-escalation (after kill, before del): the reboot clears it
  (state it). Helper restart mid-setkey: setkey runs on (§17.4), the new helper's Finish waits on the lock — fine.
  netifd restart / supplicant crash: out of scope, say so (m10). Pi 3: unsupported (owner decision), n/a.
- Security: no new network input; new local inputs are `iw dev` and argv text (m8); secrets: the status blob (m9);
  failure mode: one fail-open identified and contested (M2). Negative tests: shell (d) + the m8 decoy + the m12 (g).

## 4. Verdict

**APPROVE-WITH-CHANGES.** The principle (netifd, not the chip, says when a change is complete) is right and the
timeline shows it closes the reproduced window. Before implementation: M1 (scope the `up=true` read-back), M2 (no
reload-anyway; rc 2, and the ubus-failure contract), M3 (define the morse phy and the orphan generally), M4 (fix the
timeout claims and the DV units' client timeout), M5 (replace the non-existent evidence with the unit that produces
it), M6 (the hardware unit must not PASS without the window). Because M2 and M3 change the design's fail-secure
argument, the revised §19 should be reviewed once more as a whole.
