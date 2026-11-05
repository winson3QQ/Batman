#!/bin/sh
# scripts/node/prov-rbarm-launch-254.sh <wbox version> <run dir> — starts the rollback arm detached (254-h23 §22.1,
# §23.1): HUP / PIPE ignored and a new session, stdin from /dev/null, output to <run dir>/rbarm.out. Prints the
# session shell's pid (LAUNCH pid=…) so the harness can show that shell is gone after it kills the ssh client.
# The negative control (§23.1) starts a harmless arm WITHOUT this launcher's protection: `neg` as $1 runs
# <run dir>/harm.sh with a plain `&` (no trap, no setsid). Killing the ssh client alone does not kill such a child when
# its output goes to a file (offline pty test, 2026-10-29), so the harness also sends SIGHUP to the session's process
# group (the worst case of the hangup reaching it): the plain child dies, the setsid + HUP-ignoring arm does not.
# pgid = field 5 of our stat (comm is "sh": no spaces): the harness sends the worst-case hangup to this group
# The line also goes to <run dir>/launch.<neg|arm> (the run dir is root 0700): the harness reads it from there — over
# `ssh -tt` from Git Bash the pty output reached the host's file only when ssh ended, never while the session lived
# (2026-11-04: two re-runs, "printed after 20 s: []" while the arm itself ran and passed)
me=$$; l="LAUNCH pid=$me pgid=$(cut -d' ' -f5 "/proc/$me/stat")"; echo "$l"
t=arm; [ "$1" = neg ] && t=neg; ( umask 077; echo "$l" > "$2/launch.$t.tmp" ) && mv "$2/launch.$t.tmp" "$2/launch.$t"
if [ "$1" = neg ]; then
	sh "$2/harm.sh" > "$2/harm.out" 2>&1 < /dev/null &
else
	trap '' HUP PIPE
	setsid sh "$2/rbarm.sh" "$1" "$2" > "$2/rbarm.out" 2>&1 < /dev/null &
fi
