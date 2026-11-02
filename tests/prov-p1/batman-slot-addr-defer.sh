#!/bin/bash
# tests/prov-p1/batman-slot-addr-defer.sh <batman-slot> — #254 §13.8.2: `batman-slot commit` releases the
# address-reservation deferral (writes $RUNDIR/slot-committed, sends ONE detached `env -i … setsid /etc/init.d/openmanetd
# start`, never changes the commit's rc) and `rollback` removes the flag. Stubbed: the two functions are extracted
# from the real file and run under fake batman_rundir / st / setsid / init. No root, no node.
# Negative control: a batman-slot without addr_defer_release (e.g. 6e3a8c1) -> FAIL "function missing".
set -u
BS=$1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
fn=$(awk '/^addr_defer_release\(\) \{/,/^\}/' "$BS")
[ -n "$fn" ] || { no "addr_defer_release() missing from $BS"; echo "BATMAN-SLOT-ADDR-DEFER fails=1"; exit 1; }
rb=$(awk '/^cmd_rollback\(\) \{/,/^\}/' "$BS" | grep 'slot-committed')
[ -n "$rb" ] && ok "cmd_rollback removes slot-committed: $(echo "$rb" | sed 's/^\s*//' | cut -c1-60)" || no "cmd_rollback does not remove slot-committed"
grep -q 'addr_defer_release$' <(awk '/^cmd_commit\(\) \{/,/^\}/' "$BS") && ok "cmd_commit calls addr_defer_release last" || no "cmd_commit does not call addr_defer_release"
# the detached start must be env -i + setsid + the init, stdio detached, backgrounded
echo "$fn" | grep -q 'env -i PATH=[^ ]* setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 &' && ok "detached start: env -i, setsid, stdio to /dev/null, &" || no "detached start line not as designed"
mkdir -p "$T/bin" "$T/run" "$T/libexec"; printf '#!/bin/sh
exit 1
' > "$T/libexec/batman-addr-defer"; chmod +x "$T/libexec/batman-addr-defer"   # a real executable (MSYS judges -x by content)
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/setsid"; chmod +x "$T/bin/setsid"
printf '#!/bin/sh\necho "start $*" >> %s/init.log\n' "$T" > "$T/omd.init"; chmod +x "$T/omd.init"
# run the extracted function with stubs: rundir ok / unusable; count starts and st lines
run_fn(){ # $1 rundir rc
	rm -f "$T/init.log" "$T/st.log" "$T/run/slot-committed"
	bash -c "
RUNDIR=$T/run
batman_rundir(){ return $1; }
st(){ echo \"st \$*\" >> $T/st.log; }
$(echo "$fn" | sed -e "s#/usr/libexec/batman-addr-defer#$T/libexec/batman-addr-defer#" -e "s#/etc/init.d/openmanetd#$T/omd.init#" -e "s#env -i PATH=[^ ]* #env -i PATH=$T/bin:/usr/bin:/bin #")
addr_defer_release; echo rc=\$? >> $T/st.log; wait"
}
run_fn 0; sleep 1
[ -e "$T/run/slot-committed" ] && ok "commit: slot-committed written" || no "commit: flag not written"
[ "$(grep -c '^start start' "$T/init.log" 2>/dev/null)" = 1 ] && ok "commit: exactly one detached start" || no "commit: starts=$(grep -c . "$T/init.log" 2>/dev/null)"
grep -q 'ADDR-DEFER-RELEASE flag=written' "$T/st.log" && grep -q 'rc=0' "$T/st.log" && ok "commit: traced, rc 0" || no "commit: trace/rc: $(cat "$T/st.log")"
run_fn 1; sleep 1
[ ! -e "$T/run/slot-committed" ] && grep -q 'flag=NOT-written reason=rundir-unusable' "$T/st.log" && ok "run dir unusable: no flag, traced" || no "run dir unusable: $(cat "$T/st.log")"
[ "$(grep -c '^start start' "$T/init.log" 2>/dev/null)" = 1 ] && grep -q 'rc=0' "$T/st.log" && ok "run dir unusable: start still sent, rc still 0" || no "run dir unusable: start/rc wrong"
# the leaked-environment check (round-12 A12-m5): a caller variable must not reach the init
printf '#!/bin/sh\necho "start LEAK=${BATMAN_FAULT_INJECT:-none}" >> %s/init.log\n' "$T" > "$T/omd.init"
BATMAN_FAULT_INJECT=boom run_fn 0; sleep 1
grep -q 'LEAK=none' "$T/init.log" && ok "env -i: caller environment does not reach the init" || no "env -i: leaked: $(cat "$T/init.log")"
# decider absent -> nothing happens, rc 0
rm -f "$T/libexec/batman-addr-defer"; run_fn 0; sleep 1
[ ! -e "$T/init.log" ] && [ ! -e "$T/run/slot-committed" ] && grep -q 'rc=0' "$T/st.log" && ok "no decider in the image: release is a no-op" || no "no decider: $(cat "$T/st.log") $(cat "$T/init.log" 2>/dev/null)"
echo "BATMAN-SLOT-ADDR-DEFER fails=$fails"; [ $fails = 0 ]
