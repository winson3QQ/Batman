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
#   Both disarm a one-shot tryboot first (DISARMED, part of the extra condition): not disarmed -> WRONG-STATE extra=0.
#     REFUSED                      rb_guarded only: every check held, `batman-slot rollback` itself refused
#     WRONG-STATE boot=… active=… trial=… extra=-|0   a check failed: nothing was done. extra=- : boot / slot / trial
#                                  did not match (the extra condition was not run: it may act, e.g. disarm a tryboot);
#                                  extra=0 : they matched and the extra condition failed (round 6 B-MINOR-3)
# reboot_guarded's 5th argument `-` = no extra condition (true); its 6th, <pre> (#254 v1.6 group 4 §4.1), is a shell
#   command run only after every check passed and the tryboot is disarmed, right before the reboot; its output goes to
#   `logger -t slot-guard`. The reboot follows even when <pre> fails (today's ordering: the node is not left half-done
#   AND unrebooted); the answer is then `PRE-FAILED SENT`, and the caller FAILs. On WRONG-STATE <pre> never runs.
# commit_guarded <boot8> <active A|B>
#   `batman-slot commit` only in that boot, on that slot, in an uncommitted trial (is-trial rc 0). No DISARM: a commit
#   does not reboot. Output: `SENT <the commit's own output>`, or WRONG-STATE (nothing done).
# release_guarded <boot8> <active A|B> [wait|nowait] [extra shell condition]
#   `batman-autocommit release` (wait: `--wait`, the default; nowait: without, then "rc=N") only in that boot, on that
#   slot, in an uncommitted trial: a release that reaches another boot commits whatever trial runs there (round 6
#   B-MINOR-5). Output: the release's own output, or WRONG-STATE.
#   trial: 0 = an uncommitted trial (`batman-slot is-trial` rc 0), 1 = committed, any = either; rc 2 (unknown) matches
#   only `any`. <boot8> must be 8 lower-case hex digits (a state line's boot=), anything else can never match.
# prepare_guarded <boot8> <cmd>   (#254 v1.6 g4 PR B, 254-v16-ud §2) <cmd> = the provclient `update-prepare` line,
#   run only in that boot, on A committed (is-trial rc 1): prepare writes the INACTIVE slot B. Output: <cmd>'s own, or
#   WRONG-STATE (nothing sent to the helper).
# apply_guarded <boot8> <cmd>     the same for `update-apply` (it arms the tryboot and reboots), plus DISARMED first: an
#   armed tryboot left by anything else is cleared and must read 0, else WRONG-STATE extra=0.
#   Both are reached only through pr_pc GUARD=prepare:<boot8> / GUARD=apply:<boot8> (prov-254.sh), which refuses an
#   update-prepare / update-apply without one.
# Callers: anything but SENT is a failure (abort / NEEDS-PERSON), never "go on as if it had been sent". No answer at all
# (ssh dropped) is not SENT either: the action may or may not have run, so the caller does not guess — it stops and says
# so (a lost SENT costs a person a look; a guessed one can strand the node).
# DISARM: clear the one-shot tryboot flag, then print tryboot_flag=0|1|unknown, read exactly like the product's bf_get
# (bootfacts.sh: response code word 2 must be 0x80000000, the value word 6 is hex, `$(( ))`). vcmailbox prints every
# word as 0x%08x (trybootget-209.log on the bench nodes: "… 0x80000004 0x00000000"); round 7 B-BLOCKER-1: the old
# string compare of word 6 with "0" never held on a real node.
DISARM='vcmailbox 0x00038064 4 4 0 >/dev/null 2>&1; set -- $(vcmailbox 0x00030064 4 4 0 2>/dev/null); if [ "${2:-}" = 0x80000000 ] && [ "${5:-}" = 0x80000004 ] && [ -n "${6:-}" ]; then echo "tryboot_flag=$(( ${6} ))"; else echo tryboot_flag=unknown; fi'
# word 5 = 0x80000004: the firmware answered the tag (a firmware without it leaves the request's 0x00000004 and the
# value 0, which would read as "disarmed"; round 8 B-1 — bf_get has the same gap: checklist on #254)
# DISARMED: a reboot_guarded condition: disarm, then the flag must read 0 (an armed tryboot makes `batman-slot reboot
# committed` a plain reboot INTO the tryboot slot, batman-slot cmd_reboot; round 6 A-MAJOR-1). Else nothing is sent.
DISARMED="[ \"\$($DISARM)\" = tryboot_flag=0 ]"
_sg_cmd(){
	local b=$1 a=$2 t=$3 why=$4 x=$5 act=$6 pre=${7:-}
	[ "$x" = - ] && x=true
	case "$b" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) b=invalid-boot ;; esac
	case "$a" in A|B) ;; *) a=invalid-slot ;; esac
	case "$t" in 0|1|any) ;; *) t=invalid-trial ;; esac
	case "$why" in *[!A-Za-z0-9._-]*|'') why=invalid-reason ;; esac
	# a rollback or reboot sent while a tryboot is armed boots the tryboot slot (batman-slot cmd_reboot falls back to a
	# plain reboot): every one disarms first, and nothing is sent unless the flag then reads 0 (round 7 A-MINOR-4)
	case "$act" in rollback|reboot|apply) x="{ $x; } && $DISARMED" ;; esac
	local rb="(batman-slot reboot committed $why </dev/null >/dev/null 2>&1 &); echo SENT"
	[ "$act" = rollback ] && rb="if batman-slot rollback >/dev/null 2>&1; then $rb; else echo REFUSED; fi"
	[ "$act" = release ] && rb="batman-autocommit release --wait 2>&1"
	[ "$act" = release-nowait ] && rb="batman-autocommit release 2>&1; echo rc=\$?"
	[ "$act" = commit ] && rb="o=\$(batman-slot commit 2>&1); echo \"SENT \$o\""
	# prepare / apply: the provclient line itself (its SIGN round trip stays in the same ssh session)
	case "$act" in prepare|apply) [ -n "$pre" ] || pre="echo 'NO-COMMAND'"; rb=$pre ;; esac
	# <pre>: after every check (and DISARMED), before the reboot; its rc decides SENT / PRE-FAILED SENT, the reboot is sent
	# either way (group 4 §4.1)
	[ "$act" = reboot ] && [ -n "$pre" ] && rb="p=\$( { $pre; } </dev/null 2>&1 ); pr=\$?; [ -n \"\$p\" ] && printf '%s\n' \"\$p\" | logger -t slot-guard; logger -t slot-guard \"pre-action rc=\$pr\"; (batman-slot reboot committed $why </dev/null >/dev/null 2>&1 &); if [ \$pr = 0 ]; then echo SENT; else echo 'PRE-FAILED SENT'; fi"
	printf '%s' "b=\$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null); a=\$(batman-slot active 2>/dev/null); batman-slot is-trial >/dev/null 2>&1; t=\$?; if [ -n \"\$b\" ] && [ \"\$b\" = '$b' ] && [ \"\$a\" = '$a' ] && { [ '$t' = any ] || [ \"\$t\" = '$t' ]; }; then if { $x; }; then $rb; else echo \"WRONG-STATE boot=\$b active=\$a trial=\$t extra=0\"; fi; else echo \"WRONG-STATE boot=\$b active=\$a trial=\$t extra=-\"; fi"
}
rb_guarded(){ _sg_cmd "$1" "$2" "$3" "$4" "${5:-true}" rollback; }
reboot_guarded(){ _sg_cmd "$1" "$2" "$3" "$4" "${5:-true}" reboot "${6:-}"; }
commit_guarded(){ _sg_cmd "$1" "$2" 0 commit true commit; }
prepare_guarded(){ _sg_cmd "$1" A 1 update-prepare true prepare "$2"; }
apply_guarded(){ _sg_cmd "$1" A 1 update-apply true apply "$2"; }
release_guarded(){ local m=release; [ "${3:-wait}" = nowait ] && m=release-nowait; _sg_cmd "$1" "$2" 0 release "${4:-true}" "$m"; }
