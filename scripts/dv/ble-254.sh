# shellcheck shell=bash
# scripts/dv/ble-254.sh — the #254 BLE suites, sourced by daily-validation.sh (PR-H1, docs/design/254-h1-harness.md).
#   tier A : chk_ble_privacy_254 <node...>, chk_prov_tools_254 <node...>          (read-only; no tool staged)
#   tier B : bchk_ble_rpa_254 <periph> <central>        (~45 min; non-connectable adv, host-owned timeline)
#            bchk_ble_pair_sc_only_254 <periph> <central> (the sandwich; IRK exposed then voided; 02 reboot)
#            bchk_ble_reboot_254 <periph>                (restart keeps the IRK, a reboot replaces it)
# Needs: REPO, DIR (results dir), scripts/lib/ble-254.sh. Every FAIL line starts with "FAIL".
. "$REPO/scripts/lib/ble-254.sh"

ble_judge_a() {	# tier-A judge on one node (read-only)
	cat "$REPO/scripts/node/ble-lib-254.sh" "$REPO/scripts/node/ble-privacy-254.sh" | timeout 90 ssh "${BLE_SSHO[@]}" "root@$1" sh -s
}
chk_ble_privacy_254() { local n rc=0; [ $# -gt 0 ] || { echo "FAIL no bcm2711 node to check"; return 1; }
	for n in "$@"; do echo "== $n"; ble_judge_a "$n" || rc=1; done; return $rc; }
chk_prov_tools_254() { local n rc=0; [ $# -gt 0 ] || { echo "FAIL no bcm2711 node to check"; return 1; }
	for n in "$@"; do echo "== $n"; timeout 60 ssh "${BLE_SSHO[@]}" "root@$n" sh -s < "$REPO/scripts/node/prov-tools-254.sh" || rc=1; done; return $rc; }

# precondition of every tier-B suite: the tier-A judge passes on both nodes NOW (a previous suite may have changed
# them, design §6) — not a SKIP: a node not in the expected state is this suite's FAIL with the actual values
ble_pre() { local n o; for n in "$@"; do o=$(ble_judge_a "$n") || { echo "$o" | grep '^FAIL' | sed "s/^FAIL /FAIL precondition on $n: /"; return 1; }; done; }

ble_public() { timeout 20 ssh "${BLE_SSHO[@]}" "root@$1" 'for a in /tmp/lib/bluetooth/*/; do b=$(basename "$a"); echo "$b" | grep -qE "^([0-9A-F]{2}:){5}[0-9A-F]{2}$" && { echo "$b"; break; }; done'; }
ble_offset() { local t0 u t1; t0=$(mono); u=$(timeout 15 ssh "${BLE_SSHO[@]}" "root@$1" 'cut -d. -f1 /proc/uptime'); t1=$(mono)
	isint "$u" || return 1; echo $(( u - (t0 + t1) / 2 )); }
ble_begin() {	# <secs> <periph> [central]: stage + lease on each; on any failure release what was taken
	local s=$1 p=$2 c=${3:-}
	ble_stage "$p" periph || return 1
	[ -z "$c" ] || ble_stage "$c" central || return 1
	ble_n "$p" 60 periph acquire "$s" || return 1
	[ -z "$c" ] || ble_n "$c" 60 central acquire "$s" || { ble_n "$p" 60 periph release; return 1; }
}
ble_end() { local p=$1 c=${2:-} rc=0
	ble_n "$p" 60 periph release >/dev/null || { echo "FAIL release on $p"; rc=1; }
	[ -z "$c" ] || ble_n "$c" 60 central release >/dev/null || { echo "FAIL release on $c"; rc=1; }
	return $rc; }

# ---------------------------------------------------------------------------------------------------- RPA (§4.4)
# segments (host monotonic seconds after T0): b=[0,300) with a re-register at 150; a=[300,2100) untouched;
# c=[2100,2400) after the re-register at 2100. Samples every 60 s from T0+30; samples within 30 s of a re-register
# are not counted; every 120-s bucket of every segment must have >= 1 counted sighting.
BLE_RPA_REREG_B=${BLE_RPA_REREG_B:-150}; BLE_RPA_REREG_C=${BLE_RPA_REREG_C:-2100}; BLE_RPA_END=${BLE_RPA_END:-2400}
BLE_RPA_INJECT=${BLE_RPA_INJECT:-}		# negative controls only: N5a (power cycle at 1200) / N1 (privacy off)
bchk_ble_rpa_254() {
	local p=$1 c=$2 rc=0 name pub t0 now ts o pid0 pid op0 oc0 op1 oc1 seg addrs a
	ble_pre "$p" "$c" || return 1
	ble_begin 3300 "$p" "$c" || return 1
	pub=$(ble_public "$p"); [ -n "$pub" ] || { echo "FAIL public address of $p unreadable"; ble_end "$p" "$c"; return 1; }
	ble_reset_c "$c" || { ble_end "$p" "$c"; return 1; }
	ble_n "$p" 90 periph restore || { ble_end "$p" "$c"; return 1; }		# fresh RPA at T0 (design B-m1)
	pid0=$(ble_n "$p" 30 periph info | sed -n 's/^PID //p')
	op0=$(ble_offset "$p"); oc0=$(ble_offset "$c")
	name=$(ble_name); echo "name $name, $p public $pub, bluetoothd $pid0"
	ble_n "$p" 60 periph btmon-start rpa || { ble_end "$p" "$c"; return 1; }
	ble_n "$p" 60 periph adv-on "$name" || { ble_n "$p" 60 periph btmon-stop rpa >/dev/null; ble_end "$p" "$c"; return 1; }
	t0=$(mono); echo "T0 (host mono) $t0"
	local done_b=0 done_c=0 done_x=0 rows=() g1="" g2=""
	rpa_events() {	# run every scheduled event whose time has come; record the ACTUAL time (the guard uses it)
		now=$(( $(mono) - t0 ))
		if [ $done_b = 0 ] && [ "$now" -ge "$BLE_RPA_REREG_B" ]; then
			ble_n "$p" 60 periph adv-off >/dev/null && ble_n "$p" 60 periph adv-on "$name" >/dev/null || { echo "FAIL re-register (b) failed"; rc=1; }
			g1=$(( $(mono) - t0 )); echo "EV $g1 re-register (b)"; done_b=1
		fi
		if [ $done_c = 0 ] && [ "$now" -ge "$BLE_RPA_REREG_C" ]; then
			ble_n "$p" 60 periph adv-off >/dev/null && ble_n "$p" 60 periph adv-on "$name" >/dev/null || { echo "FAIL re-register (c) failed"; rc=1; }
			g2=$(( $(mono) - t0 )); echo "EV $g2 re-register (c)"; done_c=1
		fi
		if [ "$BLE_RPA_INJECT" = powercycle ] && [ $done_x = 0 ] && [ "$now" -ge 1200 ]; then
			timeout 30 ssh "${BLE_SSHO[@]}" "root@$p" "$BLE_DIR/btmgmt power off >/dev/null; $BLE_DIR/btmgmt power on >/dev/null"
			ble_n "$p" 60 periph adv-on "$name" >/dev/null; echo "EV $now INJECT power cycle (negative control N5a)"; done_x=1
		fi
	}
	for ts in $(seq 30 60 $((BLE_RPA_END - 30))); do
		while rpa_events; [ "$now" -lt "$ts" ]; do sleep 2; done
		o=$(ble_n "$c" 60 central sample "$name" 10) || echo "SAMPLE-FAILED T0+$ts"
		local info; info=$(ble_n "$p" 30 periph info)
		pid=$(sed -n 's/^PID //p' <<< "$info")
		[ "$pid" = "$pid0" ] || { echo "FAIL bluetoothd on $p changed pid ($pid0 -> $pid) at T0+$ts — run invalid"; rc=1; }
		has_tok_h "$(sed -n 's/^SETTINGS //p' <<< "$info")" bondable && { echo "FAIL $p current settings show bondable at T0+$ts"; rc=1; }
		for a in $(sed -n 's/^SEEN //p' <<< "$o"); do rows+=("$((ts + 5)) $a"); echo "SIGHT T0+$((ts + 5)) $a"; done
	done
	while rpa_events; [ "$now" -lt "$BLE_RPA_END" ]; do sleep 2; done
	[ -n "$g1" ] && [ -n "$g2" ] || { echo "FAIL a scheduled re-registration did not happen"; rc=1; }
	BLE_G1=${g1:-$BLE_RPA_REREG_B}; BLE_G2=${g2:-$BLE_RPA_REREG_C}
	ble_n "$p" 60 periph adv-off >/dev/null
	echo "== btmon over the whole run (a non-connectable advert must see no connection)"
	o=$(ble_n "$p" 120 periph btmon-stop rpa); echo "$o"
	grep -q '^CONN ' <<< "$o" && { echo "FAIL a connection was made to $p during the RPA run — invalid"; rc=1; }
	op1=$(ble_offset "$p"); oc1=$(ble_offset "$c")
	for x in "$op0 $op1 $p" "$oc0 $oc1 $c"; do set -- $x
		isint "${1#-}" && isint "${2#-}" && [ $(( $1 - $2 )) -le 2 ] && [ $(( $2 - $1 )) -le 2 ] || { echo "FAIL clock offset of $3 drifted ($1 -> $2 s) — run invalid"; rc=1; }
	done
	# --- judge
	local b_set a_set c_set
	b_set=$(ble_rpa_seg 0 300); a_set=$(ble_rpa_seg 300 "$BLE_RPA_REREG_C"); c_set=$(ble_rpa_seg "$BLE_RPA_REREG_C" "$BLE_RPA_END")
	echo "segment b: [$b_set]  a: [$a_set]  c: [$c_set]"
	for seg in "b 0 300" "a 300 $BLE_RPA_REREG_C" "c $BLE_RPA_REREG_C $BLE_RPA_END"; do set -- $seg; ble_rpa_buckets "$2" "$3" "$1" || rc=1; done
	[ "$(wc -w <<< "$b_set")" = 1 ] || { echo "FAIL segment b: want exactly 1 address, saw [$b_set]"; rc=1; }
	[ "$(wc -w <<< "$a_set")" = 1 ] || { echo "FAIL segment a: want exactly 1 address over 30 min, saw [$a_set]"; rc=1; }
	[ "$(wc -w <<< "$c_set")" = 1 ] || { echo "FAIL segment c: want exactly 1 address, saw [$c_set]"; rc=1; }
	[ "$a_set" = "$b_set" ] || { echo "FAIL a != b: the RPA changed without a timeout re-registration ([$b_set] -> [$a_set])"; rc=1; }
	[ -n "$c_set" ] && [ "$c_set" != "$a_set" ] || { echo "FAIL c == a: no new RPA after a re-registration past rpa_timeout"; rc=1; }
	addrs=$(printf '%s\n' "${rows[@]}" | awk '{print $2}' | sort -u | tr '\n' ' ')
	grep -qi "$pub" <<< "$addrs" && { echo "FAIL the public address $pub was seen"; rc=1; }
	if [ -n "$addrs" ]; then
		o=$(ble_n "$p" 30 periph irk | ble_ah $addrs); echo "$o"
		grep -q ' rpa=no' <<< "$o" && { echo "FAIL an address is not a resolvable private address"; rc=1; }
		grep -q ' match=no' <<< "$o" && { echo "FAIL an address does not resolve with $p's IRK"; rc=1; }
		grep -q ' match=yes' <<< "$o" || { echo "FAIL ah() produced no verdict"; rc=1; }
	fi
	ble_n "$p" 60 periph snoop-clean >/dev/null
	ble_end "$p" "$c" || rc=1
	return $rc
}
ble_reset_c() {	# 02 reset; a reset that does not report success is a FAIL with its output, never a silent stop
	local o; o=$(ble_n "$1" 90 central reset 2>&1)
	grep -q '^RESET done' <<< "$o" && { grep '^RESET done' <<< "$o"; return 0; }
	echo "FAIL central reset on $1: $(tr '\n' ' ' <<< "$o" | cut -c1-300)"; return 1
}
has_tok_h() { case " $1 " in *" $2 "*) return 0;; esac; return 1; }
ble_rpa_seg() {	# <from> <to> -> sorted unique addresses sighted in [from,to), outside the 30-s guard of re-registers
	printf '%s\n' "${rows[@]}" | awk -v f="$1" -v t="$2" -v g1="$BLE_G1" -v g2="$BLE_G2" '
		NF == 2 && $1 >= f && $1 < t { d1 = $1 - g1; d2 = $1 - g2; if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; if (d1 > 30 && d2 > 30) print $2 }' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
ble_rpa_buckets() {	# <from> <to> <seg>: every 120-s bucket needs a counted sighting
	local f=$1 t=$2 b r=0 n
	for ((b = f; b < t; b += 120)); do
		n=$(printf '%s\n' "${rows[@]}" | awk -v lo="$b" -v hi="$((b + 120 < t ? b + 120 : t))" -v g1="$BLE_G1" -v g2="$BLE_G2" '
			NF == 2 && $1 >= lo && $1 < hi { d1 = $1 - g1; d2 = $1 - g2; if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; if (d1 > 30 && d2 > 30) c++ } END { print c + 0 }')
		[ "$n" -ge 1 ] || { echo "FAIL segment $3: no sighting in [$b,$((b + 120)))s — not observed"; r=1; }
	done; return $r
}

# --------------------------------------------------------------------------------------- pairing sandwich (§4.5)
# one round: prints "VERDICT <leak|blocked|other-blocked:0xNN|invalid:<why>>" as the last line
ble_round() {	# <p> <c> <label> <sc> <bondable> <name> <pub> <expect: secure-conn on 04 yes|no>
	local p=$1 c=$2 L=$3 sc=$4 bo=$5 nm=$6 pub=$7 o r s ev
	ble_n "$p" 30 periph arm 900 >/dev/null && ble_n "$c" 30 central arm 900 >/dev/null || { echo "VERDICT invalid:arm"; return; }
	ble_reset_c "$c" || { echo "VERDICT invalid:02-reset"; return; }
	ble_n "$p" 60 periph adv-on "$nm" connectable >/dev/null || { echo "VERDICT invalid:adv-on"; return; }
	s=$(ble_n "$p" 30 periph info | sed -n 's/^SETTINGS //p'); echo "$L 04 settings: $s"
	has_tok_h "$s" privacy && ! has_tok_h "$s" bondable || { ble_n "$p" 60 periph adv-off >/dev/null; echo "VERDICT invalid:04-settings"; return; }
	[ "$8" = yes ] && ! has_tok_h "$s" secure-conn && { ble_n "$p" 60 periph adv-off >/dev/null; echo "VERDICT invalid:04-no-secure-conn"; return; }
	ble_n "$p" 60 periph btmon-start "$L" >/dev/null || { echo "VERDICT invalid:btmon"; return; }
	o=$(ble_n "$c" 120 central round "$L" "$sc" "$bo" "$nm" "$pub"); echo "$o"
	ev=$(ble_n "$p" 120 periph btmon-stop "$L"); echo "$ev" | sed "s/^/$L 04 /"
	ble_n "$p" 60 periph adv-off >/dev/null
	grep -q 'INVALID no-target' <<< "$o" && { echo "VERDICT invalid:no-target"; return; }
	s=$(sed -n "s/^ROUND $L settings-before-pair: //p" <<< "$o")
	if [ "$bo" = off ] && has_tok_h "$s" bondable; then echo "VERDICT invalid:02-bondable"; return; fi
	if [ "$bo" = on ] && ! has_tok_h "$s" bondable; then echo "VERDICT invalid:02-not-bondable"; return; fi
	if [ "$sc" = off ] && has_tok_h "$s" secure-conn; then echo "VERDICT invalid:02-secure-conn"; return; fi
	if grep -q "^ROUND $L paired-public=[1-9]" <<< "$o" || grep -q '^SMP TX IdentityInformation' <<< "$ev"; then echo "VERDICT leak"; return; fi
	local conn pf rsn
	conn=$(grep -c '^CONN status=0x00' <<< "$ev"); pf=$(grep -c '^SMP TX PairingFailed' <<< "$ev")
	rsn=$(sed -n 's/^SMP TX PairingFailed reason=//p' <<< "$ev" | head -1)
	if grep -q "pair-result: .*status 0x05" <<< "$o" && [ "$conn" = 1 ] && [ "$pf" = 1 ]; then
		[ "$rsn" = 0x03 ] && echo "VERDICT blocked" || echo "VERDICT other-blocked:${rsn:-none}"; return
	fi
	echo "VERDICT invalid:conn=$conn pairing-failed=$pf result=[$(sed -n "s/^ROUND $L pair-result: //p" <<< "$o")]"
}
ble_round_twice() {	# a round that comes back invalid is repeated once (design §4.5); prints the final VERDICT
	local o v
	o=$(ble_round "$@"); echo "$o"; v=$(tail -1 <<< "$o")
	case "$v" in "VERDICT invalid"*) echo "== $3: invalid, repeating once"; o=$(ble_round "$@"); echo "$o";; esac
}
bchk_ble_pair_sc_only_254() {
	local p=$1 c=$2 rc=0 pub v name o
	ble_pre "$p" "$c" || return 1
	ble_begin 900 "$p" "$c" || return 1
	pub=$(ble_public "$p"); [ -n "$pub" ] || { echo "FAIL public address of $p unreadable"; ble_end "$p" "$c"; return 1; }
	name=$(ble_name); echo "name $name, $p public $pub"
	echo "=== 1 target: 04 SC-only, 02 legacy (sc off, bondable off) -> must be BLOCKED (reason 0x03)"
	o=$(ble_round_twice "$p" "$c" target off off "$name" "$pub" yes); echo "$o"; v=$(tail -1 <<< "$o")
	[ "$v" = "VERDICT blocked" ] || { echo "FAIL target segment: $v (want blocked)"; rc=1; }
	echo "=== 2 flip: 04 sc on (SC-only cleared) -> must LEAK, else the method lost its discrimination"
	ble_n "$p" 30 periph arm 900 >/dev/null; ble_n "$c" 30 central arm 900 >/dev/null
	ble_n "$c" 30 central mark-exposed; ble_n "$p" 60 periph flip || { echo "FAIL flip"; rc=1; }
	o=$(ble_round_twice "$p" "$c" flip off off "$name" "$pub" yes); echo "$o"; v=$(tail -1 <<< "$o")
	[ "$v" = "VERDICT leak" ] || { echo "FAIL flip segment did not leak ($v): the test cannot tell SC-only from not — whole suite void"; rc=1; }
	echo "=== 3 restart: 04 bluetoothd restart (patch 900 re-applies SC-only) -> must be BLOCKED"
	ble_n "$p" 30 periph arm 900 >/dev/null; ble_n "$p" 90 periph restore || { echo "FAIL restore"; rc=1; }
	o=$(ble_round_twice "$p" "$c" restart off off "$name" "$pub" yes); echo "$o"; v=$(tail -1 <<< "$o")
	[ "$v" = "VERDICT blocked" ] || { echo "FAIL restart segment: $v (want blocked)"; rc=1; }
	echo "=== 4 N6: 02 asks for bonding (bondable on, sc off) -> must be OTHER-BLOCKED 0x05, never 'blocked'"
	o=$(ble_round_twice "$p" "$c" n6 off on "$name" "$pub" yes); echo "$o"; v=$(tail -1 <<< "$o")
	[ "$v" = "VERDICT other-blocked:0x05" ] || { echo "FAIL N6: $v (want other-blocked:0x05 — the judge must tell SC-only apart)"; rc=1; }
	echo "=== 5 SC Just Works (02 sc on): SMOKE only, no negative control (design §4.5)"
	o=$(ble_round "$p" "$c" scjw on off "$name" "$pub" yes); echo "$o" | tail -1 | sed 's/^VERDICT/SMOKE/'
	echo "=== cleanup: canary (04 + 02, before the IRKs change), rekey 04 with kernel verification, release"
	ble_canary_both "$p" "$c" || rc=1
	ble_rekey_verified "$p" "$c" || rc=1
	ble_n "$p" 60 periph snoop-clean >/dev/null
	ble_end "$p" "$c" || rc=1
	echo "=== 02 reboot (H-U7: its IRK may have been derived from the legacy flip pairing)"
	ble_reboot_committed "$c" || rc=1
	return $rc
}
ble_canary_both() {	# the log of this suite so far, through each node's canary (IRK never leaves the node)
	local p=$1 c=$2 f="$DIR/ble-pair-sc-only-254.log" r=0
	[ -f "$f" ] || f=/dev/null
	ble_n "$p" 60 periph canary < "$f" || r=1
	ble_n "$c" 60 central canary < "$f" || r=1
	return $r
}
ble_rekey_verified() {	# rekey 04, then prove the KERNEL uses the new IRK: a fresh RPA must resolve with it
	local p=$1 c=$2 nm a o
	ble_n "$p" 30 periph arm 300 >/dev/null; ble_n "$c" 30 central arm 300 >/dev/null
	ble_n "$p" 120 periph rekey || return 1
	ble_reset_c "$c" || return 1
	nm=$(ble_name)
	ble_n "$p" 60 periph adv-on "$nm" >/dev/null || return 1
	a=$(ble_n "$c" 60 central sample "$nm" 10 | sed -n 's/^SEEN //p' | head -1)
	ble_n "$p" 60 periph adv-off >/dev/null
	[ -n "$a" ] || { echo "FAIL rekey verification: 02 saw no advert from $p (irk-exposed kept)"; return 1; }
	o=$(ble_n "$p" 30 periph irk | ble_ah "$a"); echo "rekey check: $o"
	grep -q ' match=yes' <<< "$o" || { echo "FAIL rekey: the advertised RPA does not resolve with the NEW IRK — the kernel kept the old one (irk-exposed kept; reboot $p)"; return 1; }
	ble_n "$p" 30 periph rekey-verified
}
ble_reboot_committed() {	# explicit-partition reboot (E30), wait for the new boot
	local n=$1 b0 b1 t
	b0=$(timeout 15 ssh "${BLE_SSHO[@]}" "root@$n" 'cat /proc/sys/kernel/random/boot_id')
	timeout 30 ssh "${BLE_SSHO[@]}" "root@$n" 'batman-slot reboot committed ble-254 </dev/null >/dev/null 2>&1 &' ; sleep 20
	for t in $(seq 1 60); do b1=$(timeout 10 ssh "${BLE_SSHO[@]}" "root@$n" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null); [ -n "$b1" ] && [ "$b1" != "$b0" ] && break; sleep 5; done
	[ -n "$b1" ] && [ "$b1" != "$b0" ] || { echo "FAIL $n did not come back from reboot within ~5 min (reboot did not happen?)"; return 1; }
	echo "rebooted $n: boot ${b0:0:8} -> ${b1:0:8}"
}

# ------------------------------------------------------------------------------------- restart vs reboot (§4.6)
bchk_ble_reboot_254() {
	local p=$1 rc=0 h0 h1 h2 pid0 pid1 b0 o
	ble_pre "$p" || return 1
	ble_begin 600 "$p" || return 1
	h0=$(ble_n "$p" 30 periph irk-hash | sed -n 's/^IRKHASH //p'); pid0=$(ble_n "$p" 30 periph info | sed -n 's/^PID //p')
	ble_n "$p" 90 periph restore || rc=1
	h1=$(ble_n "$p" 30 periph irk-hash | sed -n 's/^IRKHASH //p'); pid1=$(ble_n "$p" 30 periph info | sed -n 's/^PID //p')
	echo "restart: pid $pid0 -> $pid1, IRK hash $h0 -> $h1"
	[ -n "$h0" ] && [ "$h0" = "$h1" ] || { echo "FAIL bluetoothd restart changed (or lost) the IRK ($h0 -> $h1)"; rc=1; }
	[ -n "$pid1" ] && [ "$pid1" != "$pid0" ] || { echo "FAIL bluetoothd pid did not change on restart"; rc=1; }
	ble_end "$p" || rc=1
	b0=$(timeout 15 ssh "${BLE_SSHO[@]}" "root@$p" 'cat /proc/sys/kernel/random/boot_id')
	ble_reboot_committed "$p" || return 1
	# read the boot log line FIRST, before OTS start-up floods the ring (design §4.6)
	o=$(timeout 30 ssh "${BLE_SSHO[@]}" "root@$p" 'n=$(logread -e "Generated IRK \(getrandom\)" | wc -l); f=$(ls /var/lib/bluetooth/*/identity | head -1); h=$(sed -n "s/^IdentityResolvingKey=//p" "$f" | tr A-F a-f | sha256sum | cut -c1-8); echo "$n $h $(cat /var/lib/bluetooth/batman-sc)"')
	echo "after reboot: $o"
	set -- $o
	isint "${1:-}" && [ "$1" -ge 1 ] || { echo "FAIL no 'Generated IRK (getrandom)' line in this boot's log"; rc=1; }
	h2=${2:-}; [ -n "$h2" ] && [ "$h2" != "$h1" ] || { echo "FAIL the IRK did not change across the reboot ($h1 -> $h2)"; rc=1; }
	case "$o" in *"boot_id=$(timeout 15 ssh "${BLE_SSHO[@]}" "root@$p" 'cat /proc/sys/kernel/random/boot_id')"*) ;; *) echo "FAIL batman-sc is not from this boot"; rc=1;; esac
	ble_pre "$p" || rc=1
	return $rc
}
type isint >/dev/null 2>&1 || isint() { case "$1" in ""|*[!0-9]*) return 1;; esac; }
