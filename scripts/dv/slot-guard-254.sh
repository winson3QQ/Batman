# shellcheck shell=bash
# scripts/dv/slot-guard-254.sh — every harness `batman-slot rollback` goes through rb_guarded, and every reboot that must
# land on the other slot through reboot_guarded (reviews 2026-11-09 B-MAJOR-1, round 5 MAJOR-1).
# 2026-11-08: a rollback decided on a host-side read of the node (a substring match on "badslot=[slot=B …]") went to a
# node already on A committed; the default became the fresh, keyless B and a person had to edit autoboot.txt on the
# SD card. A state read on the host can be stale or mis-parsed, so the node checks it again in the SAME command as
# the action: boot id, active slot, trial state, and an optional extra condition.
#
# rb_guarded     <boot8> <active A|B> <trial 0|1|any> <reason> [extra shell condition]
# reboot_guarded <boot8> <active A|B> <trial 0|1|any> <reason> [extra shell condition]
#   print the node-side command; its output is exactly one of
#     SENT                         rb_guarded: rollback done, then `batman-slot reboot committed <reason>` started in the
#                                  background; reboot_guarded: only the reboot (an uncommitted trial goes back to its
#                                  committed slot by itself: the tryboot is one-shot)
#     REFUSED                      rb_guarded only: every check held, `batman-slot rollback` itself refused
#     WRONG-STATE boot=… active=… trial=… extra=-|0   a check failed: nothing was done. extra=- : boot / slot / trial
#                                  did not match (the extra condition was not run: it may act, e.g. disarm a tryboot);
#                                  extra=0 : they matched and the extra condition failed (round 6 B-MINOR-3)
# release_guarded <boot8> <active A|B> [wait|nowait] [extra shell condition]
#   `batman-autocommit release` (wait: `--wait`, the default; nowait: without, then "rc=N") only in that boot, on that
#   slot, in an uncommitted trial: a release that reaches another boot commits whatever trial runs there (round 6
#   B-MINOR-5). Output: the release's own output, or WRONG-STATE.
#   trial: 0 = an uncommitted trial (`batman-slot is-trial` rc 0), 1 = committed, any = either; rc 2 (unknown) matches
#   only `any`. <boot8> must be 8 lower-case hex digits (a state line's boot=), anything else can never match.
# Callers: anything but SENT is a failure (abort / NEEDS-PERSON), never "go on as if it had been sent". No answer at all
# (ssh dropped) is not SENT either: the action may or may not have run, so the caller does not guess — it stops and says
# so (a lost SENT costs a person a look; a guessed one can strand the node).
_sg_cmd(){
	local b=$1 a=$2 t=$3 why=$4 x=$5 act=$6
	case "$b" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) b=invalid-boot ;; esac
	case "$a" in A|B) ;; *) a=invalid-slot ;; esac
	case "$t" in 0|1|any) ;; *) t=invalid-trial ;; esac
	case "$why" in *[!A-Za-z0-9._-]*|'') why=invalid-reason ;; esac
	local rb="(batman-slot reboot committed $why </dev/null >/dev/null 2>&1 &); echo SENT"
	[ "$act" = rollback ] && rb="if batman-slot rollback >/dev/null 2>&1; then $rb; else echo REFUSED; fi"
	[ "$act" = release ] && rb="batman-autocommit release --wait 2>&1"
	[ "$act" = release-nowait ] && rb="batman-autocommit release 2>&1; echo rc=\$?"
	printf '%s' "b=\$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null); a=\$(batman-slot active 2>/dev/null); batman-slot is-trial >/dev/null 2>&1; t=\$?; if [ -n \"\$b\" ] && [ \"\$b\" = '$b' ] && [ \"\$a\" = '$a' ] && { [ '$t' = any ] || [ \"\$t\" = '$t' ]; }; then if { $x; }; then $rb; else echo \"WRONG-STATE boot=\$b active=\$a trial=\$t extra=0\"; fi; else echo \"WRONG-STATE boot=\$b active=\$a trial=\$t extra=-\"; fi"
}
rb_guarded(){ _sg_cmd "$1" "$2" "$3" "$4" "${5:-true}" rollback; }
reboot_guarded(){ _sg_cmd "$1" "$2" "$3" "$4" "${5:-true}" reboot; }
release_guarded(){ local m=release; [ "${3:-wait}" = nowait ] && m=release-nowait; _sg_cmd "$1" "$2" 0 release "${4:-true}" "$m"; }
