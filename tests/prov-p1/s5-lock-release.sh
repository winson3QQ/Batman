#!/bin/bash
# tests/prov-p1/s5-lock-release.sh <batman-slot> — #254 P3 S5 (254-p3-impl §3.7.3 "每個持鎖動詞回來後 1 s 內 flock -n
# 拿得到", harness review r3 A MAJOR-1): the one place batman-slot starts a background child while the slot flock is held —
# addr_defer_release (the end of commit; the only background line s5-lock-lint's (b) list allows outside cmd_reboot) —
# is extracted from the product and run by busybox sh and by dash with fd 9 holding the flock of a temp lock file and an
# openmanetd init stub that lives 30 s. After it returns and the caller closes fd 9, `flock -n` on the lock must succeed
# within 1 s: the child must not hold it. This is run, not read: whether the child keeps fd 9 depends on what runs in the
# background (an external program: `9>&-` closes it; a shell function or eval: the shell saves fd 9 to fd >= 10 for the
# redirection and keeps it, review r3 A leak4.out), which no source lint can tell.
# Negative controls (in the test, both shells): the start without `9>&-` -> the lock stays held; the same start wrapped in
# a shell function backgrounded with `9>&-` -> the lock stays held. A start that never ran = FAIL (nothing proven).
# Ubuntu's busybox has no flock applet: util-linux flock takes and probes the lock (the same flock(2)), as s5-slot-lock.sh.
set -u
BS=$(readlink -f "${1:?usage: $0 <batman-slot>}")
pass=0; fail=0
ok(){ pass=$((pass + 1)); echo "ok   $*"; }; bad(){ fail=$((fail + 1)); echo "FAIL $*"; }
awk '/^slot_lock\(\) \{/,/^\}/' "$BS" | grep -q 'flock -n 9' || {
	echo "FAIL $BS predates S5 (no flock slot_lock): expected red until feat/254-p3 S5 lands (#254)"
	echo "S5-LOCK-RELEASE pass=0 fail=1"; exit 1; }
fn=$(awk '/^addr_defer_release\(\) \{/,/^\}/' "$BS")
[ -n "$fn" ] || { echo "FAIL addr_defer_release() missing from $BS"; echo "S5-LOCK-RELEASE pass=0 fail=1"; exit 1; }
FL=$(command -v flock); DASH=$(command -v dash); BBX=$(command -v busybox)
[ -n "$FL" ] && [ -n "$DASH" ] && [ -n "$BBX" ] || { echo "FAIL need flock, dash, busybox (got '$FL' '$DASH' '$BBX')"; echo "S5-LOCK-RELEASE pass=0 fail=1"; exit 1; }
T=$(mktemp -d)
reap(){ local p; for p in $(cat "$T"/pid.* 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -f "$T"/pid.*; }
trap 'reap; rm -rf "$T"' EXIT
mkdir -p "$T/libexec" "$T/run"
printf '#!/bin/sh\nexit 0\n' > "$T/libexec/batman-addr-defer"; chmod +x "$T/libexec/batman-addr-defer"
k=0
# run <shell> <function text> -> "free <ms>" / "held", plus " started" when the init stub ran
run(){
	k=$((k + 1)); local lock=$T/lock.$k r=held i
	printf '#!/bin/sh\necho $$ > %s/pid.%s\nexec sleep 30\n' "$T" "$k" > "$T/omd.init"; chmod +x "$T/omd.init"
	printf '%s\n' "$2" | sed -e "s#/usr/libexec/batman-addr-defer#$T/libexec/batman-addr-defer#" -e "s#/etc/init.d/openmanetd#$T/omd.init#" > "$T/fn.sh"
	grep -q "$T/omd.init" "$T/fn.sh" || { echo "nostub"; return; }
	PATH=/usr/bin:/bin "$1" -c '
		RUNDIR=$1/run; batman_rundir(){ return 0; }; st(){ :; }
		. "$1/fn.sh"
		exec 9>>"$2"; flock -n 9 || exit 3
		addr_defer_release || exit 4
		exec 9>&-' sh "$T" "$lock" || { echo "rc$?"; return; }
	for i in 1 2 3 4 5 6 7 8 9 10; do "$FL" -n "$lock" true && { r="free $((i * 100))"; break; }; sleep 0.1; done
	for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/pid.$k" ] && break; sleep 0.1; done
	[ -s "$T/pid.$k" ] && r="$r started"
	reap; echo "$r"
}
nofd=$(printf '%s\n' "$fn" | sed -E '/openmanetd start/s/ 9>&- (&)$/ \1/')
wrap=$(printf '%s\n' "$fn" | sed -E 's/^([[:space:]]*)(env -i .*openmanetd start .*) 9>&- &$/\1_adr_bg() { \2; }; _adr_bg 9>\&- \&/')
[ "$nofd" != "$fn" ] && [ "$wrap" != "$fn" ] || bad "a negative control did not change the function (the start line is not as expected)"
for sh in "$BBX sh" "$DASH"; do
	name=${sh##*/}
	S=$T/sh.$name; printf '#!/bin/sh\nexec %s "$@"\n' "$sh" > "$S"; chmod +x "$S"
	r=$(run "$S" "$fn"); ms=${r#free }; ms=${ms% started}
	case "$r" in "free "*" started") ok "$name: commit's background start does not keep the slot lock (flock -n got it within $ms ms, the init stub still running)" ;;
		*) bad "$name: the lock is not free within 1 s after addr_defer_release returned, or nothing started: $r" ;; esac
	r=$(run "$S" "$nofd"); [ "$r" = "held started" ] && ok "$name: negative control, the start without 9>&- keeps the lock" || bad "$name: negative control without 9>&-: $r (want held started)"
	r=$(run "$S" "$wrap"); [ "$r" = "held started" ] && ok "$name: negative control, a shell function backgrounded with 9>&- keeps the lock" || bad "$name: negative control function + 9>&-: $r (want held started)"
done
echo "S5-LOCK-RELEASE pass=$pass fail=$fail"
[ "$fail" = 0 ] && [ "$pass" -gt 0 ]
