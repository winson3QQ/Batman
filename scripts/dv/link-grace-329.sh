# shellcheck shell=bash
# scripts/dv/link-grace-329.sh — #329 N1 (docs/design/329-n1-plan.md §5.2 / §5.3): provd counts a BLE link that has no
# session for 30 s only, then logs "provd: link without session for 30 s" once and cuts it. Sourced by prov-254.sh.
# No node access in here: lg_judge reads log text on stdin, so scripts/test-dv-ble-254.sh runs it offline.
#
# lg_judge <BATMAN_VERSION> <pre-N1 versions file>
#   stdin: 04's provd lines after the arm's log mark, as logread prints them
#          ("Sun Jul 27 22:44:15 2025 daemon.info batman-provd[1234]: provd: adv withdrawn reason=connect").
#   stdout: verdict lines "PASS ..." / "FAIL ..." / "INVALID ...", then one "LG state=<cut|none|invalid>":
#     cut      exactly one stale-link line: the caller goes on to judge 02's side (GONE, read again)
#     none     no such line (a FAIL line was printed; on a listed pre-N1 image it is the one fixed line the
#              known-failures entry matches, and nothing else of the arm is judged)
#     invalid  the log cannot answer (no connection logged, 02's link dropped by itself, the advert came back in between)
#   The times are the log's wall clock, whole seconds; a run that crosses midnight is handled (+86400).
# shellcheck disable=SC2034  # used by prov-254.sh (lg_guard)
LG_LINE='provd: link without session for 30 s$'
lg_judge(){
	local ver=$1 list=$2 pre=0
	grep -v '^#' "$list" 2>/dev/null | grep -qxF "$ver" && pre=1
	awk -v ver="$ver" -v pre="$pre" '
	function sec(t,   f) { split(t, f, ":"); return f[1] * 3600 + f[2] * 60 + f[3] }
	function dt(a, b,   d) { d = sec(b) - sec(a); if (d < 0) d += 86400; return d }
	/batman-provd\[[0-9]+\]: provd: / {
		n++; T[n] = $4; K[n] = "-"
		if ($0 ~ /provd: adv withdrawn reason=connect$/) K[n] = "W"
		else if ($0 ~ /provd: adv registered reason=/) { K[n] = "R"; RZ[n] = $NF; sub(/.*reason=/, "", RZ[n]) }
		else if ($0 ~ /provd: link without session for 30 s$/) { K[n] = "S"; ns++; s = n }
	}
	END {
		for (i = 1; i <= n; i++) if (K[i] == "W") lw = i
		if (ns == 0) {
			if (!lw) { print "INVALID 04 logged no connection after the mark (02 did not reach 04)"; print "LG state=invalid"; exit }
			for (i = lw + 1; i <= n; i++) if (K[i] == "R" && dt(T[lw], T[i]) < 29) {
				print "INVALID the advertisement came back " dt(T[lw], T[i]) " s after the connection (" T[lw] " -> " T[i] " reason=" RZ[i] "): 02\047s link dropped by itself"; print "LG state=invalid"; exit }
			if (pre) print "FAIL no \047link without session\047 line in 70 s (pre-N1 image)"
			else print "FAIL 04 (" ver ") kept a link that has no session for 70 s and logged nothing: provd\047s 30 s rule is not in this image"
			print "LG state=none"; exit
		}
		if (ns > 1) { print "FAIL " ns " \047link without session\047 lines for one held link (want one each time a link goes stale)"; print "LG state=none"; exit }
		t0 = 0; for (i = 1; i < s; i++) if (K[i] == "W") t0 = i
		if (!t0) { print "INVALID a \047link without session\047 line at " T[s] " with no connection logged before it"; print "LG state=invalid"; exit }
		for (i = t0 + 1; i < s; i++) if (K[i] == "R") { print "INVALID the advertisement was registered (" T[i] " reason=" RZ[i] ") between the connection at " T[t0] " and the stale-link line at " T[s]; print "LG state=invalid"; exit }
		d = dt(T[t0], T[s])
		if (d >= 29 && d <= 37) print "PASS 04 logged the link as stale " d " s after it connected (" T[t0] " -> " T[s] "; want 29-37: 30 s + a tick of up to 5 s)"
		else if (d < 29) print "FAIL 04 logged the link as stale only " d " s after it connected (" T[t0] " -> " T[s] "; want 29-37): cut before 30 s"
		else print "FAIL 04 logged the link as stale " d " s after it connected (" T[t0] " -> " T[s] "; want 29-37): later than 30 s + one tick"
		r = 0; for (i = s + 1; i <= n; i++) if (K[i] == "R" && RZ[i] == "disconnect") { r = i; break }
		if (r && dt(T[s], T[r]) <= 20) print "PASS 04 advertises again " dt(T[s], T[r]) " s after the stale-link line (adv registered reason=disconnect at " T[r] "; <= 20)"
		else if (r) print "FAIL 04 advertised again " dt(T[s], T[r]) " s after the stale-link line (want <= 20)"
		else print "FAIL no \047adv registered reason=disconnect\047 after the stale-link line at " T[s] ": 04 did not come back"
		print "LG state=cut"
	}'
}
# lg_last_w: stdin as lg_judge; the time of the last "adv withdrawn reason=connect" line (HH:MM:SS), or nothing
lg_last_w(){ awk '/batman-provd\[[0-9]+\]: provd: adv withdrawn reason=connect$/ { t = $4 } END { if (t != "") print t }'; }
# lg_age <HH:MM:SS connect> <HH:MM:SS now>: seconds between the two (midnight handled)
lg_age(){ awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, ":"); split(b, y, ":"); d = (y[1] * 3600 + y[2] * 60 + y[3]) - (x[1] * 3600 + x[2] * 60 + x[3]); if (d < 0) d += 86400; print d }'; }
