#!/bin/sh
# scripts/node/addr-defer-254.sh — tier A (every committed node, every run): the address-reservation deferral of
# #254 B-M4 (254-p1-impl.md §13.8.2) is present and in its resting state. Read-only. Runs as root via `ssh node sh -s`.
# PASS/FAIL lines; rc 0 only when every check passed. Fail-closed: a missing tool is a FAIL, never a skip.
f=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; f=1; }
D=/usr/libexec/batman-addr-defer
# 1. both halves of the mechanism are in THIS image: the decider and the init hook (one without the other = fail-open)
[ -x "$D" ] && ok "decider present ($D)" || no "decider missing: $D"
grep -q 'batman-addr-defer' /etc/init.d/openmanetd 2>/dev/null && ok "openmanetd init carries the hook (board patch 0014)" || no "openmanetd init has no batman-addr-defer hook"
# 2. the decider's only boot-time input exists on this board (CM4 / Pi 4 reality check, round-12 A12-m9): a missing DT
#    node makes it fail-open (stock behaviour) silently
[ -r /proc/device-tree/chosen/bootloader/tryboot ] && ok "DT tryboot node present" || no "DT /proc/device-tree/chosen/bootloader/tryboot missing (decider would be fail-open on this board)"
# 3. resting state on a committed slot: not a trial, nothing deferred, openmanetd up
rc=1; batman-slot is-trial >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] || { no "node is not a committed slot (is-trial rc=$rc) — this check belongs to committed nodes"; echo "RESULT addr-defer-254 FAIL"; exit 1; }
s=$([ -x "$D" ] && "$D" status 2>/dev/null)
[ "$s" = "want=stock env=absent openmanetd=up" ] && ok "status: $s" || no "status on a committed slot: [$s] (want 'want=stock env=absent openmanetd=up')"
# the authoritative view, independent of the decider: procd's env of the running instance
u=$(ubus -t 5 call service list '{"name":"openmanetd"}' 2>/dev/null) || no "ubus service list failed"
case "$u" in *ADDRESSRESERVATION*) no "procd still carries ALFRED.DATATYPES.ADDRESSRESERVATION for openmanetd on a committed slot";; *) ok "procd env: no deferral variable";; esac
# 4. no stale reconcile state and no HUNG this boot (run dir resolved through rundir.sh, #280: a #280 image always has it)
R=""; [ -r /usr/lib/batman/rundir.sh ] && . /usr/lib/batman/rundir.sh && R=$RUNDIR
[ -n "$R" ] || no "no /usr/lib/batman/rundir.sh on this image (pre-#280?) — run dir unknown"
[ -e "$R/addr-defer.starts" ] && { n=$(cat "$R/addr-defer.starts"); [ "$n" -ge 3 ] 2>/dev/null && no "reconcile reached its cap this boot ($n starts) — HUNG" || ok "reconcile ran $n start(s) this boot (below the cap)"; } || ok "no reconcile start this boot"
logread 2>/dev/null | grep -q 'batman-addr-defer: HUNG' && no "HUNG logged this boot" || ok "no HUNG in logread"
# 5. a settled committed node has reserved its address (openmanetd's own job, but the deferral must not have blocked it)
up=$(cut -d. -f1 /proc/uptime)
if [ "$up" -ge 300 ]; then
	[ "$(uci -q get openmanetd.config.dhcpconfigured)" = 1 ] && ok "dhcpconfigured=1 after ${up}s" || no "dhcpconfigured != 1 after ${up}s (address never reserved)"
else ok "uptime ${up}s < 300: dhcpconfigured not judged yet"; fi
[ "$f" = 0 ] && echo "RESULT addr-defer-254 PASS" || echo "RESULT addr-defer-254 FAIL"
exit $f
