#!/bin/bash
# scripts/dv/prov-provd-wbox-254.sh — #254 H3 tier-B unit prov-provd-wbox-254: the batman-provd white-box arms that need
# the prov_test build (docs/design/254-h23-harness.md §6.3, 254-p2-impl.md §4.6 / §5 / §9). V = the P2 release
# committed on 04; the unit holds V's `-wbox test` build in the B trial and runs, in that trial:
#   L39 (prov-provd-dos-254): no "HELD" yet when the first kill goes out (else INVALID: the decision was already made);
#     provd SIGKILLed 10 times, 10 s apart, each kill finding a provd; 02 reads 04 twice meanwhile (recorded: with provd
#     killed every 10 s a read may miss it) -> the trial still ends "is healthy and HELD" (health does not look at
#     provd); provd back on its own afterwards (provd_check, no restart). Over BLE the spec's oversize frames are not
#     sent: 02's bluetoothctl writes are bounded by the ATT MTU — the oversize limits are judged on gatt.sock below,
#     an over-the-air oversize write is on the app checklist.
#   STATUS in the trial: 02 reads key 4 = true (updating=1) and key 5 = 04's last4 — the provd side of
#     prov-firstboot-254 / L21
#   SOCK_ONLY (set-provd-env SOCK_ONLY=1): judge `sock-only`; over gatt.sock (provclient proxy as 471) CTRL -> 0xC0 ‖
#     {1:1,2:0,3:244,4:8192} and STATUS -> 0xC1 ‖ map; uid 65534 gets "permission denied" (provd 0700 dir)
#   sec-hog / sec-oversize, the sock part (L66): two silent connections hold both slots and a third is refused at
#     once; a silent connection is closed after the 10 s handshake limit (9-14 s); a 513 B frame closes the connection
#     at once (a 512 B start frame does not: control); a message over 8192 B in 509 B frames closes it at the 17th
#     frame (16 frames do not: control). "2 sock + 1 BLE": not possible here (SOCK_ONLY has no BLE) — 3 sock.
#   20 handshakes / min (L66; review A-M9): provd answers every first message with a msg2 (a real one or the fake one,
#     noise.go Respond) unless the global rate is spent: 20 one-frame messages each get an answer, the 21st within the
#     same minute is closed with none; 61 s after the first, a 22nd is answered again (control). Eviction of an older
#     unauthenticated session and the 30 s idle limit need a finished handshake (anonymous NX): on the app checklist.
#   sockdir (h23 §4.8.2, F-P42; review A-M3 / B-M5): judge `sockdir-owner` (root:root 0755 — open succeeds, only the
#     owner / mode check refuses) and `sockdir-link` (a symlink to a provd 0700 decoy — the init's start replaces it;
#     a kill + respawn would bind through it, see prov-p2-254.sh); each time
#     the init's next start takes the dir back -> CTRL answers again
#   adv-len arm 1 (prov-sec-adv-len-254): ADV_LEN_TEST=29 -> judge `adv-len`; with provd held off the air, judge
#     `latch-neg` (L2's negative: a helper started while nothing registered -> adv_registered_once=0); clear
#   prov-gatt white box (h23 §6.3 / §4.8.3, F43): GATT_ENCRYPT_CTRL=1 (provd declares CTRL encrypt-read) -> 02 (no bond;
#     04 runs no agent, 02 has no paired device: the preconditions) reads CTRL -> bluetoothctl "Failed to read:
#     org.bluez.Error.NotPermitted", STATUS still read (the control), not paired; 04's btmon (the harness's copy): an SMP
#     Pairing Request and a Pairing Failed, an ATT Error Response 0x0f, no LE Start Encryption. Without the switch
#     (every other run of 02 read) CTRL reads unencrypted: boot-provd.
#   L72: judge `nojail` (ujail made non-executable by a bind from this run's wbox dir -> requirejail: no provd)
#   L83 (two arms): the host stops renewing (= dies) after (1) stopping provd, (2) setting SOCK_ONLY=1 -> provd running
#     again with a new pid <= 15 s after the lease's expiry (the deadman fires at expiry + 5 s), no test switch, one
#     advertising instance (provd_check)
# then back_to_a and pr_end (restore, B back to V). Negative controls (PR evidence, by hand, using this file's l83):
# the staged deadman's `provd_restart` replaced by `provd_start` -> arm 2 FAILs; set-provd-env on a release image ->
# refused. Type: hold / A / F. Side effects: 04 ~55 min (B rewritten twice, 4 reboots), 02 ~4 BLE links to 04.
set -u
PR_UNIT=prov-provd-wbox-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
P2J="$REPO/scripts/node/prov-p2-254.sh"; P2C="$REPO/scripts/node/prov-p2-central-254.sh"
GS=/tmp/run/batman-provd-test/gatt.sock
CTRLX=c0a4010102000318f404192000
j(){	# <arm> [arg] [ssh limit s]: the judge on 04
	local o l
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" "$P2J" | timeout "${3:-600}" ssh $SSHO root@$NODE BATMAN_DV_P2=1 sh -s -- "$1" ${2:+"$2"} 2>&1 | tr -d '\r')
	while IFS= read -r l; do case "$l" in
		PASS\ *) ok "$1: ${l#PASS }" ;; FAIL\ *) no "$1: ${l#FAIL }" ;; INVALID\ *) inv "$1: ${l#INVALID }" ;; INFO\ *) say "$1: ${l#INFO }" ;; esac
	done <<< "$o"
	grep -q "^PROV-P2 $1 fails=" <<< "$o" || no "$1: the judge did not finish ($(tail -2 <<< "$o" | tr '\n' '|'))"
}
c02(){ timeout 300 ssh $SSHO root@$PEER sh -s -- "$@" < "$P2C" 2>&1 | tr -d '\r'; }
penv(){ local o; o=$(pw set-provd-env "$@"); say "set-provd-env $*: $o"; grep -q '^PROVD-ENV pid=' <<< "$o"; }
k5(){ printf '0564%s' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"; }
# px <uid> <seconds stdin stays open> <hex lines...>: proxy to gatt.sock; prints the reply lines, then "T=<ms> rc=<rc>"
# with T timed ON the node from the connect to the socket closing (the host pipeline also waits for its own sleep)
PXR='a=$(cut -d" " -f1 /proc/uptime); '"$PCD"'/provclient node sock-as @UID@ -- proxy '"$GS"' 2>&1; rc=$?; b=$(cut -d" " -f1 /proc/uptime); awk -v a=$a -v b=$b -v r=$rc "BEGIN { printf \"T=%dms rc=%d\n\", (b - a) * 1000, r }"'
px(){
	local u=$1 hold=$2; shift 2
	{ for x in "$@"; do echo "$x"; done; sleep "$hold"; } | timeout 90 ssh $SSHO root@$NODE "${PXR/@UID@/$u}" 2>&1 | tr -d '\r'
}
zeros(){ printf '%0*d' $(( $1 * 2 )) 0; }   # <n bytes> as hex
frame(){ printf '%02x%04x%s' "$1" "$2" "$(zeros "$3")"; }   # <flags> <seq> <data bytes>
# <flags> <seq> <data bytes> of random data: a first message's ephemeral key must not be all zero — X25519 rejects the
# low-order point and provd ends the session with no answer (04 wsl.21, 2026-11-01: "bad X25519 remote ECDH input")
rframe(){ printf '%02x%04x%s' "$1" "$2" "$(head -c "$3" /dev/urandom | od -An -v -tx1 | tr -d ' \n')"; }
tms(){ sed -n 's/^T=\([0-9]*\)ms.*/\1/p' <<< "$1"; }
replies(){ grep -c '^[0-9a-f][0-9a-f]*$' <<< "$1"; }   # answer packets in a px output
provd_pid_q(){ qr 'for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && echo $x; done'; }

# before pr_begin: a pre-P2 V would cost a snapshot and a restore reboot for nothing (known-failures pre-P2 line)
ver=$(qr 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build')
[ -n "$ver" ] || { no "04 unreachable (no BATMAN_VERSION)"; pr_result; exit 1; }
[ "$(qr '[ -x /etc/init.d/batman-provd ] && echo yes || echo no')" = yes ] || { no "no batman-provd on 04 ($ver): a pre-P2 image"; pr_result; exit 1; }
LAST4=$(qr 'tr -d "\n" < /etc/batman-prov/identity/sn | tail -c 4')
case "$LAST4" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) no "04's serial last4 unreadable [$LAST4]"; pr_result; exit 1 ;; esac
pr_begin 3600 || { pr_result; exit 1; }
# the arms take ~25 min in the trial and a held trial is still reverted at its deadline (batman-autocommit:517-524,
# default 600 s): the operator's p6 autocommit.timeout, read at the trial's start (:380), is raised for this run only —
# the snapshot puts p6 back (04 wsl.21 2026-11-01: the trial was reverted at 571 s mid-run and every later arm failed)
o=$(nb state-set "$RUN" autocommit.timeout 3600); say "$o"
grep -q 'STATE-SET autocommit.timeout=3600' <<< "$o" || { pr_abort "could not raise autocommit.timeout"; pr_result; exit 1; }
pr_ota_b "$PR_V.dirty.wbox-test" B || { pr_abort "OTA of the wbox test build"; pr_result; exit 1; }
TB=$(field "$(qr "$ST")" boot)
# need_trial <section>: the wbox trial this unit landed in is still the running boot, uncommitted, on B; otherwise
# every later arm would judge a different system — stop them all as INVALID and end the run (review: a cut-off arm
# must stop, not cascade)
need_trial(){ local s; s=$(qr "$ST")
	[ "$(field "$s" boot)" = "$TB" ] && [ "$(field "$s" slot)" = B ] && [ "$(field "$s" trial_rc)" = 0 ] && return 0
	inv "the wbox trial (boot $TB) is gone before '$1' ($s) — the remaining arms did not run"
	if [ "$(field "$s" slot)" = B ]; then back_to_a; fi
	b=$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null'); if [ -n "$b" ]; then pr_end revert wrote-b; else pr_end wrote-b; fi
	pr_result; exit 1; }

need_trial "L39"
# ---- L39: provd killed 10 times before the decision, 02 reading meanwhile -> HELD
if qr 'logread | grep -q "is healthy and HELD"'; then
	inv "L39: the trial was already HELD when the kills were to start (uptime $(qr 'cut -d. -f1 /proc/uptime') s) — the arm proves nothing"
else
	k=0
	for i in 1 2 3 4 5 6 7 8 9 10; do
		n=$(qr 'n=0; for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && kill -9 $x && n=$((n + 1)); done; echo $n')
		[ "${n:-0}" -ge 1 ] && k=$((k + 1))
		[ $i = 1 ] && qr 'logread | grep -q "is healthy and HELD"' && inv "L39: HELD appeared before the first kill landed"
		[ $i = 3 ] || [ $i = 7 ] && { r=$(c02 read "$LAST4" | tr '\n' ' '); say "02 read during the kills (recorded only): $r"; }
		sleep 10
	done
	[ $k = 10 ] && ok "L39: 10 of 10 kills found a provd to kill" || no "L39: only $k of 10 kills found a provd (respawn window) — fewer kills than the arm claims"
	pr_wait_held 480 && ok "L39: the trial is HELD after the provd kills (no HELD before the first one)" || no "L39: not HELD by uptime 480 s"
	o=$(pl provd-check); grep -q 'PROVD ok' <<< "$o" && ok "L39: provd back on its own ($(tail -1 <<< "$o"))" || no "L39: provd after the kills (no restart): $o"
fi
o=$(c02 read "$LAST4"); sv=$(sed -n 's/^STATUS //p' <<< "$o")
case "$sv" in a5*04f5*"$(k5 "$LAST4")"*) ok "in the trial 02 reads STATUS with key 4 = true (updating) and key 5 = $LAST4 ($sv; prov-firstboot provd side, L21)" ;;
	'') inv "in the trial 02 could not read STATUS at all (02's bluetoothctl: $(echo $o | cut -c1-120)) — not a verdict" ;;
	*) no "STATUS in the trial [$sv] (want key 4 = true, key 5 = $LAST4)" ;; esac
pr_pc_place || { pr_abort "provclient placement"; pr_result; exit 1; }

need_trial "SOCK_ONLY"
# ---- SOCK_ONLY: the frame socket, CTRL / STATUS without a handshake, who can reach it
penv SOCK_ONLY=1 || { pr_abort "set-provd-env SOCK_ONLY=1"; pr_result; exit 1; }
j sock-only
o=$(px 471 1 c0 c1); echo "$o" | sed 's/^/    /'
grep -qx "$CTRLX" <<< "$o" && ok "sock CTRL -> 0xC0 ‖ {1:1,2:0,3:244,4:8192}" || no "sock CTRL: [$o]"
grep -q "^c1a5.*$(k5 "$LAST4")" <<< "$o" && ok "sock STATUS -> 0xC1 ‖ 5-entry map with key 5 = $LAST4 ($(grep '^c1' <<< "$o"))" || no "sock STATUS: [$o]"
o=$(px 65534 0); grep -qi 'CONN-ERR .*permission denied' <<< "$o" && ok "uid 65534 cannot reach gatt.sock (provd 0700 dir)" || no "uid 65534 on gatt.sock: [$o]"

need_trial "sec-hog / oversize, sock part"
# ---- sec-hog / oversize, sock part
f0=$(qr "logread | grep -c 'provd: connection refused (2 slots in use) sock'")
tmpa=$(mktemp); tmpb=$(mktemp)
px 471 20 > "$tmpa" & pa=$!; px 471 20 > "$tmpb" & pb=$!
sleep 3
o=$(px 471 3); t=$(tms "$o"); say "third connection: $(echo $o)"
[ "$(qr "logread | grep -c 'provd: connection refused (2 slots in use) sock'")" -gt "$f0" ] && [ "${t:-99999}" -lt 2500 ] \
	&& ok "two silent connections hold both slots: the third is refused at once (${t} ms, 'connection refused (2 slots in use) sock')" \
	|| no "third connection while two are open: ${t} ms, refusals $f0 -> $(qr "logread | grep -c 'provd: connection refused (2 slots in use) sock'")"
wait $pa $pb
for x in "$tmpa" "$tmpb"; do t=$(tms "$(cat "$x")")
	[ "${t:-0}" -ge 9000 ] && [ "${t:-0}" -le 14000 ] && ok "a silent connection closed after ${t} ms (handshake limit 10 s)" || no "silent connection lifetime ${t} ms (want 9-14 s): $(cat "$x" | tr '\n' ' ')"
done; rm -f "$tmpa" "$tmpb"
o=$(px 471 5 "$(frame 1 0 509)"); t=$(tms "$o")
[ "${t:-0}" -ge 4500 ] && ok "control: a 512 B start frame keeps the connection (${t} ms, closed by our EOF)" || no "control: a 512 B frame closed the connection after ${t} ms"
o=$(px 471 5 "$(frame 1 0 510)"); t=$(tms "$o")
[ "${t:-99999}" -lt 2500 ] && ok "a 513 B frame closes the connection at once (${t} ms)" || no "a 513 B frame: closed after ${t} ms (want < 2.5 s)"
fr=("$(frame 1 0 509)"); for s in $(seq 1 15); do fr+=("$(frame 0 "$s" 509)"); done
o=$(px 471 5 "${fr[@]}"); t=$(tms "$o")
[ "${t:-0}" -ge 4500 ] && ok "control: 16 frames (8144 B, under 8192) keep the connection (${t} ms)" || no "control: 16 frames closed it after ${t} ms"
fr+=("$(frame 0 16 509)")
o=$(px 471 5 "${fr[@]}"); t=$(tms "$o")
[ "${t:-99999}" -lt 2500 ] && ok "a 17th frame (8653 B > 8192) closes the connection at once (${t} ms)" || no "over 8192 B: closed after ${t} ms (want < 2.5 s)"

need_trial "20 handshakes / min. A fresh provd (no f"
# ---- 20 handshakes / min. A fresh provd (no first message counted yet: control packets and unfinished frames never
# reach onMsg1) -> 21 one-frame first messages (start+end, 32 B) within the minute
penv SOCK_ONLY=1 || no "set-provd-env SOCK_ONLY=1 before the rate arm"
t0=$(mono); got=0; i=1
q "logger -t batman-dv-p2 mark rate-$RUN"
while [ $i -le 21 ]; do
	o=$(px 471 1 "$(rframe 3 0 32)"); n=$(replies "$o")
	[ $i = 1 ] && say "rate: first message -> $(echo "$o" | sed 's/\(^[0-9a-f]\{24\}\)[0-9a-f]*/\1…/' | tr '\n' ' ' | cut -c1-200)"
	if [ $i -le 20 ]; then [ "$n" -ge 1 ] && got=$((got + 1)); else last=$n; fi
	i=$((i + 1))
done
el=$(( $(mono) - t0 ))
if [ $el -ge 55 ]; then inv "rate arm: the 21 messages took ${el} s (> 55): the minute window may have rolled"
else
	say "rate: provd during the arm: $(qr "logread | sed -n '/batman-dv-p2: mark rate-$RUN\$/,\$p' | grep 'batman-provd\[' | grep -E 'session ended|connection (refused|sock)|global handshake' | sed 's/.*provd\[1\]: //' | sort | uniq -c | tr '\n' '|'")"
	if [ $got = 0 ]; then inv "rate: none of the 20 first messages got an answer — a precondition of the arm (provd ready / message accepted), not a verdict on the limit; see the provd lines above"
	elif [ $got = 20 ]; then ok "rate: the first 20 first-messages in ${el} s were each answered (msg2)"
	else no "rate: only $got of the first 20 were answered"; fi
	[ "${last:-1}" = 0 ] && ok "rate: the 21st within the minute was closed with no answer (20/min)" || no "rate: the 21st was answered ($last packet(s)) — no global handshake limit"
	w=$(( 62 - ( $(mono) - t0 ) )); [ $w -gt 0 ] && sleep $w
	o=$(px 471 1 "$(rframe 3 0 32)"); [ "$(replies "$o")" -ge 1 ] && ok "rate control: 61 s after the first, a new first message is answered again" || no "rate control: still refused after the minute"
fi

need_trial "sockdir"
# ---- sockdir: a respawned provd refuses a dir it does not own (owner check); the init's next start takes the dir
# back. A symlinked dir: the init's start replaces the link (a kill + respawn binds through it: prov-p2-254.sh)
j sockdir-owner
o=$(px 471 1 c0); grep -qx "$CTRLX" <<< "$o" && no "sockdir owner: gatt.sock answered" || { grep -q 'CONN-ERR' <<< "$o" && ok "sockdir owner: no answer on gatt.sock ($(grep CONN-ERR <<< "$o" | head -1))" || no "sockdir owner: no CONN-ERR reason: [$o]"; }
penv SOCK_ONLY=1 || no "set-provd-env SOCK_ONLY=1 after the sockdir owner arm"
o=$(px 471 1 c0); grep -qx "$CTRLX" <<< "$o" && ok "sockdir owner: the init's start took the dir back, CTRL answers again" || no "after the sockdir owner arm: [$o]"
# the decoy in this run's wbox dir: prep makes the dir root 0700 first (a mkdir -p would make it 0755 and nojail's
# precondition then fails: 04 wsl.21, 2026-11-01)
pw prep >/dev/null; dec=/tmp/run/batman-dv/wbox/$RUN/decoy; q "rm -rf $dec; mkdir -m 0700 $dec"
j sockdir-link "$dec"
o=$(px 471 1 c0); grep -qx "$CTRLX" <<< "$o" && ok "sockdir link: CTRL answers on the dir the init made" || no "after the sockdir link arm: [$o]"

need_trial "adv-len arm 1, then L2's negative while "
# ---- adv-len arm 1, then L2's negative while provd stays off the air
penv ADV_LEN_TEST=29 || no "set-provd-env ADV_LEN_TEST=29"
j adv-len
j latch-neg
penv clear || no "set-provd-env clear"
o=$(pl provd-check); grep -q 'PROVD ok' <<< "$o" && ok "switches cleared: $(tail -1 <<< "$o")" || no "after clear: $o"

need_trial "GATT_ENCRYPT_CTRL"
# ---- prov-gatt white box: CTRL encrypt-read -> an unpaired 02 is refused, after SMP fails
BTT=${DV_BT_TOOLS:-$HOME/batman-dv-tools/bluez-5.72}
gatt_wb(){
	local o e bt
	[ -f "$BTT/btmon" ] && (cd "$BTT" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { inv "gatt: no verified btmon in $BTT"; return; }
	o=$(qr 'pidof bluetoothctl'); [ -z "$o" ] || { no "gatt precondition: a bluetoothctl (an agent?) runs on 04 [$o]"; return; }
	o=$(timeout 30 ssh $SSHO root@$PEER ': | bluetoothctl devices Paired 2>/dev/null' | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^Device ')
	[ "$o" = 0 ] || { no "gatt precondition: 02 has $o paired device(s)"; return; }
	scp -q $SSHO "$BTT/btmon" root@$NODE:$PCD/btmon.up && q "mv $PCD/btmon.up $PCD/btmon && chmod 0700 $PCD/btmon" || { no "gatt: btmon upload"; return; }
	[ "$(qr "sha256sum < $PCD/btmon | cut -c1-64")" = "$(awk '{sub(/^\*/, "", $2)} $2 == "btmon" {print $1}' "$BTT/SHA256SUMS")" ] || { no "gatt: btmon sha on 04"; return; }
	penv GATT_ENCRYPT_CTRL=1 || { no "set-provd-env GATT_ENCRYPT_CTRL=1"; return; }
	sleep 10
	q "nohup $PCD/btmon </dev/null >$PCD/gatt.btmon 2>&1 & echo \$! > $PCD/gatt.btmon.pid"
	o=$(c02 read "$LAST4"); say "gatt: 02 read: $(tr '\n' ' ' <<< "$o")"
	q "kill -INT \$(cat $PCD/gatt.btmon.pid) 2>/dev/null; sleep 1; rm -f $PCD/gatt.btmon.pid"
	bt=$(qr "cat $PCD/gatt.btmon"); q "rm -f $PCD/gatt.btmon"
	e=$(sed -n 's/^ERRS //p' <<< "$o")
	if [ -z "$(sed -n 's/^STATUS //p' <<< "$o")" ]; then inv "gatt: 02 did not read STATUS (not found / unreadable): no verdict on CTRL"
	else
		ok "gatt: STATUS read without encryption (the control)"
		[ -z "$(sed -n 's/^CTRL //p' <<< "$o")" ] && grep -q 'org.bluez.Error.NotPermitted' <<< "$e" && ok "gatt: CTRL refused: $e" || no "gatt: CTRL [$(sed -n 's/^CTRL //p' <<< "$o")] errors [$e] (want none / NotPermitted)"
		grep -q '^PAIRED no' <<< "$o" && ok "gatt: 02 not paired after the read" || no "gatt: 02 $(grep '^PAIRED' <<< "$o")"
	fi
	say "gatt: btmon SMP / ATT error / encryption lines: $(grep -E 'SMP: |Error Response|Error: |Start Encr|0x08\|0x0019' <<< "$bt" | sed 's/^[[:space:]]*//' | tr -s ' ' | head -12 | tr '\n' '|')"
	grep -q 'SMP: Pairing Request' <<< "$bt" && ok "gatt btmon: SMP Pairing Request" || no "gatt btmon: no SMP Pairing Request"
	grep -q 'SMP: Pairing Failed' <<< "$bt" && ok "gatt btmon: SMP Pairing Failed" || no "gatt btmon: no SMP Pairing Failed"
	grep -A3 'ATT: Error Response' <<< "$bt" | grep -qi '(0x0f)' && ok "gatt btmon: ATT Error Response 0x0f (insufficient encryption)" || no "gatt btmon: no ATT Error Response 0x0f"
	grep -qE 'LE Start Encr|0x08\|0x0019' <<< "$bt" && no "gatt btmon: an LE Start Encryption" || ok "gatt btmon: no LE Start Encryption"
	penv clear || no "set-provd-env clear after gatt"
}
gatt_wb

need_trial "L72"
# ---- L72: no ujail -> requirejail keeps provd from starting
pw prep >/dev/null
j nojail "/tmp/run/batman-dv/wbox/$RUN"

need_trial "L83"
# ---- L83: the host dies after it (1) stopped provd, (2) started it with SOCK_ONLY; the deadman puts provd back
l83(){	# <label> <setup>
	local p0 o ex p t u x
	eval "$2" || { no "L83 $1: setup"; return 1; }
	p0=$(provd_pid_q); say "L83 $1: provd pid [${p0:-none}]; no renew from here (lease 40 s, deadman at expiry + 5 s)"
	pr_lease_renew +40 || return 1
	ex=$(qr 'set -- $(cat /tmp/run/batman-dv/bt/lease-prov 2>/dev/null); echo ${3:-}')
	case "$ex" in ''|*[!0-9]*) no "L83 $1: no lease expiry readable"; return 1 ;; esac
	t=""; while :; do
		o=$(qr 'u=$(cut -d. -f1 /proc/uptime); p=""; for x in $(pidof batman-provd); do [ "$(readlink /proc/$x/exe)" = /usr/bin/batman-provd ] && p=$x; done; echo "$u $p"')
		# read, not set --: set -- would overwrite the label in $1 (2026-11-01: "L83 790" / "L83 851")
		read -r u x <<< "$o"; [ -n "${x:-}" ] && [ "${x:-}" != "$p0" ] && [ "${u:-0}" -ge "$ex" ] && { t=$(( u - ex )); break; }
		[ "${u:-0}" -ge $(( ex + 60 )) ] && break; sleep 2
	done
	[ -n "$t" ] && [ "$t" -le 15 ] && ok "L83 $1: a new provd ${t} s after the lease expired (<= 15: deadman at + 5)" || no "L83 $1: no new provd within 15 s of the expiry (${t:-none})"
	sleep 10
	o=$(qr 'echo "lease=[$(cat /tmp/run/batman-dv/bt/lease-prov 2>/dev/null)]"; tail -2 /opt/batdata/log/ble-dm-254.log')
	say "L83 $1 after the deadman: $(echo $o)"
	grep -q 'lease=\[\]' <<< "$o" || no "L83 $1: the lease is still there"
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" - <<< 'provd_check' | timeout 60 ssh $SSHO root@$NODE sh -s 2>&1 | tr -d '\r')
	case "$o" in *"PROVD ok pid="*) ok "L83 $1: $o (no test switch, one instance)" ;; *) no "L83 $1: $o" ;; esac
	o=$(pl acquire 1800); grep -q '^LEASE ' <<< "$o" || { no "L83 $1: re-acquire: $o"; return 1; }
	PR_DEADLINE=$(( $(mono) + 1800 ))
}
l83 "provd stopped" 'q "/etc/init.d/batman-provd stop" >/dev/null; [ -z "$(provd_pid_q)" ]'
l83 "SOCK_ONLY" 'penv SOCK_ONLY=1'

back_to_a || { pr_abort "back_to_a"; pr_result; exit 1; }
pr_end wrote-b
pr_result
