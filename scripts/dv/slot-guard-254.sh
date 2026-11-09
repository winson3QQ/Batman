# shellcheck shell=bash
# scripts/dv/slot-guard-254.sh — every harness `batman-slot rollback` goes through rb_guarded (review 2026-11-09 B-MAJOR-1).
# 2026-11-08: a rollback decided on a host-side read of the node (a substring match on "badslot=[slot=B …]") went to a
# node already on A committed; the default became the fresh, keyless B and a person had to edit autoboot.txt on the
# SD card. A state read on the host can be stale or mis-parsed, so the node checks it again in the SAME command as
# the rollback: boot id, active slot, trial state, and an optional extra condition.
#
# rb_guarded <boot8> <active A|B> <trial 0|1|any> <reason> [extra shell condition]
#   prints the node-side command; its output is exactly one of
#     SENT                         rollback done, `batman-slot reboot committed <reason>` started in the background
#     REFUSED                      every check held, `batman-slot rollback` itself refused (bad-slot, lock gate, …)
#     WRONG-STATE boot=… active=… trial=…   a check failed: nothing was sent
#   trial: 0 = an uncommitted trial (`batman-slot is-trial` rc 0), 1 = committed, any = either.
#   An empty <boot8> can never match (the node's boot id is never empty): fail-closed.
# Callers: anything but SENT is a failure (abort / NEEDS-PERSON), never "go on as if it had been sent".
# RB_BOOTID (tests only) replaces /proc/sys/kernel/random/boot_id.
rb_guarded(){
	local b=$1 a=$2 t=$3 why=$4 x=${5:-true}
	case "$a" in A|B) ;; *) a=invalid-slot ;; esac
	case "$t" in 0|1|any) ;; *) t=invalid-trial ;; esac
	case "$why" in *[!A-Za-z0-9._-]*|'') why=invalid-reason ;; esac
	printf '%s' "b=\$(cut -c1-8 \${RB_BOOTID:-/proc/sys/kernel/random/boot_id} 2>/dev/null); a=\$(batman-slot active 2>/dev/null); batman-slot is-trial >/dev/null 2>&1; t=\$?; if [ -n \"\$b\" ] && [ \"\$b\" = '$b' ] && [ \"\$a\" = '$a' ] && { [ '$t' = any ] || [ \"\$t\" = '$t' ]; } && { $x; }; then if batman-slot rollback >/dev/null 2>&1; then (batman-slot reboot committed $why </dev/null >/dev/null 2>&1 &); echo SENT; else echo REFUSED; fi; else echo \"WRONG-STATE boot=\$b active=\$a trial=\$t\"; fi"
}
