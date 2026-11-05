#!/bin/bash
# scripts/dv/test-h4-undo.sh — #254 H4 undo executor on 04 (docs/design/254-h4-harness.md §5.7 "測試"). Git Bash.
# Arms (each its own run id and lease; nothing is renewed in a deadman arm, so the lease deadman fires):
#   D-<cat>   one deadman arm per action category: make the change, register its undo, let the lease run out ->
#             the deadman's undo executor puts it back -> assert the state and the "done" line in dv-undo-<run>.log
#             categories: rm-file link-del netns-del link-master nft-del-table uci-revert uci-restore svc-enable
#             svc-start p5-save kill-pg  [+ fw-start with --with-fw, bt-start with --with-bt]
#   H-normal  host mode, lease valid throughout -> release cancels the deadman -> the deadman did nothing
#   H-expire  host mode outlives the lease (test-count slow) -> release FAILs, the deadman waits for the lock, finds
#             everything done -> each action ran exactly once
#   H-stuck   host mode hangs (test-count stall, a tool that escapes lim) past lease + 10 min -> the deadman stops the
#             host executor, does both segments -> a / c once, b twice (the hung one), lock free afterwards
#   V-param   a tampered journal line (rm-file /etc/passwd) -> CRIT, /etc/passwd unchanged
# The scratch it makes on 04 (package /etc/config/undotest, /etc/init.d/h4undo, h4u* / h4m0 links, netns h4z, nft
# table inet h4undo, flags under /tmp/run/batman-dv/) is removed at the end whatever happened (printed first).
#   bash scripts/dv/test-h4-undo.sh [--with-fw] [--with-bt] [--only <arm>...]
PR_UNIT=prov-h4undo-254
. "$(dirname "$0")/prov-254.sh"
WITH_FW=0; WITH_BT=0; ONLY=""
while [ $# -gt 0 ]; do case "$1" in --with-fw) WITH_FW=1 ;; --with-bt) WITH_BT=1 ;; --only) shift; ONLY="$ONLY $1" ;; *) echo "bad arg $1"; exit 2 ;; esac; shift; done
BASE=$RUN; ARMN=0; CUR=""
want(){ [ -z "$ONLY" ] && return 0; case " $ONLY " in *" $1 "*) return 0 ;; esac; return 1; }
newrun(){ ARMN=$((ARMN + 1)); RUN="${BASE}u$ARMN"; PRD=/tmp/run/batman-dv/bt/$RUN; CUR=$1; say "== arm $1 (run $RUN)"; }
ulog_(){ qr "cat /opt/batdata/log/dv-undo-$RUN.log 2>/dev/null"; }
lease_gone(){ local t=0; while [ $t -lt "${1:-40}" ]; do [ -z "$(qr "cat /tmp/run/batman-dv/bt/lease-prov 2>/dev/null")" ] && return 0; sleep 5; t=$((t + 1)); done; return 1; }
dm_done(){	# wait for the deadman of $RUN to finish (lease gone + its undo end line), up to $1 x 5 s
	local t=0; while [ $t -lt "${1:-60}" ]; do
		[ -z "$(qr "cat /tmp/run/batman-dv/bt/lease-prov 2>/dev/null")" ] && ulog_ | grep -q 'undo_run deadman end' && return 0
		sleep 5; t=$((t + 1)); done; return 1; }
cleanup(){
	say "cleanup of the test scratch on 04 (printed, then removed):"
	q 'ls -l /etc/config/undotest /etc/init.d/h4undo /etc/rc.d/*h4undo 2>/dev/null; ls /sys/class/net | grep -E "^h4(u|m)"; ip netns list | grep h4z; nft list table inet h4undo >/dev/null 2>&1 && echo "nft table inet h4undo"; ls /tmp/run/batman-dv/h4u.* 2>/dev/null' | sed 's/^/  /'
	q '[ -x /etc/init.d/h4undo ] && /etc/init.d/h4undo disable; rm -f /etc/init.d/h4undo /etc/config/undotest /tmp/run/batman-dv/h4u.* /tmp/run/batman-dv/h4undo.started; uci -q revert undotest
	   for d in h4u0 h4m0; do [ -e /sys/class/net/$d ] && ip link del $d; done; ip netns del h4z 2>/dev/null; nft delete table inet h4undo 2>/dev/null
	   for p in $(pidof sh); do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q h4killme && kill $p; done; true'
	o=$(q 'ls /etc/config/undotest /etc/init.d/h4undo 2>/dev/null; ls /sys/class/net | grep -E "^h4"; ip netns list | grep "^h4"; nft list table inet h4undo 2>/dev/null | head -1')
	[ -z "$o" ] && say "cleanup: nothing left" || no "cleanup left: $(echo $o)"
}
trap 'cleanup; pr_unlock' EXIT

pr_lock
o=$(pr_p9); echo "$o"; grep -q '^FAIL' <<< "$o" && { no "preconditions"; exit 1; }
q "rm -rf /tmp/run/batman-dv/undo-test"

# ---- D-<cat>: one deadman arm per category -----------------------------------------------------------------------
# d_arm <cat> <make-change+register (node sh, $L = lease cmd)> <assert after the deadman (node sh: rc 0 = restored)>
d_arm(){
	want "D-$1" || return 0
	newrun "D-$1"; o=$(pr_acquire 45) || { no "D-$1: lease: $o"; return; }
	L="env RUN_ID=$RUN sh $PRD/prov-lease-254.sh"	# env: an expanded RUN_ID=... is no assignment
	o=$(q "L='$L'; $2" 2>&1); say "D-$1 setup: $(echo $o)"
	grep -q '^UNDO-ADDED' <<< "$o" || { no "D-$1: setup did not register: $o"; pl release >/dev/null; return; }
	dm_done 60 || { no "D-$1: the deadman did not finish within 5 min"; return; }
	u=$(ulog_); say "D-$1 undo log: $(grep -E 'done|FAIL|CRIT|NEEDS|seg1' <<< "$u" | sed 's/^.*boot=[0-9a-f]* //' | tr '\n' '|')"
	grep -qE "done [0-9]* $1|seg1 $1 [0-9]+ " <<< "$u" || no "D-$1: no 'done' line for $1"	# kill-pg: segment 1 logs "seg1 kill-pg <pg>"
	grep -qE 'FAIL|CRIT|NEEDS' <<< "$u" && no "D-$1: FAIL / CRIT / NEEDS-PERSON in the undo log"
	o=$(q "$3 && echo RESTORED-OK"); grep -q RESTORED-OK <<< "$o" && ok "D-$1: the deadman's undo put it back" || no "D-$1: not restored: $o"
	o=$(qr "[ -e /tmp/run/batman-dv/undo/$RUN ] || [ -e /opt/batdata/state/dv-undo/$RUN ] && echo JOURNAL-LEFT"); [ -z "$o" ] || no "D-$1: journal left"
}
d_arm rm-file 'f=/tmp/run/batman-dv/h4u.flag; (umask 077; echo x > $f) && $L undo-add rm-file $f' '[ ! -e /tmp/run/batman-dv/h4u.flag ]'
d_arm link-del '$L undo-add link-del h4u0 && ip link add h4u0 type veth peer name h4u1' '[ ! -e /sys/class/net/h4u0 ] && [ ! -e /sys/class/net/h4u1 ]'
d_arm netns-del '$L undo-add netns-del h4z && ip netns add h4z' '! ip netns list | grep -qw h4z'
d_arm link-master 'ip link add h4m0 type veth peer name h4m1 && ip link set h4m0 master br-ahwlan && $L undo-add link-del h4m0 && $L undo-add link-master h4m0 br-ahwlan && ip link set h4m0 nomaster' \
	'[ ! -e /sys/class/net/h4m0 ]'
d_arm nft-del-table '$L undo-add nft-del-table inet h4undo && nft add table inet h4undo' '! nft list table inet h4undo >/dev/null 2>&1'
d_arm uci-revert 'printf "config x y\n\toption a 1\n" > /etc/config/undotest && $L undo-add uci-revert undotest && uci set undotest.y.a=2' '[ -z "$(uci -q changes undotest)" ] && [ "$(uci -q get undotest.y.a)" = 1 ]'
d_arm uci-restore 'printf "config x y\n\toption a 1\n" > /etc/config/undotest && $L undo-add uci-restore undotest && uci set undotest.y.a=3 && uci commit undotest' '[ "$(uci -q get undotest.y.a)" = 1 ] && [ -z "$(uci -q changes undotest)" ]'
H4INIT='printf "#!/bin/sh /etc/rc.common\nSTART=99\nstart() { touch /tmp/run/batman-dv/h4undo.started; }\nstop() { rm -f /tmp/run/batman-dv/h4undo.started; }\n" > /etc/init.d/h4undo && chmod 755 /etc/init.d/h4undo'
d_arm svc-enable "$H4INIT"' && /etc/init.d/h4undo enable && $L undo-add svc-enable h4undo && /etc/init.d/h4undo disable && ! /etc/init.d/h4undo enabled' '/etc/init.d/h4undo enabled'
d_arm svc-start "$H4INIT"' && rm -f /tmp/run/batman-dv/h4undo.started && $L undo-add svc-start h4undo' '[ -e /tmp/run/batman-dv/h4undo.started ]'
d_arm p5-save 'batman-config-save --check >/dev/null 2>&1 || { echo "p5 not fresh before the arm: rc $?"; exit 1; }; $L undo-add p5-save' 'batman-config-save --check >/dev/null 2>&1'
d_arm kill-pg 'setsid sh -c "sleep 600; : h4killme" </dev/null >/dev/null 2>&1 & sleep 1; pg=$(cut -d" " -f5 /proc/$!/stat); echo "pg=$pg"; $L undo-add kill-pg $pg h4killme' \
	'! for p in $(pidof sh); do tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q h4killme && echo alive; done | grep -q alive'
[ $WITH_FW = 1 ] && d_arm fw-start '$L undo-add fw-start && /etc/init.d/firewall stop' 'nft list table inet fw4 >/dev/null 2>&1'
[ $WITH_BT = 1 ] && d_arm bt-start '$L undo-add bt-start && /etc/init.d/bluetoothd stop && sleep 2 && ! pidof bluetoothd' 'pidof bluetoothd >/dev/null'

cnt(){ qr "grep -c '$1' /tmp/run/batman-dv/undo-test/$RUN.count 2>/dev/null || true"; }

# ---- H-normal ----------------------------------------------------------------------------------------------------
if want H-normal; then newrun H-normal; o=$(pr_acquire 300) || no "H-normal lease: $o"
	pl undo-add test-count a >/dev/null; pl undo-add test-count b >/dev/null
	o=$(QT=200 pl undo); grep -qx 'UNDO undo_run host end rc=0' <<< "$o" || no "H-normal: host undo: $(echo $o)"
	o=$(pl release); grep -q RELEASED <<< "$o" || no "H-normal: release: $o"
	sleep 10; d=$(qr "grep -c 'run=$RUN prov deadman' /opt/batdata/log/ble-dm-254.log 2>/dev/null || true")
	[ "$(cnt 'host a$')" = 1 ] && [ "$(cnt 'host b$')" = 1 ] && [ "$(cnt deadman)" = 0 ] && [ "${d:-0}" = 0 ] \
		&& ok "H-normal: host did both once, release cancelled the deadman (0 deadman lines)" || no "H-normal: a=$(cnt 'host a$') b=$(cnt 'host b$') dm-count=$(cnt deadman) dm-lines=$d"
fi

# ---- H-expire ----------------------------------------------------------------------------------------------------
if want H-expire; then newrun H-expire; o=$(pr_acquire 40) || no "H-expire lease: $o"
	pl undo-add test-count a >/dev/null; pl undo-add test-count s slow >/dev/null; pl undo-add test-count c >/dev/null
	o=$(QT=300 pl undo); say "H-expire host: $(grep -E 'end rc|FAIL' <<< "$o" | tr '\n' '|')"
	o=$(pl release); grep -q 'lease is not ours or expired' <<< "$o" && ok "H-expire: release FAILs (the lease ran out during the host undo)" || no "H-expire: release: $o"
	dm_done 40 || lease_gone 20 || no "H-expire: the deadman did not finish"
	[ "$(cnt 'host a$')" = 1 ] && [ "$(cnt 'host s$')" = 1 ] && [ "$(cnt 'host c$')" = 1 ] && [ "$(cnt deadman)" = 0 ] \
		&& ok "H-expire: each action exactly once (all by the host; the deadman found them done)" || no "H-expire: $(qr "cat /tmp/run/batman-dv/undo-test/$RUN.count" | tr '\n' '|')"
fi

# ---- H-stuck (about 17 min: lease 60 s + the deadman's 10 min lock wait + 330 s for the hung tool) ----------------
if want H-stuck; then newrun H-stuck; o=$(pr_acquire 60) || no "H-stuck lease: $o"
	pl undo-add test-count a >/dev/null; pl undo-add test-count b stall >/dev/null; pl undo-add test-count c >/dev/null
	( QT=1800 pl undo > "$TEMP/h4undo-stuck.$RUN" 2>&1 ) & hp=$!
	say "H-stuck: host undo running (pid $hp), waiting for the deadman"
	t=0; while [ $t -lt 240 ]; do qr "grep -q 'undo_run deadman end' /opt/batdata/log/dv-undo-$RUN.log 2>/dev/null" && break; sleep 10; t=$((t + 1)); done
	wait $hp 2>/dev/null
	u=$(ulog_); say "H-stuck undo log: $(grep -E 'host executor|done|FAIL|NEEDS|end' <<< "$u" | sed 's/^.*boot=[0-9a-f]* //' | tr '\n' '|')"
	[ "$(cnt 'a$')" = 1 ] && [ "$(cnt 'b$')" = 2 ] && [ "$(cnt 'c$')" = 1 ] && grep -q 'host executor group .* gone' <<< "$u" && grep -q ' undo_run deadman end rc=0$' <<< "$u" \
		&& ok "H-stuck: the deadman stopped the host executor and finished both segments (a, c once; b twice)" || no "H-stuck: $(qr "cat /tmp/run/batman-dv/undo-test/$RUN.count" | tr '\n' '|')"
	newrun H-stuck-after; o=$(pr_acquire 60) && grep -q RELEASED <<< "$(pl release)" && ok "H-stuck: the lock is free afterwards (acquire + release)" || no "H-stuck: lease commands after: $o"
fi

# ---- V-param -----------------------------------------------------------------------------------------------------
if want V-param; then newrun V-param; o=$(pr_acquire 300) || no "V-param lease: $o"
	s0=$(qr 'sha256sum /etc/passwd'); pl undo-add test-count a >/dev/null
	q "echo '9 todo - rm-file /etc/passwd' >> /tmp/run/batman-dv/undo/$RUN/journal"
	o=$(QT=200 pl undo); s1=$(qr 'sha256sum /etc/passwd')
	grep -q 'CRIT line 9 refused: rm-file /etc/passwd' <<< "$o" && [ -n "$s0" ] && [ "$s0" = "$s1" ] \
		&& ok "V-param: rm-file /etc/passwd refused (CRIT), /etc/passwd unchanged" || no "V-param: $(echo $o) [$s0] [$s1]"
	say "V-param: the tampered journal (printed, then removed): $(qr "cat /tmp/run/batman-dv/undo/$RUN/journal" | tr '\n' '|')"
	q "rm -rf /tmp/run/batman-dv/undo/$RUN"; o=$(pl release); grep -q RELEASED <<< "$o" || no "V-param: release: $o"
fi

o=$( { cat "$REPO/scripts/node/ble-lib-254.sh"; echo provd_check; } | timeout 90 ssh $SSHO root@$NODE sh -s 2>&1 | tr -d '\r' | tail -1)	# every run dir is gone by now: the lib through stdin
say "provd after the arms: $o"; grep -q 'PROVD ok' <<< "$o" || no "provd after the arms: $o"
o=$(qr 'ls -A /tmp/run/batman-dv/undo/ /opt/batdata/state/dv-undo/ 2>/dev/null | grep -v -e "^$" -e ":$"'); [ -z "$o" ] && ok "no undo journal left" || no "undo journals left: $(echo $o)"
say "fails=$fails invalid=$invalid"; [ "$fails" = 0 ] && echo "TEST-H4-UNDO PASS" || echo "TEST-H4-UNDO FAIL"
