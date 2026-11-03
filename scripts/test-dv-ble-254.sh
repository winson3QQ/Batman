#!/bin/bash
# scripts/test-dv-ble-254.sh — offline tests of the #254 BLE judges (PR-H1 §4.10 N10): no node, no radio.
#   - current-settings parsing: only the `current settings:` line, whole tokens (le vs connectable, supported line)
#   - btmon judge (node-side awk) on recorded btmon text: SMP reason vs disconnect reason, direction, leaks
#   - pairing round verdicts (leak / blocked / other-blocked / invalid) with a stubbed ble_n
#   - the RPA judge end to end with a fake clock + stubbed nodes: good run PASS, every bad run FAIL for its reason
# Run by daily-validation (harness self-test) and CI. Exit 0 = all checks passed.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
P=0; F=0
tok() { echo "ok   $1"; P=$((P + 1)); }
tbad() { echo "FAIL $1"; F=$((F + 1)); }
FIX=$REPO/tests/fixtures/btmon-254

# ---------------------------------------------------------------- 1. current settings (node lib, run by sh)
cat > "$W/mgmtinfo" <<'EOF'
hci0:	Primary controller
	addr 88:A2:9E:B5:6C:8B version 9 manufacturer 305 class 0x000000
	supported settings: powered connectable fast-connectable discoverable bondable link-security ssp br/edr le advertising secure-conn debug-keys privacy configuration static-addr phy-configuration
	current settings: powered le secure-conn privacy
	name BCM2711
EOF
mkdir -p "$W/bin"; printf '#!/bin/sh\ncat "%s"\n' "$W/mgmtinfo" > "$W/bin/bluetoothctl"; chmod +x "$W/bin/bluetoothctl"
# settings() reads only while a bluetoothd runs (bluetoothctl would wait for it forever): a fake pidof says one does
printf '#!/bin/sh\n[ "$1" = bluetoothd ] && { echo 4242; exit 0; }\nexit 1\n' > "$W/bin/pidof"; chmod +x "$W/bin/pidof"
o=$(PATH="$W/bin:$PATH" sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; s=\$(settings); has_tok \"\$s\" privacy && echo P; has_tok \"\$s\" bondable && echo B; has_tok \"\$s\" connectable && echo C; has_tok \"\$s\" le && echo L")
[ "$o" = "$(printf 'P\nL')" ] && tok "settings: current line only; 'le' is a whole token, 'bondable'/'connectable' from 'supported' ignored" || tbad "settings parse gave [$o]"
sed -i 's/current settings: powered le/current settings: powered bondable le/' "$W/mgmtinfo"
o=$(PATH="$W/bin:$PATH" sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; has_tok \"\$(settings)\" bondable && echo B")
[ "$o" = B ] && tok "settings: bondable in the current line is seen" || tbad "bondable in current line missed"
# no bluetoothd: settings() is unreadable (rc 1, nothing printed) and never calls bluetoothctl
mkdir -p "$W/nobtd"; printf '#!/bin/sh\nexit 1\n' > "$W/nobtd/pidof"; printf '#!/bin/sh\ntouch "%s"\nsleep 30\n' "$W/called" > "$W/nobtd/bluetoothctl"; chmod +x "$W/nobtd/pidof" "$W/nobtd/bluetoothctl"
o=$(PATH="$W/nobtd:$PATH" timeout 10 sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; settings; echo rc=\$?")
[ "$o" = rc=1 ] && [ ! -e "$W/called" ] && tok "settings: no bluetoothd -> rc 1 without calling bluetoothctl" || tbad "settings without bluetoothd gave [$o] called=$([ -e "$W/called" ] && echo yes || echo no)"
# a wedged bluetoothctl (bluetoothd alive but stuck): settings() gives up — 3 tries of lim 10 — instead of hanging the
# deadman before it restores provd (review B-M2; main's lib hangs here: the negative control)
mkdir -p "$W/hang"; printf '#!/bin/sh\n[ "$1" = bluetoothd ] && { echo 4242; exit 0; }\nexit 1\n' > "$W/hang/pidof"; printf '#!/bin/sh\nsleep 120\n' > "$W/hang/bluetoothctl"; chmod +x "$W/hang/pidof" "$W/hang/bluetoothctl"
t0=$(date +%s); o=$(PATH="$W/hang:$PATH" timeout 60 sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; settings; echo rc=\$?"); t1=$(date +%s)
case "$o" in *rc=1) [ $((t1 - t0)) -le 45 ] && tok "settings: a hanging bluetoothctl -> rc 1 after $((t1 - t0)) s (no hang)" || tbad "settings with a hanging bluetoothctl took $((t1 - t0)) s" ;; *) tbad "settings with a hanging bluetoothctl: [$o] after $((t1 - t0)) s" ;; esac
pkill -f "$W/hang/bluetoothctl" 2>/dev/null
# lim returns when the command ends, not at its next 1 s poll (0.03 s reads took 1.02 s and pushed helper-stop past
# L71's 65 s, 04 2026-11-02): a 0.3 s command under `lim 10` < 0.8 s; main's polling lim waits for its 1 s poll
# (the negative control; `true` would end before the first poll and hide it)
limt(){ dash -c ". '$1'; a=\$(cut -d' ' -f1 /proc/uptime); lim 10 /bin/sleep 0.3; b=\$(cut -d' ' -f1 /proc/uptime); awk -v a=\$a -v b=\$b 'BEGIN{print (b - a < 0.8) ? \"fast\" : \"slow\"}'"; }
[ "$(limt "$REPO/scripts/node/ble-lib-254.sh")" = fast ] && tok "lim: a 0.3 s command returns in < 0.8 s" || tbad "lim waits for its poll after the command ended"
# the negative controls run fixed commits (git show), not the main checkout: main moves on once a fix lands
neg(){ git -C "$REPO" -c safe.directory='*' show "$1:scripts/node/ble-lib-254.sh" > "$W/neg-$1.sh" 2>/dev/null && echo "$W/neg-$1.sh"; }
NEGLIM=$(neg fbb14e4~1); NEGLOCK=$(neg 2ecf1cb)
[ -n "$NEGLIM" ] && [ -n "$NEGLOCK" ] || tbad "negative controls: the fixed commits are not in this clone"
if [ -n "$NEGLIM" ]; then [ "$(limt "$NEGLIM")" = slow ] && tok "lim negative control: the polling lim (fbb14e4~1) takes >= 0.8 s (the test sees it)" || tbad "lim negative control: fbb14e4~1's lim was fast — the test cannot see a polling lim"; fi
# 02's central watchdog must not keep the session lock (ed0cf33): the REAL line from prov-p2-central-254.sh (270 s ->
# 3 s) under dash, whose sleep forks like the node's busybox (no ASH_SLEEP; WSL busybox's builtin sleep hides it).
# A session that ends at once must leave the lock free; the e4efc29 line must not (the negative control).
if command -v dash >/dev/null && command -v flock >/dev/null; then
	wd_try(){	# <watchdog line> -> "free" / "held": is the lock free right after a session that ended at once?
		printf '%s\n' "trap 'kill \"\$WD\" 2>/dev/null' EXIT" "exec 8>'$W/wd.lock'; flock -n 8 || exit 1" "$1" "sleep 1" > "$W/wd.sh"	# a real session runs >= 1 s: the watchdog's sleep is forked by then
		dash "$W/wd.sh"; sleep 0.5
		dash -c "exec 8>'$W/wd.lock'; flock -n 8" && echo free || echo held
		sleep 4	# let the old line's orphan sleep end before the next case
	}
	new=$(grep '^( exec 8>&-; sleep 270' "$REPO/scripts/node/prov-p2-central-254.sh" | sed 's/sleep 270/sleep 3/')
	[ -n "$new" ] || tbad "watchdog: the line was not found in prov-p2-central-254.sh"
	[ "$(wd_try "$new")" = free ] && tok "central watchdog: the lock is free right after the session (dash, forking sleep)" || tbad "central watchdog keeps 02's lock after the session"
	[ "$(wd_try '( sleep 3; kill -TERM 0 ) & WD=$!')" = held ] && tok "central watchdog negative control: the e4efc29 line keeps the lock (the test sees it)" || tbad "watchdog negative control: the e4efc29 line left the lock free — the test cannot see the bug"
else tbad "watchdog test needs dash and flock on the host"; fi
# the deadman waits for a held lock 20 x `lock 30` (F-H48) — lock() must not touch its caller's counter: with a shared
# `n`, `lock 30` returned n=30 and cmd_dm_fire's `while [ $n -lt 20 ]` gave up after ONE try (30 s, not 10 min; 04
# 2026-11-03 test-h4-undo H-expire: "lock stuck 10 min" 73 s after the host executor started). Scaled: 3 x `lock 2`
# against a held lock = 3 tries; main's lib makes 1 (the negative control)
lockt(){ dash -c ". '$1'; BT='$W'; exec 7>'$W/lock'; flock -n 7 || exit 9; ( exec 7>&-; t=0; n=0; while [ \$n -lt 3 ]; do t=\$((t + 1)); lock 2 && break; n=\$((n + 1)); done; echo tries=\$t )"; }
[ "$(lockt "$REPO/scripts/node/ble-lib-254.sh")" = tries=3 ] && tok "lock leaves the caller's counter alone: 3 waits of a held lock" || tbad "lock: the caller's retry loop gave up early ($(lockt "$REPO/scripts/node/ble-lib-254.sh"))"
if [ -n "$NEGLOCK" ]; then [ "$(lockt "$NEGLOCK")" = tries=1 ] && tok "lock negative control: 2ecf1cb's lock() ends the caller's loop after one try (the test sees it)" || tbad "lock negative control: 2ecf1cb's lib waited 3 times — the test cannot see the shared counter"; fi
# the helper-down backoff judge on real and broken sequences (tests/judges/helper-down-backoff.py)
o=$(python3 "$REPO/tests/judges/helper-down-backoff.py" "$REPO/scripts/node/prov-p2-254.sh" 2>&1) && tok "helper-down backoff judge: 7 sequences judged as expected" || tbad "helper-down backoff judge: $(grep FAIL <<< "$o" | head -3 | tr '\n' '|')"
# the H3 review fixes' negative controls: pr_release / pxok / L71 flip end line / bond_verdict (tests/judges/h3-judges.sh)
o=$(REPO=$REPO bash "$REPO/tests/judges/h3-judges.sh" 2>&1) && tok "h3 judges: $(tail -1 <<< "$o")" || tbad "h3 judges: $(grep '^FAIL' <<< "$o" | head -3 | tr '\n' '|')"

# ---------------------------------------------------------------- 2. btmon judge (node awk) on fixtures
judge() { RUN_ID=x sh "$REPO/scripts/node/ble-periph-254.sh" judge; }
if [ -d "$FIX" ] && ls "$FIX"/*.txt >/dev/null 2>&1; then
	for f in "$FIX"/*.txt; do
		want=$(sed -n 's/^# expect: //p' "$f" | head -1)
		got=$(grep -v '^#' "$f" | judge | tr '\n' ';')
		[ -n "$want" ] && [ "$got" = "$want" ] && tok "btmon judge $(basename "$f"): $got" || tbad "btmon judge $(basename "$f"): got [$got] want [$want]"
	done
else
	tbad "no btmon fixtures in $FIX (a judge without fixtures is untested)"
fi
# synthetic: SMP reason must not be taken from a later disconnect block, direction matters
o=$(printf '%s\n' \
 '> HCI Event: LE Meta Event (0x3e) plen 31' '      LE Enhanced Connection Complete (0x0a)' '        Status: Success (0x00)' \
 '> ACL Data RX: Handle 64 flags 0x02 dlen 11' '      SMP: Pairing Request (0x01) len 6' '        IO capability: NoInputNoOutput (0x03)' \
 '< ACL Data TX: Handle 64 flags 0x00 dlen 6' '      SMP: Pairing Failed (0x05) len 1' '        Reason: Pairing not supported (0x05)' \
 '> HCI Event: Disconnect Complete (0x05) plen 4' '        Status: Success (0x00)' '        Handle: 64' '        Reason: Authentication Failure (0x05)' | judge | tr '\n' ';')
[ "$o" = "CONN status=0x00;SMP RX PairingRequest;SMP TX PairingFailed reason=0x05;DISC reason=0x05;UNPARSED 0;" ] && tok "btmon judge: SMP reason vs disconnect reason, directions" || tbad "btmon judge synthetic: [$o]"
o=$(printf '%s\n' '> ACL Data RX: Handle 64 flags 0x02 dlen 6' '      SMP: Pairing Failed (0x05) len 1' '        Reason: Authentication requirements (0x03)' | judge | tr '\n' ';')
[ "$o" = "SMP RX PairingFailed reason=0x03;UNPARSED 0;" ] && tok "btmon judge: a RECEIVED Pairing Failed is RX, never 'sent by 04'" || tbad "direction: [$o]"
o=$(printf '%s\n' '< ACL Data TX: Handle 64 flags 0x00 dlen 17' '      SMP: Identity Information (0x08) len 16' '        Identity resolving key: 00000000000000000000000000000000' | judge | tr '\n' ';')
[ "$o" = "SMP TX IdentityInformation;UNPARSED 0;" ] && tok "btmon judge: Identity Information TX seen, key value never printed" || tbad "identity: [$o]"
o=$(printf '%s\n' '< ACL Data TX: Handle 64 flags 0x00 dlen 6' '      SMP: Something New (0x7f) len 1' '        Weird field: 1' | judge | tr '\n' ';')
[ "$o" = "UNPARSED 1;" ] && tok "btmon judge: an unknown SMP opcode is UNPARSED (its fields are not judged)" || tbad "unparsed opcode: [$o]"
o=$(printf '%s\n' '> ACL Data RX: Handle 64 flags 0x02 dlen 11' '      SMP: Pairing Request (0x01) len 6' '        Brand new field: 1' | judge | tr '\n' ';')
[ "$o" = "SMP RX PairingRequest;UNPARSED 1;" ] && tok "btmon judge: an unknown field INSIDE a known SMP section is UNPARSED" || tbad "unparsed field: [$o]"
o=$(printf '%s\n' '< ACL Data TX: Handle 64 flags 0x00 dlen 7' '      ATT: Exchange MTU Request (0x02) len 2' '        Client RX MTU: 517' '> HCI Event: LE Meta Event (0x3e) plen 11' '      LE Data Length Change (0x07)' '        Max TX octets: 251' | judge | tr '\n' ';')
[ "$o" = "UNPARSED 0;" ] && tok "btmon judge: ATT / other LE subevents are outside the verdict (not UNPARSED)" || tbad "non-judged sections: [$o]"

# btmgmt hangs on stdin=/dev/null (found by N7 on 04): every call in the node scripts must go through bm()
o=$(grep -n '"\$BTMGMT"' "$REPO/scripts/node/ble-periph-254.sh" | grep -v 'bm() {' | grep -v '^[0-9]*:#' | grep -v 'tool_ok\|file_ok\|for t in\|sha256sum')
[ -z "$o" ] && tok "every btmgmt call goes through bm() (pipe stdin)" || tbad "direct btmgmt calls: $o"
o=$(sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; lim 1 sleep 5; echo rc=\$?")
case "$o" in *"FAIL timeout after 1s"*"rc=124"*) tok "lim kills a hung command and reports it";; *) tbad "lim: [$o]";; esac

# ---------------------------------------------------------------- 3. round verdicts (stubbed ble_n)
DIR=$W; export DIR
# shellcheck disable=SC1091
. "$REPO/scripts/dv/ble-254.sh"
round_case() {	# <name> <02 round output> <04 judge output> <want verdict>
	R02=$2 E04=$3
	ble_n() { case "$3 $4" in
		"periph info") echo "SETTINGS powered le secure-conn privacy"; echo "PID 100";;
		"central round") printf '%s\n' "$R02";;
		"periph btmon-stop") printf '%s\n' "$E04";;
		"central reset") echo "RESET done pid 1 -> 2";;
		*) echo "OK";; esac; }
	v=$(ble_round p c t off off N 88:A2:9E:B5:6C:8B yes | tail -1)
	[ "$v" = "$4" ] && tok "round $1 -> $v" || tbad "round $1: got [$v] want [$4]"
}
R_OK='ROUND t target=5B:4F:00:00:00:01
ROUND t settings-before-pair: powered le privacy
ROUND t connected=1
ROUND t paired-public=0
ROUND t public-seen=0
ROUND t pair-result: Pairing with 5B:4F:00:00:00:01 (LE Random) failed. status 0x05 (Authentication Failed)'
round_case blocked "$R_OK" $'CONN status=0x00\nSMP RX PairingRequest\nSMP TX PairingFailed reason=0x03\nDISC reason=0x05\nUNPARSED 0' "VERDICT blocked"
round_case n6 "$R_OK" $'CONN status=0x00\nSMP TX PairingFailed reason=0x05\nUNPARSED 0' "VERDICT other-blocked:0x05"
round_case disc-only "$R_OK" $'CONN status=0x00\nDISC reason=0x05\nUNPARSED 0' "VERDICT invalid:conn=1 pairing-failed=0 result=[Pairing with 5B:4F:00:00:00:01 (LE Random) failed. status 0x05 (Authentication Failed)]"
round_case leak-02 "${R_OK/paired-public=0/paired-public=1}" $'CONN status=0x00\nUNPARSED 0' "VERDICT leak"
round_case leak-04 "$R_OK" $'CONN status=0x00\nSMP TX IdentityInformation\nUNPARSED 0' "VERDICT leak"
round_case no-conn "$R_OK" $'SMP TX PairingFailed reason=0x03\nUNPARSED 0' "VERDICT invalid:conn=0 pairing-failed=1 result=[Pairing with 5B:4F:00:00:00:01 (LE Random) failed. status 0x05 (Authentication Failed)]"
round_case 02-bondable "${R_OK/powered le privacy/powered bondable le privacy}" $'CONN status=0x00\nSMP TX PairingFailed reason=0x03' "VERDICT invalid:02-bondable"
round_case 0x04 "${R_OK/status 0x05 (Authentication Failed)/status 0x04 (Connect Failed)}" $'UNPARSED 0' "VERDICT invalid:conn=0 pairing-failed=0 result=[Pairing with 5B:4F:00:00:00:01 (LE Random) failed. status 0x04 (Connect Failed)]"

# ---------------------------------------------------------------- 4. the RPA judge, end to end (fake clock)
CLK=$W/clock; echo 1000 > "$CLK"
mono() { cat "$CLK"; }
sleep() { echo $(( $(cat "$CLK") + ${1%.*} )) > "$CLK"; }
ble_pre() { :; }; ble_begin() { :; }; ble_end() { :; }; ble_public() { echo 88:A2:9E:B5:6C:8B; }; ble_offset() { echo 50; }
ble_ah() { cat >/dev/null; for a in "$@"; do case "$a" in 88:*) echo "$a rpa=no match=no";; *) echo "$a rpa=yes match=yes";; esac; done; }
rpa_case() {	# <name> <scenario function> <want: PASS|FAIL> [<FAIL text that must appear>]
	echo 1000 > "$CLK"; SCEN=$2
	ble_n() { local t=$(( $(cat "$CLK") - 1000 ))
		case "$3 $4" in
			"periph info") echo "SETTINGS powered le secure-conn privacy"; echo "PID 100";;
			"central sample") echo $(( $(cat "$CLK") + 12 )) > "$CLK"; $SCEN "$t"; return 0;;	# a real sample that ran is rc 0
			"periph btmon-stop") echo "UNPARSED 0";;
			"central reset") echo "RESET done pid 1 -> 2";;
			*) echo "OK";; esac; }
	out=$(bchk_ble_rpa_254 p c 2>&1); r=$?
	if [ "$3" = PASS ]; then [ $r = 0 ] && tok "rpa $1: PASS" || { tbad "rpa $1: want PASS, got rc=$r"; grep '^FAIL' <<< "$out" | head -3; }
	else
		if [ $r != 0 ] && grep -q -- "$4" <<< "$out"; then tok "rpa $1: FAIL for the right reason ($4)"; else tbad "rpa $1: want FAIL with [$4], rc=$r"; grep '^FAIL' <<< "$out" | head -3; fi
	fi
}
s_good() { if [ "$1" -lt 2100 ]; then echo "SEEN 5E:F4:81:C3:D4:43"; else echo "SEEN 49:F1:0C:63:DE:34"; fi; }
s_rot_a() { if [ "$1" -lt 1200 ]; then echo "SEEN 5E:F4:81:C3:D4:43"; elif [ "$1" -lt 2100 ]; then echo "SEEN 6A:00:00:00:00:01"; else echo "SEEN 49:F1:0C:63:DE:34"; fi; }
s_no_c() { echo "SEEN 5E:F4:81:C3:D4:43"; }
s_gap() { if [ "$1" -ge 900 ] && [ "$1" -lt 1150 ]; then :; elif [ "$1" -lt 2100 ]; then echo "SEEN 5E:F4:81:C3:D4:43"; else echo "SEEN 49:F1:0C:63:DE:34"; fi; }
s_pub() { s_good "$1"; [ "$1" -gt 1500 ] && [ "$1" -lt 1600 ] && echo "SEEN 88:A2:9E:B5:6C:8B"; }
s_guard() { if [ "$1" -lt 2100 ]; then echo "SEEN 5E:F4:81:C3:D4:43"; [ "$1" -gt 140 ] && [ "$1" -lt 175 ] && echo "SEEN 7B:00:00:00:00:09"; else echo "SEEN 49:F1:0C:63:DE:34"; fi; }
rpa_case good s_good PASS
rpa_case rotates-in-a s_rot_a FAIL "segment a: want exactly 1 address"
rpa_case no-new-in-c s_no_c FAIL "c == a"
rpa_case 4-min-gap s_gap FAIL "no sighting in"
rpa_case public-seen s_pub FAIL "public address"
rpa_case guard-only-extra s_guard PASS
s_none() { :; }
rpa_case nothing-seen s_none FAIL "no address observed at all"
o=$(echo 1000 > "$CLK"; SCEN=s_none; bchk_ble_rpa_254 p c 2>&1)
grep -q 'c == a' <<< "$o" && tbad "rpa nothing-seen: printed the misleading 'c == a'" || tok "rpa nothing-seen: no 'c == a' when nothing was observed (2026-10-21 s15)"

echo "$P passed, $F failed"
[ "$F" = 0 ] && [ "$P" -gt 0 ]
