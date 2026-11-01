#!/bin/bash
# scripts/dv/prov-provd-wbox-254.sh — #254 H3 tier-B unit prov-provd-wbox-254: the batman-provd white-box arms that need
# the prov_test build (docs/design/254-h23-harness.md §6.3, 254-p2-impl.md §4.6 / §5 / §9). V = the P2 release
# committed on 04; the unit holds V's `-wbox test` build in the B trial and runs, in that trial:
#   L39 (prov-provd-dos-254): from the landing, before the trial's decision: provd killed with SIGKILL 10 times (10 s
#     apart) while 02 connects / reads twice -> the trial still ends "is healthy and HELD" (health does not look at
#     provd); provd advertising again afterwards
#   SOCK_ONLY (set-provd-env SOCK_ONLY=1): judge `sock-only`; over gatt.sock (provclient proxy as 471) CTRL -> 0xC0 ‖
#     {1:1,2:0,3:244,4:8192} and STATUS -> 0xC1 ‖ map; uid 65534 cannot reach the socket (provd 0700 dir)
#   sec-hog / sec-oversize, the sock part (prov-sec-hog-254 / -oversize-254; L66): two silent connections hold both
#     slots and a third is refused at once ("connection refused (2 slots in use) sock"); a silent connection is closed
#     after the 10 s handshake limit (9-14 s); a 513 B frame closes the connection at once (a 512 B start frame does
#     not: control); a message over 8192 B in 509 B frames closes it at the 17th frame (16 frames do not: control).
#     The parts that need a handshake (eviction of an older unauthenticated session, idle 30 s, the 20/min rate) stay
#     on the app checklist (#254 comment 6544220159)
#   sockdir (h23 §4.8.2, F-P42): judge `sockdir-root` (respawned provd refuses a root-owned dir); the init's next start
#     takes the dir back -> proxy works again
#   adv-len arm 1 (prov-sec-adv-len-254): ADV_LEN_TEST=29 -> judge `adv-len`; clear -> provd_check
#   L83 (two arms): the host stops renewing (= dies) after (1) stopping provd, (2) setting SOCK_ONLY=1 -> after the
#     deadman: provd runs, a new pid, no test switch in its environ, one advertising instance (provd_check)
# then back_to_a and pr_end (restore, B back to V). Negative controls (PR evidence, by hand): L83 with the deadman's
# `provd_restart` replaced by `provd_start` -> arm 2 keeps the SOCK_ONLY pid; set-provd-env on the release image -> refused.
# Type: hold / A / F. Side effects: 04 ~45 min (B rewritten twice, 4 reboots), 02 ~4 BLE links to 04.
set -u
PR_UNIT=prov-provd-wbox-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
P2J="$REPO/scripts/node/prov-p2-254.sh"; P2C="$REPO/scripts/node/prov-p2-central-254.sh"
GS=/tmp/run/batman-provd-test/gatt.sock
j(){	# <arm>: the judge on 04
	local o l
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" "$P2J" | timeout 600 ssh $SSHO root@$NODE sh -s -- "$1" 2>&1 | tr -d '\r')
	while IFS= read -r l; do case "$l" in
		PASS\ *) ok "$1: ${l#PASS }" ;; FAIL\ *) no "$1: ${l#FAIL }" ;; INFO\ *) say "$1: ${l#INFO }" ;; esac
	done <<< "$o"
	grep -q "^PROV-P2 $1 fails=" <<< "$o" || no "$1: the judge did not finish ($(tail -2 <<< "$o" | tr '\n' '|'))"
}
c02(){ timeout 120 ssh $SSHO root@$PEER sh -s -- "$@" < "$P2C" 2>&1 | tr -d '\r'; }
penv(){ local o; o=$(pw set-provd-env "$@"); say "set-provd-env $*: $o"; grep -q '^PROVD-ENV pid=' <<< "$o"; }
# px <uid> <seconds stdin stays open> <hex lines...>: proxy to gatt.sock; prints the reply lines, then "T=<ms> rc=<rc>"
# with T timed ON the node from the connect to the socket closing (the host pipeline also waits for its own sleep)
PXR='a=$(cut -d" " -f1 /proc/uptime); '"$PCD"'/provclient node sock-as @UID@ -- proxy '"$GS"' 2>&1; rc=$?; b=$(cut -d" " -f1 /proc/uptime); awk -v a=$a -v b=$b -v r=$rc "BEGIN { printf \"T=%dms rc=%d\n\", (b - a) * 1000, r }"'
px(){
	local u=$1 hold=$2; shift 2
	{ for x in "$@"; do echo "$x"; done; sleep "$hold"; } | timeout 90 ssh $SSHO root@$NODE "${PXR/@UID@/$u}" 2>&1 | tr -d '\r'
}
zeros(){ printf '%0*d' $(( $1 * 2 )) 0; }   # <n bytes> as hex
frame(){ printf '%02x%04x%s' "$1" "$2" "$(zeros "$3")"; }   # <flags> <seq> <data bytes>
tms(){ sed -n 's/^T=\([0-9]*\)ms.*/\1/p' <<< "$1"; }

pr_begin 3600 || { pr_result; exit 1; }
[ "$(qr '[ -x /etc/init.d/batman-provd ] && echo yes')" = yes ] || { pr_abort "V = $PR_V has no batman-provd (pre-P2)"; pr_result; exit 1; }
pr_ota_b "$PR_V.dirty.wbox-test" B || { pr_abort "OTA of the wbox test build"; pr_result; exit 1; }

# ---- L39: provd killed 10 times before the decision, 02 reading meanwhile -> HELD
r=$(c02 read | tr '\n' ' '); say "02 read 1: $r"
for i in 1 2 3 4 5 6 7 8 9 10; do q 'kill -9 $(pidof batman-provd) 2>/dev/null'; [ $i = 5 ] && { r=$(c02 read | tr '\n' ' '); say "02 read 2: $r"; }; sleep 10; done
ok "L39: provd killed 10 times in the trial"
pr_wait_held 480 && ok "L39: the trial is HELD despite the provd kills" || no "L39: not HELD by uptime 480 s"
o=$(pl provd-reset); grep -q 'PROVD ok' <<< "$o" && ok "L39: provd advertising again ($(tail -1 <<< "$o"))" || no "L39: provd after the kills: $o"
pr_pc_place || { pr_abort "provclient placement"; pr_result; exit 1; }

# ---- SOCK_ONLY: the frame socket, CTRL / STATUS without a handshake, who can reach it
penv SOCK_ONLY=1 || { pr_abort "set-provd-env SOCK_ONLY=1"; pr_result; exit 1; }
j sock-only
o=$(px 471 1 c0 c1); echo "$o" | sed 's/^/    /'
grep -qx 'c0a4010102000318f404192000' <<< "$o" && ok "sock CTRL -> 0xC0 ‖ {1:1,2:0,3:244,4:8192}" || no "sock CTRL: [$o]"
grep -q '^c1a[0-9a-f]*$' <<< "$o" && ok "sock STATUS -> 0xC1 ‖ map ($(grep '^c1' <<< "$o"))" || no "sock STATUS: [$o]"
o=$(px 65534 0); grep -qi 'CONN-ERR .*permission denied' <<< "$o" && ok "uid 65534 cannot reach gatt.sock (provd 0700 dir)" || no "uid 65534 on gatt.sock: [$o]"

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

# ---- sockdir: a respawned provd refuses a root-owned dir; the init's next start takes it back
j sockdir-root
o=$(px 471 1 c0); grep -qx 'c0a4010102000318f404192000' <<< "$o" && no "gatt.sock answered with the dir root-owned" || ok "no answer on gatt.sock with the dir root-owned ($(grep CONN-ERR <<< "$o" | head -1))"
penv SOCK_ONLY=1 || no "set-provd-env SOCK_ONLY=1 after the sockdir arm"
o=$(px 471 1 c0); grep -qx 'c0a4010102000318f404192000' <<< "$o" && ok "the init's start took the dir back: CTRL answers again" || no "after the restart: [$o]"

# ---- adv-len arm 1
penv ADV_LEN_TEST=29 || no "set-provd-env ADV_LEN_TEST=29"
j adv-len
penv clear || no "set-provd-env clear"
o=$(pl provd-reset); grep -q 'PROVD ok' <<< "$o" && ok "switches cleared: $(tail -1 <<< "$o")" || no "after clear: $o"

# ---- L83: the host dies after it (1) stopped provd, (2) started it with SOCK_ONLY; the deadman puts provd back
l83(){	# <label> <setup>
	local p0 o
	eval "$2" || { no "L83 $1: setup"; return 1; }
	p0=$(qr 'pidof batman-provd'); say "L83 $1: provd pid [${p0:-none}]; no renew from here (lease 40 s + 5 s deadman)"
	pr_lease_renew +40 || return 1
	sleep 75
	o=$(qr 'echo "lease=[$(cat /tmp/run/batman-dv/bt/lease-prov 2>/dev/null)] pid=$(pidof batman-provd)"; tail -2 /opt/batdata/log/ble-dm-254.log')
	say "L83 $1 after the deadman: $(echo $o)"
	grep -q 'lease=\[\]' <<< "$o" || { no "L83 $1: the lease is still there after 75 s"; return 1; }
	o=$(cat "$REPO/scripts/node/ble-lib-254.sh" - <<< 'provd_check' | timeout 60 ssh $SSHO root@$NODE sh -s 2>&1 | tr -d '\r')
	case "$o" in *"PROVD ok pid="*) ;; *) no "L83 $1: $o"; return 1 ;; esac
	[ "$(sed -n 's/.*PROVD ok pid=\([0-9]*\).*/\1/p' <<< "$o")" != "$p0" ] && ok "L83 $1: the deadman restarted provd ($o, pid ${p0:-none} -> new), no test switch" || no "L83 $1: same pid as before the host died ($o)"
	o=$(pl acquire 1800); grep -q '^LEASE ' <<< "$o" || { no "L83 $1: re-acquire: $o"; return 1; }
	PR_DEADLINE=$(( $(mono) + 1800 ))
}
l83 "provd stopped" 'q "/etc/init.d/batman-provd stop" >/dev/null; [ -z "$(qr "pidof batman-provd")" ]'
l83 "SOCK_ONLY" 'penv SOCK_ONLY=1'

q "rm -rf $PCD"
back_to_a || { pr_abort "back_to_a"; pr_result; exit 1; }
pr_end wrote-b
pr_result
