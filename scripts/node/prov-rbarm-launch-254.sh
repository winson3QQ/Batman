#!/bin/sh
# scripts/node/prov-rbarm-launch-254.sh <wbox version> <run dir> — starts the rollback arm detached (254-h23 §22.1,
# §23.1): HUP / PIPE ignored and a new session, stdin from /dev/null, output to <run dir>/rbarm.out. Prints the
# session shell's pid (LAUNCH pid=…) so the harness can show that shell is gone after it kills the ssh client.
# The negative control (§23.1) starts a harmless arm WITHOUT this launcher's protection: `neg` as $1 runs
# <run dir>/harm.sh with a plain `&` (no trap, no setsid). Killing the ssh client alone does not kill such a child when
# its output goes to a file (offline pty test, 2026-10-29), so the harness also sends SIGHUP to the session's process
# group (the worst case of the hangup reaching it): the plain child dies, the setsid + HUP-ignoring arm does not.
# pgid = field 5 of our stat (comm is "sh": no spaces): the harness sends the worst-case hangup to this group
me=$$; echo "LAUNCH pid=$me pgid=$(cut -d' ' -f5 "/proc/$me/stat")"
if [ "$1" = neg ]; then
	sh "$2/harm.sh" > "$2/harm.out" 2>&1 < /dev/null &
else
	trap '' HUP PIPE
	setsid sh "$2/rbarm.sh" "$1" "$2" > "$2/rbarm.out" 2>&1 < /dev/null &
fi
