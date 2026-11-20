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
# #254 whole-team status: prov-status-diag-254 SD6's judge on 24 canned answers; only "image without whole-team status" may be a
# known failure (tests/judges/sd6-judge.sh, review r1 A-M2 / B-M1..M3)
o=$(REPO=$REPO bash "$REPO/tests/judges/sd6-judge.sh" 2>&1) && tok "sd6 judge: $(tail -1 <<< "$o")" || tbad "sd6 judge: $(grep '^FAIL' <<< "$o" | head -3 | tr '\n' '|')"
# the H4 offline judges (254-h4 §16): cap / hs / secrets, each with its bad-log cases (tests/judges/h4/test-judges.py)
o=$(python3 "$REPO/tests/judges/h4/test-judges.py" 2>&1) && tok "h4 judges: $(tail -1 <<< "$o")" || tbad "h4 judges: $(grep '^FAIL' <<< "$o" | head -3 | tr '\n' '|')"

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

# ---------------------------------------------------------------- link without session (#329 N1, scripts/dv/link-grace-329.sh)
# lg_judge on canned logread text: every exit of prov-boot-provd-254's link-without-session arm
# shellcheck source=scripts/dv/link-grace-329.sh
. "$REPO/scripts/dv/link-grace-329.sh"
printf '# c\n1.5.14-wsl.26+5edb755.fw162a4d5.bench\n' > "$W/pre-n1"
lgl() { printf 'Sun Jul 27 %s 2025 daemon.info batman-provd[1234]: provd: %s\n' "$1" "$2"; }   # <HH:MM:SS> <text>
LGW='adv withdrawn reason=connect'; LGS='link without session for 30 s'; LGD='adv registered reason=disconnect'
# lg_case <name> <version> <want state> <want ERE in the output> <unwanted ERE or -> ; the log in $W/lg
lg_case() {
	local o; o=$(lg_judge "$2" "$W/pre-n1" < "$W/lg")
	if [ "$(sed -n 's/^LG state=//p' <<< "$o")" = "$3" ] && grep -qE "$4" <<< "$o" && { [ "$5" = - ] || ! grep -qE "$5" <<< "$o"; }; then tok "link-grace $1: state=$3"
	else tbad "link-grace $1: want state=$3 with /$4/ and without /$5/, got [$(tr '\n' '|' <<< "$o")]"; fi
}
RC=1.5.14-wsl.30+1f74d28.fw689266b.bench; OLD=1.5.14-wsl.26+5edb755.fw162a4d5.bench
{ lgl 22:44:15 "$LGW"; lgl 22:44:48 "$LGS"; lgl 22:44:49 "disconnected 1 stale link(s)"; lgl 22:44:50 "$LGD"; } > "$W/lg"; lg_case good "$RC" cut '^PASS 04 logged the link as stale 33 s' '^(FAIL|INVALID)'
{ lgl 22:44:15 "$LGW"; lgl 22:44:48 "$LGS"; lgl 22:44:50 "$LGD"; } | lg_judge "$RC" "$W/pre-n1" | grep -q '^PASS 04 advertises again 2 s' && tok "link-grace good: the advert is back 2 s after the line" || tbad "link-grace good: no PASS for the advert coming back"
{ lgl 22:44:15 "$LGW"; lgl 22:44:44 "$LGS"; lgl 22:44:45 "$LGD"; } > "$W/lg"; lg_case edge-29 "$RC" cut '^PASS 04 logged the link as stale 29 s' '^FAIL'
{ lgl 22:44:15 "$LGW"; lgl 22:44:52 "$LGS"; lgl 22:44:53 "$LGD"; } > "$W/lg"; lg_case edge-37 "$RC" cut '^PASS 04 logged the link as stale 37 s' '^FAIL'
{ lgl 22:44:15 "$LGW"; lgl 22:44:43 "$LGS"; lgl 22:44:44 "$LGD"; } > "$W/lg"; lg_case under-29 "$RC" cut '^FAIL .* only 28 s .*cut before 30 s' '^PASS 04 logged'
{ lgl 22:44:15 "$LGW"; lgl 22:44:53 "$LGS"; lgl 22:44:54 "$LGD"; } > "$W/lg"; lg_case over-37 "$RC" cut '^FAIL .* 38 s .*later than 30 s \+ one tick' '^PASS 04 logged'
{ lgl 22:44:15 "$LGW"; lgl 22:44:48 "$LGS"; lgl 22:44:53 "$LGS"; lgl 22:44:54 "$LGD"; } > "$W/lg"; lg_case two-lines "$RC" none "^FAIL 2 'link without session' lines" '^PASS'
{ lgl 22:44:15 "$LGW"; lgl 22:44:30 "adv registered reason=health"; lgl 22:44:48 "$LGS"; } > "$W/lg"; lg_case adv-in-between "$RC" invalid '^INVALID the advertisement was registered \(22:44:30 reason=health\)' '^(PASS|FAIL)'
{ lgl 22:44:15 "$LGW"; lgl 22:44:21 "$LGD"; } > "$W/lg"; lg_case self-drop "$RC" invalid '^INVALID the advertisement came back 6 s after the connection' '^(PASS|FAIL)'
{ lgl 22:44:15 "$LGW"; lgl 22:44:21 "$LGD"; } > "$W/lg"; lg_case self-drop-on-old "$OLD" invalid '^INVALID the advertisement came back 6 s' '^(PASS|FAIL)'
{ lgl 22:44:10 "adv registered reason=start"; } > "$W/lg"; lg_case no-connection "$RC" invalid '^INVALID 04 logged no connection' '^(PASS|FAIL)'
: > "$W/lg"; lg_case empty-log "$RC" invalid '^INVALID 04 logged no connection' '^(PASS|FAIL)'
{ lgl 22:44:48 "$LGS"; lgl 22:44:50 "$LGD"; } > "$W/lg"; lg_case line-without-connect "$RC" invalid '^INVALID a .link without session. line at 22:44:48 with no connection' '^(PASS|FAIL)'
# the pre-N1 line, whole; an image off the list gets a different FAIL. Since N1 shipped (wsl.31, #358) no
# known-failures entry covers it: a pre-N1 node is a NEW FAIL now
o=$({ lgl 22:44:15 "$LGW"; lgl 22:45:30 "$LGD"; } | lg_judge "$OLD" "$W/pre-n1")
[ "$o" = "$(printf "FAIL no 'link without session' line in 70 s (pre-N1 image)\nLG state=none")" ] && tok "link-grace pre-N1: the one fixed line, nothing else" || tbad "link-grace pre-N1: got [$(tr '\n' '|' <<< "$o")]"
kf=$(awk -F'\t' '$1 == "prov-boot-provd-254" && /pre-N1/ { print $2 }' "$REPO/scripts/validation-known-failures.txt")
[ -z "$kf" ] && tok "link-grace: no pre-N1 known-failures entry for prov-boot-provd-254 (N1 shipped)" || tbad "link-grace: the pre-N1 known-failures entry for prov-boot-provd-254 is back: [$kf]"
o=$({ lgl 22:44:15 "$LGW"; lgl 22:45:30 "$LGD"; } | lg_judge "$RC" "$W/pre-n1")
grep -q "^FAIL 04 ($RC) kept a link that has no session for 70 s" <<< "$o" && ! grep -q 'pre-N1' <<< "$o" && tok "link-grace rc without the rule: a plain FAIL, not the pre-N1 line" || tbad "link-grace rc without the rule: got [$(tr '\n' '|' <<< "$o")]"
o=$({ lgl 22:44:15 "$LGW"; lgl 22:45:30 "$LGD"; } | lg_judge "$RC" "$W/nonexistent")
grep -q '^FAIL 04 (' <<< "$o" && tok "link-grace: no versions file -> not pre-N1 (plain FAIL)" || tbad "link-grace without a versions file: [$o]"
{ lgl 23:59:45 "$LGW"; lgl 00:00:17 "$LGS"; lgl 00:00:19 "$LGD"; } > "$W/lg"; lg_case midnight "$RC" cut '^PASS 04 logged the link as stale 32 s' '^FAIL'
# an earlier link's connect / disconnect before the held one: t0 is the last connect before the line
{ lgl 22:43:00 "$LGW"; lgl 22:43:05 "$LGD"; lgl 22:44:15 "$LGW"; lgl 22:44:47 "$LGS"; lgl 22:44:49 "$LGD"; } > "$W/lg"; lg_case earlier-link "$RC" cut '^PASS 04 logged the link as stale 32 s' '^(FAIL|INVALID)'
{ lgl 22:44:15 "$LGW"; lgl 22:44:47 "$LGS"; } > "$W/lg"; lg_case no-advert-after "$RC" cut "^FAIL no 'adv registered reason=disconnect' after" '^PASS 04 advertises'
{ lgl 22:44:15 "$LGW"; lgl 22:44:47 "$LGS"; lgl 22:45:10 "$LGD"; } > "$W/lg"; lg_case advert-late "$RC" cut '^FAIL 04 advertised again 23 s' '^PASS 04 advertises'
[ "$({ lgl 22:43:00 "$LGW"; lgl 22:44:15 "$LGW"; lgl 22:44:20 "$LGD"; } | lg_last_w)" = 22:44:15 ] && [ "$(lg_age 22:44:15 22:44:36)" = 21 ] && [ "$(lg_age 23:59:50 00:00:05)" = 15 ] && tok "link-grace: lg_last_w / lg_age (midnight too)" || tbad "link-grace: lg_last_w / lg_age"

# ---------------------------------------------------------------- rotating identifier (#329, scripts/dv/advid-judge-329.sh)
# aj_judge on canned text: provd's lines as logread prints them, then the kept btmon blocks (design §8, D1)
# shellcheck source=scripts/dv/advid-judge-329.sh
. "$REPO/scripts/dv/advid-judge-329.sh"
AJV=1.5.14-wsl.31+5c718d8.fwd4f5dc8.bench
# ajm <HH:MM:SS.us> <6 B hex | -> : a MGMT Add Extended Advertising Data block; ajh <time> <hex | -> [noflags|nouuid]: the
# HCI command that follows it. Block text as btmon printed it on 04 (2026-11-19, BlueZ of wsl.31, pushed provd 870faf7):
# LE Set Advertising Data (0x08|0x0008), "Length: 31", the UUID list, the Manufacturer AD, Flags
ajad() { [ "$1" = - ] || printf '        Company: internal use (65535)\n          Data: %s\n' "$1"; }
ajm() { printf '@ MGMT Command (0x0055) plen %s  {0x0001} [hci0] %s\n        Instance: 1\n        Advertising data length: %s\n        128-bit Service UUIDs (complete): 1 entry\n          Vendor specific\n' "$([ "$2" = - ] && echo 32 || echo 42)" "$1" "$([ "$2" = - ] && echo 21 || echo 31)"
	ajad "$2"; printf '        Flags: 0x04\n          BR/EDR Not Supported\n        Scan response length: 0\n'; }
ajh() { printf '< HCI Command: LE.. (0x08|0x0008) plen 32  #7 [hci0] %s\n        Length: %s\n' "$1" "$([ "$2" = - ] && echo 21 || echo 31)"
	[ "${3:-}" = nouuid ] || printf '        128-bit Service UUIDs (complete): 1 entry\n          Vendor specific\n'
	ajad "$2"
	[ "${3:-}" = noflags ] || printf '        Flags: 0x04\n          BR/EDR Not Supported\n'; }
AJF='adv field id=1'; AJR='adv registered reason='
# aj_good [id1] [id2] [id3] [noflags|nouuid for the second HCI command]: three registrations, as a run of the rpa unit has
aj_good() { local a=${1:-0a0b0c010203} b=${2:-1a1b1c111213} c=${3:-2a2b2c212223}
	lgl 22:44:15 "$AJF"; lgl 22:44:15 "${AJR}start"; lgl 23:00:20 "$AJF"; lgl 23:00:20 "${AJR}rpa_timeout"; lgl 23:05:31 "$AJF"; lgl 23:05:31 "${AJR}disconnect"
	ajm 22:44:15.412345 "$a"; ajh 22:44:15.413000 "$a"; ajm 23:00:20.998877 "$b"; ajh 23:00:21.001200 "$b" "${4:-}"; ajm 23:05:31.100000 "$c"; ajh 23:05:31.101000 "$c"; }
# aj_case <name> <state> <want ERE> <unwanted ERE or -> ; the text in $W/aj
aj_case() {
	local o; o=$(aj_judge "$AJV" "$2" < "$W/aj")
	if grep -qE "$3" <<< "$o" && { [ "$4" = - ] || ! grep -qE "$4" <<< "$o"; }; then tok "adv-id $1"
	else tbad "adv-id $1: want /$3/ without /$4/, got [$(tr '\n' '|' <<< "$o")]"; fi
}
aj_good > "$W/aj"; aj_case good member '^PASS adv id: 3 HCI advertising-data command' '^FAIL'
[ "$(aj_judge "$AJV" claimed < "$W/aj" | grep -c '^PASS adv id: ')" = 4 ] && tok "adv-id good: four PASS lines (registrations, blocks, identifiers, HCI)" || tbad "adv-id good: not four PASS lines"
aj_good 0a0b0c010203 0a0b0c010203 > "$W/aj"; aj_case payload-reused member '^FAIL adv id: the registrations at 22:44:15 and 23:00:20 carry the same identifier' '^PASS adv id: 3 registration\(s\), 3 different'
# an image without the field: the one fixed line, whole. Since the field shipped (wsl.32, #362) no known-failures
# entry covers it: a node without the field is a NEW FAIL now
{ aj_good - - - | grep -v 'provd: adv field '; } > "$W/aj"; o=$(aj_judge "$AJV" member < "$W/aj")
[ "$o" = "FAIL no adv field line on 04 ($AJV): an image without the field" ] && tok "adv-id old image: the one fixed line, nothing else" || tbad "adv-id old image: got [$(tr '\n' '|' <<< "$o")]"
kf=$(awk -F'\t' '$1 == "prov-rpa-254" && /an image without the field/ { print $2 }' "$REPO/scripts/validation-known-failures.txt")
[ -z "$kf" ] && tok "adv-id old image: no known-failures entry for prov-rpa-254 (the field shipped in wsl.32)" || tbad "adv-id old image: the known-failures entry for prov-rpa-254 is back: [$kf]"
aj_good "" "" "" noflags > "$W/aj"; aj_case hci-without-flags member '^FAIL adv id: the HCI advertising data at 23:00:21 has no Flags AD' '^PASS adv id: 3 HCI'
aj_good "" "" "" nouuid > "$W/aj"; aj_case hci-without-uuid member '^FAIL adv id: the HCI advertising data at 23:00:21 has no 128-bit UUID list' '^PASS adv id: 3 HCI'
{ lgl 22:44:15 "$AJF"; lgl 22:44:15 "${AJR}start"; } > "$W/aj"; aj_case no-block member '^FAIL adv id: nothing captured$' '^PASS'
{ aj_good | grep -v 'batman-provd'; } > "$W/aj"; aj_case no-registration member '^FAIL adv id: nothing captured$' '^PASS'
aj_good > "$W/aj"; aj_case unclaimed unclaimed '^FAIL adv id: node is unclaimed, nothing to check$' '^PASS'
# a registration made without the identifier although the image has the field
{ aj_good | sed '0,/adv field id=1/s//adv field id=0 why=helper/'; } > "$W/aj"; aj_case fell-back member '^FAIL adv id: the registration at 22:44:15 \(reason=start\) was made without the identifier \[id=0 why=helper\]' '^PASS adv id: 3 registration\(s\), each'
# a field line belongs to the registration right after it only
{ aj_good | awk '/adv field/ && ++n == 2 {next} {print}'; } > "$W/aj"; aj_case field-line-missing member '^FAIL adv id: the registration at 23:00:20 \(reason=rpa_timeout\) has no adv field line before it' '^PASS adv id: 3 registration\(s\), each'
{ aj_good | awk '/MGMT Command/ && ++n == 2 {skip = 1; next} /^[@<>=]/ {skip = 0} !skip'; } > "$W/aj"; aj_case registration-without-block member '^FAIL adv id: the registration at 23:00:20 \(reason=rpa_timeout\) has no 0x0055 block of its own' '^PASS adv id: 3 registration\(s\), 3 different'
{ aj_good | awk '/^< HCI/ && ++n == 3 {h = 1} h && /Data: / {sub(/Data: .*/, "Data: ffffffffffff")} {print}'; } > "$W/aj"; aj_case hci-other-identifier member '^FAIL adv id: the HCI advertising data at 23:05:31 does not carry the identifier of the 0x0055 block before it' '^PASS adv id: 3 HCI'
{ aj_good | awk '/^</ {skip = 1; next} /^[@=>]/ || /batman-provd/ {skip = 0} !skip'; } > "$W/aj"; aj_case no-hci member '^FAIL adv id: no HCI LE Set \(Extended\) Advertising Data command in the capture' '^PASS adv id: 0 HCI'
{ aj_good | sed 's/Data: 1a1b1c111213/Data: 1a1b1c1112/'; } > "$W/aj"; aj_case short-identifier member '^FAIL adv id: the 0x0055 block at 23:00:20 has a Manufacturer AD of 5 B' '^PASS adv id: 3 MGMT'
{ aj_good | sed '0,/Company: internal use (65535)/s//Company: Ericsson AB (0)/'; } > "$W/aj"; aj_case other-company member '^FAIL adv id: the 0x0055 block at 22:44:15 has 0 Manufacturer AD\(s\) of company 0xFFFF and 1 of another company' '^PASS adv id: 3 MGMT'
{ lgl 23:59:58 "$AJF"; lgl 23:59:58 "${AJR}start"; lgl 00:15:30 "$AJF"; lgl 00:15:30 "${AJR}rpa_timeout"; ajm 23:59:58.500000 0a0b0c010203; ajh 23:59:58.600000 0a0b0c010203; ajm 00:15:30.999000 1a1b1c111213; ajh 00:15:31.010000 1a1b1c111213; } > "$W/aj"
aj_case midnight member '^PASS adv id: 2 registration\(s\), 2 different identifier' '^FAIL'
# the node judge's adv_field (prov-p2-254.sh): the field line of the LAST registration only — an older id=1 does not
# speak for a newer registration that logged none
eval "$(grep '^adv_field() ' "$REPO/scripts/node/prov-p2-254.sh")"
logread() { cat "$W/ajlog"; }
{ lgl 22:44:15 "$AJF"; lgl 22:44:15 "${AJR}start"; lgl 23:00:20 "${AJR}rpa_timeout"; } > "$W/ajlog"
[ -z "$(adv_field)" ] && tok "adv_field: an older id=1 is not the newer registration's" || tbad "adv_field stale: [$(adv_field)]"
{ lgl 22:44:15 "$AJF"; lgl 22:44:15 "${AJR}start"; lgl 23:00:20 "adv field id=0 why=off"; lgl 23:00:20 "${AJR}rpa_timeout"; } > "$W/ajlog"
[ "$(adv_field)" = "id=0 why=off" ] && tok "adv_field: the last registration's line" || tbad "adv_field last: [$(adv_field)]"
unset -f logread

# ---------------------------------------------------------------- #329 advertising interval: adv_int_check
# docs/design/329-adv-interval.md §8 T1a + §11. btmon-04-wsl32.txt is real (04, wsl.32: 1280 ms); btmon-edited-pass.txt
# is that capture with the two values edited by hand — no image with the interval existed yet (tests/fixtures/advint-329/README).
AI=$REPO/tests/fixtures/advint-329; AIV='1.5.14-wsl.32+4c0078c.fw45def04.bench'
printf '[General]\n#MinAdvertisementInterval = 0x00A0\nFooMinAdvertisementInterval = 1\n' > "$W/nokey.conf"
printf '[LE]\n  MinAdvertisementInterval = 0x00A0\nMaxAdvertisementInterval = 0x00F0\n' > "$W/key.conf"
echo "BATMAN_VERSION=$AIV" > "$W/bb"
aic() { ADV_INT_BUILD="$W/bb" sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; adv_int_check \"\$1\" \"\$2\"; echo rc=\$?" x "$1" "$2"; }
ai_case() {	# <name> <capture> <main.conf> <rc> <the one line: fixed string>
	local o; o=$(aic "$2" "$3")
	if [ "$o" = "$5"$'\n'"rc=$4" ]; then tok "adv_int_check: $1"; else tbad "adv_int_check: $1: [$o]"; fi; }
AI_OLD="FAIL adv interval 1280.000 / 1280.000 msec (want 100.000 / 150.000): image without the interval [$AIV]"
AI_WANT='(want 100.000 / 150.000 msec, ADV_IND, Success)'
ai_case "real wsl.32 capture, no key in main.conf -> the fixed old-image line" "$AI/btmon-04-wsl32.txt" "$W/nokey.conf" 1 "$AI_OLD"
# what the arm really captures (btmon -T): "> HCI Event: Command Comp.." — the first version of the judge read that as
# "no Command Complete" (found on 04, 2026-11-20)
ai_case "real wsl.32 capture from the arm (btmon -T), no key -> the fixed old-image line" "$AI/btmon-04-wsl32-dated.txt" "$W/nokey.conf" 1 "$AI_OLD"
ai_case "the same capture with the key -> another FAIL line" "$AI/btmon-04-wsl32.txt" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [1280.000 msec (0x0800)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has the key"
ai_case "100 / 150 ms with the key -> PASS (edited fixture)" "$AI/btmon-edited-pass.txt" "$W/key.conf" 0 "PASS adv interval 100.000 / 150.000 msec, ADV_IND (1 block)"
ai_case "100 / 150 ms without the key -> FAIL (who set it?)" "$AI/btmon-edited-pass.txt" "$W/nokey.conf" 1 "FAIL adv interval 100.000 / 150.000 msec (1 block) but main.conf has no key"
# the MGMT records of the fixture carry the same labels with other values: the PASS above did not read them
grep -A8 '^@ MGMT Command: Add Extende.. (0x0054)' "$AI/btmon-edited-pass.txt" | grep -q 'Min advertising interval: 0.000 msec' && tok "adv_int_check: the PASS fixture has an MGMT record with 'Min advertising interval: 0.000 msec' (not read)" || tbad "adv_int_check: the fixture lost its MGMT interval lines"
sed 's/Type: Connectable undirected - ADV_IND (0x00)/Type: Non connectable undirected - ADV_NONCONN_IND (0x03)/' "$AI/btmon-edited-pass.txt" > "$W/ai-nonconn"
ai_case "right interval on a non-connectable advertisement -> FAIL" "$W/ai-nonconn" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [100.000 msec (0x00a0)] max [150.000 msec (0x00f0)] type [Non connectable undirected - ADV_NONCONN_IND (0x03)] status [Success (0x00)] $AI_WANT; main.conf has the key"
awk '/^< HCI Command: .*\(0x08\|0x0006\)/ {exit} {print}' "$AI/btmon-edited-pass.txt" > "$W/ai-noblock"
grep -q 'Max advertising interval' "$W/ai-noblock" && tok "adv_int_check: the no-block fixture keeps the MGMT interval lines" || tbad "adv_int_check: the no-block fixture should keep the MGMT interval lines"
ai_case "no 0x0006 command (MGMT interval lines only) -> FAIL" "$W/ai-noblock" "$W/key.conf" 1 "FAIL adv interval: no LE Set Advertising Parameters (0x08|0x0006) in the capture"
awk 'f && /Status:/ {sub(/Success \(0x00\)/, "Invalid HCI Command Parameters (0x12)"); f = 0} /^> HCI Event: Command Complete/ {c = 1; next_is = 1} /\(0x08\|0x0006\) ncmd/ {f = 1} {print}' "$AI/btmon-edited-pass.txt" > "$W/ai-refused"
ai_case "the controller refused the command -> FAIL with the status" "$W/ai-refused" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [100.000 msec (0x00a0)] max [150.000 msec (0x00f0)] type [Connectable undirected - ADV_IND (0x00)] status [Invalid HCI Command Parameters (0x12)] $AI_WANT; main.conf has the key"
awk '/\(0x08\|0x0006\) ncmd/ {exit} {l[++n] = $0} END {for (i = 1; i < n; i++) print l[i]}' "$AI/btmon-edited-pass.txt" > "$W/ai-nocc"
ai_case "the capture ends before the Command Complete -> FAIL" "$W/ai-nocc" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [100.000 msec (0x00a0)] max [150.000 msec (0x00f0)] type [Connectable undirected - ADV_IND (0x00)] status [no Command Complete] $AI_WANT; main.conf has the key"
# one value right, the other not (edited): never PASS, never the old-image line
sed 's/Max advertising interval: 150.000 msec (0x00f0)/Max advertising interval: 1280.000 msec (0x0800)/' "$AI/btmon-edited-pass.txt" > "$W/ai-minonly"
sed 's/Min advertising interval: 100.000 msec (0x00a0)/Min advertising interval: 1280.000 msec (0x0800)/' "$AI/btmon-edited-pass.txt" > "$W/ai-maxonly"
ai_case "only the minimum right, with the key -> FAIL" "$W/ai-minonly" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [100.000 msec (0x00a0)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has the key"
ai_case "only the maximum right, with the key -> FAIL" "$W/ai-maxonly" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [1280.000 msec (0x0800)] max [150.000 msec (0x00f0)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has the key"
ai_case "only the maximum at 1280 ms, no key -> not the old-image line" "$W/ai-minonly" "$W/nokey.conf" 1 \
	"FAIL adv interval block 1 of 1: min [100.000 msec (0x00a0)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has no key"
ai_case "only the minimum at 1280 ms, no key -> not the old-image line" "$W/ai-maxonly" "$W/nokey.conf" 1 \
	"FAIL adv interval block 1 of 1: min [1280.000 msec (0x0800)] max [150.000 msec (0x00f0)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has no key"
# only the Command Complete of 0x0006 counts: its two lines removed, the other commands' Success lines still there
awk '/\(0x08\|0x0006\) ncmd/ {skip = 1; next} skip {skip = 0; next} {print}' "$AI/btmon-edited-pass.txt" > "$W/ai-othercc"
grep -q 'Status: Success' "$W/ai-othercc" && tok "adv_int_check: the other-CC fixture keeps other Success lines" || tbad "adv_int_check: the other-CC fixture should keep other Success lines"
ai_case "another command's Command Complete is not this one's -> FAIL" "$W/ai-othercc" "$W/key.conf" 1 \
	"FAIL adv interval block 1 of 1: min [100.000 msec (0x00a0)] max [150.000 msec (0x00f0)] type [Connectable undirected - ADV_IND (0x00)] status [no Command Complete] $AI_WANT; main.conf has the key"
# the arm's format (btmon -T) with the two values edited by hand (NOT real) -> PASS
sed 's/Min advertising interval: 1280.000 msec (0x0800)/Min advertising interval: 100.000 msec (0x00a0)/; s/Max advertising interval: 1280.000 msec (0x0800)/Max advertising interval: 150.000 msec (0x00f0)/' "$AI/btmon-04-wsl32-dated.txt" > "$W/ai-dated-pass"
ai_case "the arm's format (btmon -T), values edited, with the key -> PASS" "$W/ai-dated-pass" "$W/key.conf" 0 "PASS adv interval 100.000 / 150.000 msec, ADV_IND (1 block)"
# the arm's glue (adv_int_arm in prov-p2-254.sh): PASS -> ok, anything else -> no, with the judge's text
arm_case() {	# <name> <capture> <main.conf> <want>
	local o
	o=$(ADV_INT_BUILD="$W/bb" sh -c ". '$REPO/scripts/node/ble-lib-254.sh'; ok() { echo \"OK \$*\"; }; no() { echo \"NO \$*\"; }
		adv_int_haskey() { grep -Eq '^[[:space:]]*MinAdvertisementInterval[[:space:]]*=' \"\$CONF\"; }
		$(grep '^adv_int_arm() ' "$REPO/scripts/node/prov-p2-254.sh")
		BMF=\"\$1\"; CONF=\"\$2\"; adv_int_arm" x "$2" "$3")
	if [ "$o" = "$4" ]; then tok "adv_int_arm: $1"; else tbad "adv_int_arm: $1: [$o]"; fi; }
arm_case "a PASS goes to ok" "$AI/btmon-edited-pass.txt" "$W/key.conf" "OK adv interval 100.000 / 150.000 msec, ADV_IND (1 block)"
arm_case "the old image goes to no" "$AI/btmon-04-wsl32-dated.txt" "$W/nokey.conf" "NO ${AI_OLD#FAIL }"
arm_case "no capture goes to no" "$W/ai-missing" "$W/key.conf" "NO adv interval: no btmon capture to read"
ai_case "no capture file -> FAIL" "$W/ai-missing" "$W/key.conf" 1 "FAIL adv interval: no btmon capture to read"
: > "$W/ai-empty"; ai_case "an empty capture -> FAIL" "$W/ai-empty" "$W/key.conf" 1 "FAIL adv interval: no btmon capture to read"
cat "$AI/btmon-edited-pass.txt" "$AI/btmon-edited-pass.txt" > "$W/ai-two"
ai_case "two good blocks -> PASS (2 blocks)" "$W/ai-two" "$W/key.conf" 0 "PASS adv interval 100.000 / 150.000 msec, ADV_IND (2 blocks)"
cat "$AI/btmon-edited-pass.txt" "$AI/btmon-04-wsl32.txt" > "$W/ai-mixed"
ai_case "two blocks, the second at 1280 ms -> FAIL naming block 2" "$W/ai-mixed" "$W/key.conf" 1 \
	"FAIL adv interval block 2 of 2: min [1280.000 msec (0x0800)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has the key"
ai_case "the same two blocks without the key -> not the old-image line" "$W/ai-mixed" "$W/nokey.conf" 1 \
	"FAIL adv interval block 2 of 2: min [1280.000 msec (0x0800)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has no key"
# the arms that hold a fresh registration call the judge (each before it removes the capture)
[ "$(grep -c '^[[:space:]].*adv_int_arm' "$REPO/scripts/node/prov-p2-254.sh")" = 3 ] && tok "adv_int_check: wired into 3 places of prov-p2-254.sh (adv-data, the dep-* arm, dep-power only)" || tbad "adv_int_check: expected 3 adv_int_arm calls in prov-p2-254.sh"
# the known-failures entries (#329, until the image with the interval ships) match the fixed line of each arm and no other
. "$REPO/scripts/dv/known-failures.sh"; KFL=$REPO/scripts/validation-known-failures.txt
kfc() { printf '%s\n' "$2" > "$W/kf.log"; KF_NO_GH=1 kf_classify "$1" "$W/kf.log" "$KFL" "${3:-2026-12-20}"; }
c=$(kfc prov-boot-provd-254 "FAIL prov-boot-provd-254: adv-data: ${AI_OLD#FAIL }"); case "$c" in "known #329"*) tok "known-failures: adv-data's old-image line -> known #329" ;; *) tbad "known-failures adv-data: [$c]" ;; esac
for a in dep-bluetoothd dep-bluetoothd-kill dep-dbus dep-power; do
	c=$(kfc prov-dep-restart-254 "FAIL prov-dep-restart-254: $a: ${AI_OLD#FAIL }"); case "$c" in "known #329"*) tok "known-failures: $a's old-image line -> known #329" ;; *) tbad "known-failures $a: [$c]" ;; esac; done
c=$(kfc prov-dep-restart-254 "FAIL prov-dep-restart-254: dep-power: ${AI_OLD#FAIL }" 2026-12-21); case "$c" in "new (the entry for #329 2026-12-20 has expired"*) tok "known-failures: the day after the expiry -> NEW" ;; *) tbad "known-failures expiry: [$c]" ;; esac
c=$(kfc prov-dep-restart-254 "FAIL prov-dep-restart-254: power-bondable: ${AI_OLD#FAIL }"); case "$c" in "new (unmatched"*) tok "known-failures: an arm that has no interval check -> NEW" ;; *) tbad "known-failures other arm: [$c]" ;; esac
for l in "adv interval block 1 of 1: min [1280.000 msec (0x0800)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [Success (0x00)] $AI_WANT; main.conf has the key" \
	"adv interval 100.000 / 150.000 msec (1 block) but main.conf has no key" "adv interval: no LE Set Advertising Parameters (0x08|0x0006) in the capture" "adv interval: no btmon capture to read"; do
	c=$(kfc prov-boot-provd-254 "FAIL prov-boot-provd-254: adv-data: $l"); case "$c" in "new (unmatched"*) tok "known-failures: [${l%%[:(]*}...] -> NEW" ;; *) tbad "known-failures should be NEW: [$l] -> [$c]" ;; esac; done
echo "$P passed, $F failed"
[ "$F" = 0 ] && [ "$P" -gt 0 ]
