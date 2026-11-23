#!/bin/bash
# tests/judges/h4/test-undo-ud-254.sh [LIB] — offline test of the undo actions the UD unit adds (254-v16-ud.md §4.3, §7, §9):
# ssid-restore <hex|->, rm-hold, undo-done, the node-side ssid encode (ssid_hex), and the host-death replay order.
# The real ble-lib + undo lib (LIB, default this checkout's) run under busybox sh in a mount namespace (as
# test-undo-lib.sh): the lib's own /tmp/run and /opt paths, stub uci / batman-slot / batman-config-save on PATH.
#   - the replay restores exactly the recorded ssid for a*b, "Lab 1", x'y, 50%, a\b, *, and one with a CR byte, from a
#     working directory full of files named a, ab, Lab1 (the executor's unquoted `set --` must not glob or split);
#   - a value with a newline / NUL, or longer than 32 bytes, gives RT=bad and is refused at undo-add; an empty S0 ssid
#     is "-" and replays as a uci delete;
#   - undo-done of an unknown id FAILs and changes nothing; of a known id the replay skips that line;
#   - rm-hold removes the hold flag; replay order ssid-restore -> p5-save -> the first registration;
#   - negative control (printed, must hold): the RAW value through the executor's `set -- $(awk …)` loop in the same
#     directory is globbed / split — why the argument is hex.
# Prints "N PASS / M FAIL"; with LIB = the 4eba26d lib the ssid / rm-hold / undo-done cases FAIL.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
LIB=$(readlink -f "${1:-$REPO/scripts/node/prov-undo-lib-254.sh}")
BB=$(command -v busybox) || { echo "FAIL no busybox"; echo "0 PASS / 1 FAIL"; exit 1; }
if [ "${UNDO_T_INNER:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] && exec unshare --mount --propagation private env UNDO_T_INNER=1 bash "$0" "$@"
	exec unshare --user --map-root-user --mount env UNDO_T_INNER=1 bash "$0" "$@"
fi
mount -t tmpfs -o mode=755 none /tmp || { echo "FAIL tmpfs over /tmp"; exit 1; }; mkdir -p /tmp/run; mount -t tmpfs -o mode=755 none /opt || { echo "FAIL tmpfs over /opt"; exit 1; }
mkdir -p /opt/batdata/log /opt/batdata/state; chmod 755 /opt/batdata/log
W=$(mktemp -d /tmp/ut.XXXXXX); mkdir "$W/bin"
cat > "$W/bin/batman-slot" <<'X'
#!/bin/sh
[ "$1" = active ] && cat /tmp/ut.slot
X
# uci: wireless.default_radio0.ssid only, raw bytes in /tmp/ut.ssid; set / delete are staged, commit applies them and
# logs the umask it ran under
cat > "$W/bin/uci" <<'X'
#!/bin/sh
[ "$1" = -q ] && shift
case "$1" in
get) [ "$2" = wireless.default_radio0.ssid ] && [ -f /tmp/ut.ssid ] || exit 1; cat /tmp/ut.ssid; echo ;;
set) case "$2" in wireless.default_radio0.ssid=*) printf %s "${2#wireless.default_radio0.ssid=}" > /tmp/ut.staged ;; *) exit 1 ;; esac ;;
delete) [ "$2" = wireless.default_radio0.ssid ] || exit 1; echo DEL > /tmp/ut.staged.del; [ -f /tmp/ut.ssid ] ;;
commit) [ "$2" = wireless ] || exit 1; echo "COMMIT umask=$(umask)" >> /tmp/ut.trace
	[ -f /tmp/ut.staged.del ] && { rm -f /tmp/ut.ssid /tmp/ut.staged.del; }
	[ -f /tmp/ut.staged ] && mv /tmp/ut.staged /tmp/ut.ssid; true ;;
*) exit 1 ;;
esac
X
cat > "$W/bin/batman-config-save" <<'X'
#!/bin/sh
echo "CFGSAVE $1" >> /tmp/ut.trace
X
chmod 755 "$W/bin/"*
pass=0; fails=0
ok(){ echo "PASS $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
G=$W/globdir; mkdir -p "$G"; : > "$G/a"; : > "$G/ab"; : > "$G/Lab1"; : > "$G/x"
run() {	# <script>: busybox sh with ble-lib + LIB, useg1 stubbed, cwd = the glob dir
	(cd "$G" && PATH="$W/bin:$PATH" DIR="$W" "$BB" sh -c '
		. "$1"; . "$2"; scratch
		useg1() { echo "SEG1 $1" >> /tmp/ut.trace; }
		provd_present() { return 1; }
		eval "$3"' sh "$REPO/scripts/node/ble-lib-254.sh" "$LIB" "$1")
}
reset() { rm -rf /tmp/run/batman-dv /opt/batdata/state/dv-undo /opt/batdata/log/dv-undo-* /tmp/ut.ssid /tmp/ut.staged* /tmp/ut.trace /opt/batdata/state/autocommit-hold-commit; echo A > /tmp/ut.slot; }
setssid() { printf '%b' "$1" > /tmp/ut.ssid; }

# 1. node-side encode + round trip, registration, change, host-death replay: the exact bytes come back
for v in 'a*b' 'Lab 1' "x'y" '50%' 'a\\b' '*' '\rA'; do
	reset; setssid "$v"; want=$(od -An -tx1 /tmp/ut.ssid | tr -d ' \n')
	o=$(run 'h=$(ssid_hex); echo "$h"; case "$h" in "HEX="*" RT=ok") x=${h#HEX=}; undo_add r1 ssid-restore "${x% RT=ok}" ;; esac; printf %s changed > /tmp/ut.ssid; undo_run r1 deadman; echo "rc=$?"')
	got=$(od -An -tx1 /tmp/ut.ssid 2>/dev/null | tr -d ' \n')
	if grep -q "^HEX=$want RT=ok$" <<< "$o" && grep -q "^UNDO-ADDED 1 p6 slot:A ssid-restore $want$" <<< "$o" && [ "$got" = "$want" ] && grep -q rc=0 <<< "$o" \
		&& grep -q '^COMMIT umask=0022$' /tmp/ut.trace; then ok "ssid $(printf '%q' "$(printf '%b' "$v")"): hex $want registered (p6 slot:A), replay restores the exact bytes under umask 022"
	else no "ssid [$v]: want $want got $got :: $(tr '\n' '|' <<< "$o" | cut -c1-300) trace=$(tr '\n' '|' < /tmp/ut.trace 2>/dev/null)"; fi
done
# 2. an empty / unset S0 ssid: "-", replayed as a delete
reset; o=$(run 'h=$(ssid_hex); echo "$h"; undo_add r1 ssid-restore -; printf %s dv-s1 > /tmp/ut.ssid; undo_run r1 deadman; echo "rc=$?"')
grep -q '^HEX=- RT=ok$' <<< "$o" && [ ! -e /tmp/ut.ssid ] && grep -q rc=0 <<< "$o" && ok "unset S0 ssid: HEX=-, the replay deletes the test ssid" || no "empty ssid: $(tr '\n' '|' <<< "$o") left=[$(cat /tmp/ut.ssid 2>/dev/null)]"
# 3. values the replay would refuse: RT=bad at the encode, and refused at undo-add
reset; setssid 'a\nb'; o=$(run 'ssid_hex; echo "rc=$?"'); grep -q '^HEX=? RT=bad$' <<< "$o" && grep -q rc=1 <<< "$o" && ok "an ssid with a newline -> RT=bad" || no "newline ssid: $o"
reset; setssid "$(printf '%033d' 0)"; o=$(run 'ssid_hex; echo "rc=$?"'); grep -q '^HEX=? RT=bad$' <<< "$o" && ok "a 33-byte ssid -> RT=bad" || no "33 bytes: $o"
reset
o=$(run 'for a in 610a62 6100 '"$(printf '61%.0s' $(seq 33))"' 4C 616 "a*b" "61 62" "" "-x"; do undo_add r1 ssid-restore "$a" >/dev/null && echo "ACCEPTED [$a]"; done; undo_add r1 ssid-restore 61 62 >/dev/null && echo ACCEPTED-2ARGS; echo end')
[ "$o" = end ] && [ ! -e /opt/batdata/state/dv-undo/r1/journal ] && ok "undo-add refuses newline / NUL / > 32 bytes / upper case / odd length / raw / blank / two args" || no "undo-add accepted: $o"
# 4. undo-done
reset; : > /opt/batdata/state/autocommit-hold-commit
o=$(run 'undo_add r1 rm-hold; undo_done r1 7; echo "rc7=$?"; undo_done r1 1; echo "rc1=$?"; undo_done r1 1; echo "rc1b=$?"; undo_run r1 deadman; echo "rc=$?"')
grep -q '^UNDO-ADDED 1 p6 - rm-hold$' <<< "$o" && grep -q '^FAIL undo-done: no todo line 7' <<< "$o" && grep -q rc7=1 <<< "$o" && grep -q '^UNDO-DONE 1$' <<< "$o" && grep -q rc1=0 <<< "$o" \
	&& grep -q rc1b=1 <<< "$o" && [ -e /opt/batdata/state/autocommit-hold-commit ] && grep -q rc=0 <<< "$o" \
	&& ok "undo-done: unknown id FAILs, a known id is marked done and the replay skips it (the hold file stays)" || no "undo-done: $(tr '\n' '|' <<< "$o")"
# 5. rm-hold replay
reset; echo 1.5.14-wsl.36 > /opt/batdata/state/autocommit-hold-commit
o=$(run 'undo_add r1 rm-hold; undo_run r1 deadman; echo "rc=$?"')
[ ! -e /opt/batdata/state/autocommit-hold-commit ] && grep -q rc=0 <<< "$o" && ok "rm-hold: the replay removes the hold flag" || no "rm-hold: $o"
o=$(run 'undo_add r1 rm-hold x >/dev/null && echo ACCEPTED; echo end'); [ "$o" = end ] && ok "rm-hold takes no argument" || no "rm-hold arg: $o"
# 6. the UD13 / UD6 (b) registrations replayed after a host death: reverse order ssid-restore -> p5-save -> the first
reset; setssid S0ssid
o=$(run 'undo_add r1 test-count first; undo_add r1 p5-save; h=$(ssid_hex); x=${h#HEX=}; undo_add r1 ssid-restore "${x% RT=ok}"; printf %s "dv'"'"'q" > /tmp/ut.ssid; undo_run r1 deadman; echo "rc=$?"')
ord=$(grep -oE '^(COMMIT|CFGSAVE --save)' /tmp/ut.trace | tr '\n' ' '); tc=$(cat /tmp/run/batman-dv/undo-test/r1.count 2>/dev/null)
dl=$(grep -E 'done [0-9]+ ' /opt/batdata/log/dv-undo-r1.log | sed 's/.* done \([0-9]*\) \([a-z0-9-]*\).*/\2/' | tr '\n' ' ')
[ "$dl" = "ssid-restore p5-save test-count " ] && [ "$(cat /tmp/ut.ssid)" = S0ssid ] && grep -q rc=0 <<< "$o" && [ "$tc" = "deadman first" ] \
	&& ok "replay order: ssid-restore -> p5-save -> first registration ($ord)" || no "order: [$dl] ssid=[$(cat /tmp/ut.ssid)] $o"
# 7. negative control: the raw value in the executor's own unquoted rebuild of a line
line='1 todo slot:A ssid-restore a*b'; raw=$(cd "$G" && "$BB" sh -c 'set -- $(echo "$1"); shift 3; echo "$# [$*]"' sh "$line")
line2='1 todo slot:A ssid-restore Lab 1'; raw2=$(cd "$G" && "$BB" sh -c 'set -- $(echo "$1"); shift 3; echo "$#"' sh "$line2")
[ "$raw" = "2 [ssid-restore ab]" ] && [ "$raw2" = 3 ] && ok "negative control: raw 'a*b' globs to 'ab' and 'Lab 1' splits into 2 words in the unquoted rebuild" \
	|| no "negative control did not show the hazard: [$raw] [$raw2]"
echo "$pass PASS / $fails FAIL"; [ $fails = 0 ] && [ $pass -gt 0 ]
