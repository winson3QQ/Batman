#!/bin/bash
# tests/prov-p1/s5-lock-lint.sh <feed/batman-provision/files> — #254 P3 S5 (254-p3-impl §3.7.3, review r1 B-M3 / B-M4,
# harness review r2 A MAJOR-1 / A m6 / B m6): the slot flock's source lints and the sysupgrade ramfs check, offline.
#  (a) every `exec N<` / `N>` / `N>>` / `N<>` whose target names the slot lock — the text `batman-slot` in it (a literal,
#      a built path "$RUNDIR/batman-slot.$EXT", a glob), or a variable that is (transitively, in any scanned file)
#      assigned from something that does — in any shell file under feed/*/files and deploy/provisioning is either
#      batman-slot's ONE writer open (`exec 9>>"$LOCKF"` inside slot_lock()), or sits inside a `( … )` / `$( … )` that
#      opens AND closes on that line — that exec itself, so `( exec 8<… ); exec 7<…` FAILs on the second. A brace group,
#      a plain exec, a multi-line subshell, or the exec inside a quoted string (eval / sh -c) FAILs (fail-closed): a
#      reader left on the caller's shell holds the shared lock, every later `batman-slot commit` rc 14 (B15-MAJOR-1);
#  (b) in batman-slot, every command unit that detaches carries `9>&-` itself (a child that inherits fd 9 keeps the lock
#      after the verb returns). The scan drops comments and quoted text first, joins `\` / `&&` / `||` / `|` line
#      continuations, skips heredoc bodies (<<WORD, <<'WORD', <<"WORD", <<-WORD; quote state never crosses one), and
#      splits each line at `;` `&` `&&` `||` `|` `(` `)` `{` `}` and backticks:
#        - a background `&`: the command before it needs its own `9>&-` (`true 9>&-; sleep 100 &` FAILs), and so does
#          every command of a background and-or list / pipeline; a group `( … ) &` / `{ …; } &` needs it after the
#          group; `9>&-` in a comment or inside quotes does not count;
#        - setsid / nohup / start-stop-daemon / `/etc/init.d/<x> start` outside quotes;
#        - quoted text that detaches (a `&`, setsid, nohup, start-stop-daemon, init.d start) when it runs as code:
#          `sh -c` / any `-c`, eval, trap, xargs, a shell reading it, an assignment (code kept for later), or a
#          `"$( … )"` / backticks inside double quotes; a heredoc body that detaches marks its command line the same way.
#          Quoted text that only says `&` (a message) is not code;
#      a `$(( … ))` not closed on its line, a heredoc delimiter not understood, a heredoc or a quote never closed FAIL
#      (the scan would be blind after it). One exception: cmd_reboot, and only while it never calls slot_lock / opens
#      fd 9 and is dispatched by the `reboot` branch before the verb `case` (so fd 9 is never open);
#  (b-lib) the same scan, with no exception, over every shell file batman-slot sources (`. /usr/lib/batman/x.sh`,
#      resolved in the feed tree, recursively): their functions run while the lock is held. A sourced path that does not
#      resolve FAILs. Out of scope (separate processes, residual risk recorded in #254): external programs batman-slot
#      runs in the foreground while it holds the lock (batman-config-save, /etc/init.d/batpower …);
#  (c) RAMFS_COPY_BIN (usr/lib/batman/platform-ab.sh) lists /usr/bin/flock: sysupgrade stage 2 runs batman-slot in the
#      ramfs, busybox has no SH_STANDALONE, so without it every ssh sysupgrade dies rc 18 (the #89 class: ramfs without tr);
#  (d) built-in negative control: on a copy of the tree, each mutant below (the review r2 bypasses among them) must FAIL
#      with the right section, the must-pass ones and the unmodified product must PASS. A product without the flock
#      slot_lock (main before S5) FAILs "predates S5". Nothing scanned / nothing found = FAIL.
set -u
SELF=$(readlink -f "$0")
F=$(readlink -f "${1:?usage: $0 <feed/batman-provision/files>}")
R=$(cd "$F/../../.." && pwd)
SLOT=$F/usr/sbin/batman-slot; PAB=$F/usr/lib/batman/platform-ab.sh
[ -s "$SLOT" ] || { echo "FAIL no $SLOT"; echo "S5-LOCK-LINT checks=0 fail=1"; exit 1; }
awk '/^slot_lock\(\) \{/,/^\}/' "$SLOT" | grep -q 'flock -n 9' || {
	echo "FAIL $SLOT predates S5 (no flock slot_lock): expected red until feat/254-p3 S5 lands (#254)"
	echo "S5-LOCK-LINT checks=0 fail=1"; exit 1; }
n=0; fail=0
ok(){ n=$((n + 1)); echo "ok   $*"; }; bad(){ n=$((n + 1)); fail=$((fail + 1)); echo "FAIL $*"; }
trim(){ sed 's/^[[:space:]]*//' | cut -c1-"${1:-100}"; }

# (b) scanner: one record per detaching command unit, "LN<TAB>OK|BAD<TAB>why<TAB>line"; "LN<TAB>ERR<TAB>why<TAB>" when
# the scan cannot go on (it stops there: the caller FAILs)
IFS= read -r -d '' DET_AWK <<'AWK' || :
# (b) detach scanner: one record per detaching command unit, "LN<TAB>OK|BAD<TAB>why<TAB>text", and "LN<TAB>ERR<TAB>why<TAB>"
function strip_ar(t,   o, i, d, c) {   # drop $(( … )) (paren depth counted), so `a & 1` / `1<<2` there are not read as shell
	o = ""; i = 1
	while (i <= length(t)) {
		if (substr(t, i, 3) == "$((") {
			d = 2; i += 3
			while (i <= length(t) && d > 0) { c = substr(t, i, 1); if (c == "(") d++; else if (c == ")") d--; i++ }
			o = o " 0 "; continue
		}
		o = o substr(t, i, 1); i++
	}
	return o
}
function detw(t,   x) {   # does this text (a quoted body, a heredoc line) detach?
	x = strip_ar(t)
	gsub(/&&/, " ", x); gsub(/[0-9]*[<>]&[0-9-]*/, " ", x); gsub(/&>>?/, " ", x)
	return (x ~ /&/ || x ~ /(^|[^A-Za-z0-9_.-])(setsid|nohup|start-stop-daemon)([^A-Za-z0-9_.-]|$)/ || x ~ /\/etc\/init\.d\/[^ \t;&|]+[ \t]+start/)
}
function emit(ln, st, why, text) { printf "%s\t%s\t%s\t%s\n", ln, st, why, text }
function finish(   u, k, nU, c, j, s, i, ok, why, w) {
	u = cur
	if (hdet) gsub(/@H@/, "@QD@", u)
	# redirections with & are not operators: 2>&1, >&2, <&0, &>file
	gsub(/>&/, ">@A@", u); gsub(/<&/, "<@A@", u); gsub(/&>/, "@A@>", u)
	# split into command units U[k] and the separator S[k] after each
	nU = 1; U[1] = ""; S[1] = ""; i = 1
	while (i <= length(u)) {
		c = substr(u, i, 1); s = ""
		if (c == "$" && substr(u, i + 1, 1) == "{") { j = index(substr(u, i), "}"); if (!j) j = length(u) - i + 1; U[nU] = U[nU] substr(u, i, j); i += j; continue }
		if (substr(u, i, 2) == "&&" || substr(u, i, 2) == "||" || substr(u, i, 2) == ";;") s = substr(u, i, 2)
		else if (c == "&" || c == "|" || c == ";" || c == "(" || c == ")" || c == "{" || c == "}" || c == "`" || c == "\n") s = c
		if (s == "") { U[nU] = U[nU] c; i++; continue }
		S[nU] = s; nU++; U[nU] = ""; S[nU] = ""; i += length(s)
	}
	for (k = 1; k <= nU; k++) {
		if (S[k] == "&") {
			ok = 1; why = "background &"
			if (U[k] !~ /@C9@/) { ok = 0; why = (k > 1 && (S[k - 1] == ")" || S[k - 1] == "}")) ? "background group, no 9>&- on the group" : "background & without 9>&- on that command" }
			else if (!(k > 1 && (S[k - 1] == ")" || S[k - 1] == "}")))
				for (j = k - 1; j >= 1 && (S[j] == "&&" || S[j] == "||" || S[j] == "|"); j--)
					if (U[j] !~ /@C9@/) { ok = 0; why = "background and-or list / pipeline: an earlier command lacks 9>&-"; break }
			emit(ln0, ok ? "OK" : "BAD", why, raw)
		} else {
			w = U[k]
			qd = (w ~ /@QD@/ || (w ~ /@QX@/ && (w ~ /(^|[^A-Za-z0-9_])(eval|trap|xargs|sh|ash|bash|dash|source)([^A-Za-z0-9_]|$)/ || w ~ /[ \t]-c([ \t]|$)/ || w ~ /[A-Za-z_][A-Za-z0-9_]*= *@QX@/)))
			if (qd || w ~ /(^|[^A-Za-z0-9_.-])(setsid|nohup|start-stop-daemon)([^A-Za-z0-9_.-]|$)/ || w ~ /[/]etc[/]init[.]d[/][^ \t;&|]+[ \t]+start/) {
				why = qd ? "quoted / heredoc text that detaches, run as code (sh -c, eval, trap, $( ), an assignment)" : "setsid / nohup / start-stop-daemon / init.d start"
				emit(ln0, (w ~ /@C9@/) ? "OK" : "BAD", why, raw)
			}
		}
	}
	cur = ""; raw = ""; open = 0; hdet = 0; nh = 0; hi = 1; hb = 0
}
BEGIN { q = ""; cur = ""; raw = ""; open = 0; nh = 0; hi = 1; hb = 0; hdet = 0; dead = 0 }
dead { next }
hb {   # inside heredoc bodies: no quote state at all; a line that detaches marks the command line
	line = $0; if (hdash[hi]) sub(/^\t+/, "", line)
	if (line == hdel[hi]) { hi++; if (hi > nh) finish(); next }
	if (detw($0)) hdet = 1
	next
}
{
	L = $0; i = 1; n = length(L); cont = 0
	if (!open) { ln0 = NR; open = 1 }
	raw = raw (raw == "" ? "" : " ") L
	while (i <= n) {
		c = substr(L, i, 1)
		if (q == "s") { if (c == "\047") { q = ""; cur = cur (detw(body) ? " @QX@ " : " @Q@ ") } else body = body c; i++; continue }
		if (q == "d") {
			if (c == "\\") { body = body substr(L, i, 2); i += 2; continue }
			if (c == "\"") { q = ""; cur = cur (!detw(body) ? " @Q@ " : body ~ /[$][(]|`/ ? " @QD@ " : " @QX@ ") } else body = body c
			i++; continue
		}
		if (c == "\\") { if (i == n) { cont = 1; i++; continue } cur = cur " "; i += 2; continue }
		if (c == "\047") { q = "s"; body = ""; qln = NR; i++; continue }
		if (c == "\"") { q = "d"; body = ""; qln = NR; i++; continue }
		if (c == "#" && (i == 1 || substr(L, i - 1, 1) ~ /[ \t;&|()]/)) break
		if (substr(L, i, 3) == "$((") {
			d = 2; j = i + 3
			while (j <= n && d > 0) { cc = substr(L, j, 1); if (cc == "(") d++; else if (cc == ")") d--; j++ }
			if (d > 0) { emit(NR, "ERR", "$(( … )) not closed on its line — not supported here", ""); dead = 1; next }
			cur = cur " 0 "; i = j; continue
		}
		if (substr(L, i, 2) == "<<") {
			if (substr(L, i, 3) == "<<<") { cur = cur " <<< "; i += 3; continue }
			k = i + 2; dash = 0
			if (substr(L, k, 1) == "-") { dash = 1; k++ }
			while (substr(L, k, 1) ~ /[ \t]/) k++
			qc = substr(L, k, 1); if (qc == "\047" || qc == "\"") k++; else qc = ""
			w = ""; while (k <= n && substr(L, k, 1) ~ /[A-Za-z0-9_]/) { w = w substr(L, k, 1); k++ }
			if (qc != "") { if (substr(L, k, 1) != qc) w = ""; else k++ }
			if (w == "") { emit(NR, "ERR", "heredoc delimiter not understood (want <<WORD, <<'WORD', <<\"WORD\", <<-WORD)", ""); dead = 1; next }
			nh++; hdel[nh] = w; hdash[nh] = dash; hln = NR; cur = cur " @H@ "; i = k; continue
		}
		if (substr(L, i, 4) == "9>&-" && (i == 1 || substr(L, i - 1, 1) !~ /[0-9]/)) { cur = cur " @C9@ "; i += 4; continue }
		cur = cur c; i++
	}
	if (q != "") { body = body "\n"; next }   # a quoted string spans lines: the logical line goes on
	if (cont) next
	if (cur ~ /(&&|[|][|]?)[ \t]*$/) { cur = cur " "; next }   # `a &&` / `a ||` / `a |` ends the line: the list goes on
	if (nh > 0) { hb = 1; next }
	finish()
}
END {
	if (dead) exit
	if (q != "") emit(qln, "ERR", "quote opened here never closes (EOF) — the scan would be blind after it", "")
	else if (hb) emit(hln, "ERR", "heredoc <<" hdel[hi] " never ends (EOF)", "")
	else if (open) finish()
}
AWK
# (a) scanner: for each `exec N<`/`N>`/`N>>`/`N<>` whose target names the lock (-v vars="A|B": the lock variables), one
# record "LN<TAB>SUB|BARE|QUOTED<TAB>target<TAB>line"; SUB = inside a ( … ) / $( … ) that opens AND closes on this line
IFS= read -r -d '' OPN_AWK <<'AWK' || :
# (a) who opens the slot lock: for each `exec N<`/`N>`/`N>>`/`N<>` whose target names the lock (batman-slot in it, or a
# lock variable from -v vars="A|B"), one record "LN<TAB>SUB|BARE|QUOTED<TAB>target<TAB>line". SUB = this exec sits inside
# a ( … ) / $( … ) that opens AND closes on this line; BARE = it does not (brace group, plain exec, multi-line subshell)
function lockish(t) { return (t ~ /batman-slot/ || (vars != "" && t ~ ("[$][{]?(" vars ")([^A-Za-z0-9_]|$)"))) }
function quoted_exec(b) { return (b ~ /(^|[^A-Za-z0-9_])exec[ \t]+[0-9]+[<>]/ && lockish(b)) }
{
	L = $0; n = length(L); i = 1; q = ""; d = 0; ne = 0; body = ""
	while (i <= n) {
		c = substr(L, i, 1)
		if (q == "s") { if (c == "\047") { q = ""; if (quoted_exec(body)) printf "%d\tQUOTED\t%s\t%s\n", NR, body, L } else body = body c; i++; continue }
		if (q == "d") {
			if (c == "\\") { body = body substr(L, i, 2); i += 2; continue }
			if (c == "\"") { q = ""; if (quoted_exec(body)) printf "%d\tQUOTED\t%s\t%s\n", NR, body, L } else body = body c
			i++; continue
		}
		if (c == "\\") { i += 2; continue }
		if (c == "\047") { q = "s"; body = ""; i++; continue }
		if (c == "\"") { q = "d"; body = ""; i++; continue }
		if (c == "#" && (i == 1 || substr(L, i - 1, 1) ~ /[ \t;&|()]/)) break
		if (c == "(") { d++; i++; continue }
		if (c == ")") { d--; for (e = 1; e <= ne; e++) if (!cl[e] && d < ed[e]) cl[e] = 1; i++; continue }
		if (substr(L, i, 4) == "exec" && (i == 1 || substr(L, i - 1, 1) ~ /[ \t;&|({]/) && substr(L, i + 4, 1) ~ /[ \t]/) {
			k = i + 4
			# every N<… / N>… redirection after this exec (exec 7<a 8<b), each with its target word (quotes kept)
			while (1) {
				while (substr(L, k, 1) ~ /[ \t]/) k++
				if (!match(substr(L, k), /^[0-9]+(<>|>>|<|>)/)) break
				k += RLENGTH; while (substr(L, k, 1) ~ /[ \t]/) k++
				t = ""; tq = ""
				while (k <= n) {
					cc = substr(L, k, 1)
					if (tq != "") { if (cc == tq) tq = ""; t = t cc; k++; continue }
					if (cc == "\047" || cc == "\"") { tq = cc; t = t cc; k++; continue }
					if (cc ~ /[ \t;&|)]/) break
					t = t cc; k++
				}
				if (lockish(t)) { ne++; ed[ne] = d; cl[ne] = 0; et[ne] = t }
			}
			i = k; continue
		}
		i++
	}
	for (e = 1; e <= ne; e++) printf "%d\t%s\t%s\t%s\n", NR, (ed[e] > 0 && cl[e]) ? "SUB" : "BARE", et[e], L
	split("", ed); split("", cl); split("", et)
}
AWK

# ---- (a) who opens the lock file ------------------------------------------------------------------------------------
shf=()
while IFS= read -r f; do
	case "$f" in *.sh) ;; *) head -1 "$f" 2>/dev/null | grep -Eq '^#!.*(/sh|/ash|/bash|rc\.common)' || continue ;; esac
	shf+=("$f")
done < <(find "$R"/feed/*/files "$R/deploy/provisioning" -type f 2>/dev/null | sort)
# the variables that hold (part of) the lock path, over every scanned file and transitively (L=…batman-slot.…, M=$L …):
# fail-closed, a name is a lock variable everywhere once any file assigns it so
vars=$(for f in "${shf[@]}"; do grep -v '^[[:space:]]*#' "$f" | grep -Eo "(^|[^A-Za-z0-9_\$])[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'[^']*'|[^[:space:];&|\"'])+"; done \
	| sed -E 's/^[^A-Za-z_]+//' | sort -u | awk '{ i = index($0, "="); nm = substr($0, 1, i - 1); r = substr($0, i + 1)
		if (r ~ /batman-slot([.*]|["\047}]*$)/) lk[nm] = 1
		# the names this value expands: an edge name -> nm for the closure below
		while (match(r, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) { v = substr(r, RSTART, RLENGTH); sub(/^[$][{]?/, "", v); e[++ne] = v SUBSEP nm; r = substr(r, RSTART + RLENGTH) } }
	END { do { ch = 0; for (k = 1; k <= ne; k++) { split(e[k], p, SUBSEP); if ((p[1] in lk) && !(p[2] in lk)) { lk[p[2]] = 1; ch = 1 } } } while (ch)
		for (v in lk) print v }' | sort -u | paste -sd'|')
slot_range=$(awk '/^slot_lock\(\) \{/{s=NR} s && /^\}/{print s, NR; exit}' "$SLOT")
writers=0; readers=0
for f in "${shf[@]}"; do
	rel=${f#"$R"/}
	while IFS=$'\t' read -r ln kind tgt line; do
		[ -n "$ln" ] || continue
		s=$(echo "$line" | trim 100)
		if [ "$kind" = BARE ] && [ "$f" = "$SLOT" ] && [ -n "$slot_range" ] && [ "$ln" -gt "${slot_range% *}" ] && [ "$ln" -lt "${slot_range#* }" ] \
			&& echo "$line" | grep -Eq '^[[:space:]]*exec 9>>"?[$][{]?LOCKF[}]?"?[[:space:]]*$'; then
			writers=$((writers + 1)); ok "(a) $rel:$ln the writer open, inside slot_lock(): $s"
		elif [ "$kind" = SUB ]; then readers=$((readers + 1)); ok "(a) $rel:$ln a reader open inside a one-line ( … ) (target $tgt): $s"
		elif [ "$kind" = QUOTED ]; then bad "(a) $rel:$ln opens the slot lock inside a quoted string (eval / sh -c: not checkable — write it as code in a one-line ( … )): $s"
		else bad "(a) $rel:$ln opens the slot lock (target $tgt) outside slot_lock() and not inside a ( … ) that closes on the line — that exec itself: $s"; fi
	done < <(awk -v vars="$vars" "$OPN_AWK" "$f")
done
[ "${#shf[@]}" -ge 10 ] && ok "(a) scanned ${#shf[@]} shell files; $(echo "$vars" | grep -o "[^|]*" | grep -c .) lock variable name(s) (fail-closed: any value naming batman-slot, transitively)" || bad "(a) only ${#shf[@]} shell files scanned under $R/feed/*/files + deploy/provisioning"
echo "|$vars|" | grep -q '|LOCKF|' && ok "(a) LOCKF is recognised as a lock variable" || bad "(a) LOCKF (batman-slot's lock path) not recognised as a lock variable: [$vars] — the scan is broken"
[ "$writers" = 1 ] && ok "(a) exactly one writer open" || bad "(a) writer opens in slot_lock(): $writers, want 1"
[ "$readers" -ge 1 ] && ok "(a) $readers reader open(s) found and checked" || bad "(a) no reader open found (rundir.sh slot_busy?) — nothing checked"

# ---- (b) detaching command units in batman-slot ----------------------------------------------------------------------
rb=$(awk '/^cmd_reboot\(\) \{/{s=NR} s && /^\}/{print s, NR; exit}' "$SLOT")
[ -n "$rb" ] || bad "(b) cmd_reboot() not found in batman-slot"
rb_s=${rb% *}; rb_e=${rb#* }
nd=0
while IFS=$'\t' read -r ln kind why line; do
	[ -n "$ln" ] || continue
	s=$(echo "$line" | trim)
	case "$kind" in
		ERR) bad "(b) :$ln $why — batman-slot not scanned past it" ;;
		OK) nd=$((nd + 1)); ok "(b) :$ln detaches ($why) with fd 9 closed: $s" ;;
		*) nd=$((nd + 1))
			if [ -n "$rb" ] && [ "$ln" -gt "$rb_s" ] && [ "$ln" -lt "$rb_e" ]; then ok "(b) :$ln in cmd_reboot (fd 9 never open there, checked below): $s"
			else bad "(b) :$ln $why (the child would keep the slot lock): $s"; fi ;;
	esac
done < <(awk "$DET_AWK" "$SLOT")
[ "$nd" -ge 2 ] && ok "(b) $nd detaching units found and checked" || bad "(b) only $nd detaching units found (want the openmanetd start + the reboot safety net) — the scan is broken"
# the cmd_reboot exception holds only while fd 9 is never open there
if [ -n "$rb" ]; then
	body=$(sed -n "${rb_s},${rb_e}p" "$SLOT" | grep -v '^[[:space:]]*#')
	if echo "$body" | grep -Eq '(^|[^A-Za-z0-9_])slot_lock([^A-Za-z0-9_]|$)|exec[[:space:]]+9'; then
		bad "(b) cmd_reboot calls slot_lock / opens fd 9 — its background child would then keep the lock"
	else ok "(b) cmd_reboot never calls slot_lock nor opens fd 9"; fi
	calls=$(grep -nE '(^|[^A-Za-z0-9_])cmd_reboot([^A-Za-z0-9_(]|$)' "$SLOT" | grep -v '^[0-9]*:[[:space:]]*#' | cut -d: -f1)
	vcase=$(grep -n '^case "[$][{]1:-[}]" in' "$SLOT" | head -1 | cut -d: -f1)
	# top-level code (outside any function body) before the reboot branch must not take the lock
	toplock=$(sed -n "1,${calls:-0}p" "$SLOT" | awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/{f=1} f && /^\}/{f=0; next} !f' | grep -v '^[[:space:]]*#' | grep -Ec '(^|[^A-Za-z0-9_])(slot_lock|exec[[:space:]]+9)')
	if [ "$(echo "$calls" | grep -c .)" != 1 ]; then bad "(b) cmd_reboot called from $(echo "$calls" | grep -c .) places (want only the reboot branch): lines $(echo $calls)"
	elif [ -z "$vcase" ] || [ "$calls" -le "$rb_e" ] || [ "$calls" -ge "$vcase" ]; then bad "(b) cmd_reboot's call (line $calls) is not between its definition (end $rb_e) and the verb case (line ${vcase:-none})"
	elif ! sed -n "$((calls > 3 ? calls - 3 : 1)),${calls}p" "$SLOT" | grep -q 'if \[ "[$][{]1:-[}]" = reboot \]'; then bad "(b) cmd_reboot's call (line $calls) is not under the 'if [ \"\${1:-}\" = reboot ]' branch"
	elif [ "$toplock" != 0 ]; then bad "(b) top-level code before the reboot branch (line $calls) takes the lock: fd 9 would be open in cmd_reboot"
	else ok "(b) cmd_reboot dispatched by the reboot branch (line $calls) before the verb case (line $vcase), no lock taken before it"; fi
fi

# ---- (b-lib) the shell files batman-slot sources, recursively: their functions run with the lock held ---------------
srcs(){ grep -v '^[[:space:]]*#' "$1" | grep -Eo '(^|[;&|({[:space:]])(\.|source)[[:space:]]+[^[:space:];&|)]+' | sed -E 's/^[;&|({[:space:]]*(\.|source)[[:space:]]+//' | tr -d "\"'"; }
todo=$(srcs "$SLOT"); seen=" "; nlib=0
while [ -n "$todo" ]; do
	p=$(echo "$todo" | head -1); todo=$(echo "$todo" | sed 1d)
	case "$seen" in *" $p "*) continue ;; esac
	seen="$seen$p "
	case "$p" in
		*'$'* | *'*'* | *'`'*) bad "(b-lib) batman-slot sources '$p': not a literal path — cannot resolve it in the feed tree"; continue ;;
		/*) ;;
		*) bad "(b-lib) batman-slot sources '$p': not an absolute path — cannot resolve it in the feed tree"; continue ;;
	esac
	lf=$F$p; [ -f "$lf" ] || lf=$(ls -d "$R"/feed/*/files"$p" 2>/dev/null | head -1)
	[ -n "$lf" ] && [ -f "$lf" ] || { bad "(b-lib) sourced $p is not in the feed tree ($R/feed/*/files) — not scanned"; continue; }
	nlib=$((nlib + 1)); lrel=${lf#"$R"/}; lu=0
	while IFS=$'\t' read -r ln kind why line; do
		[ -n "$ln" ] || continue
		case "$kind" in
			ERR) bad "(b-lib) $lrel:$ln $why — not scanned past it" ;;
			OK) lu=$((lu + 1)); ok "(b-lib) $lrel:$ln detaches ($why) with fd 9 closed: $(echo "$line" | trim)" ;;
			*) lu=$((lu + 1)); bad "(b-lib) $lrel:$ln $why (sourced by batman-slot: the child would keep the slot lock): $(echo "$line" | trim)" ;;
		esac
	done < <(awk "$DET_AWK" "$lf")
	ok "(b-lib) scanned $lrel (sourced as $p): $lu detaching unit(s)"
	todo=$(printf '%s\n%s\n' "$todo" "$(srcs "$lf")" | grep .)
done
[ "$nlib" -ge 1 ] && ok "(b-lib) $nlib sourced shell file(s) scanned" || bad "(b-lib) batman-slot sources no shell file found in the feed tree — nothing scanned (otatrace.sh / rundir.sh expected)"

# ---- (c) flock in the sysupgrade ramfs ----------------------------------------------------------------------------------
if [ -s "$PAB" ]; then
	rcb=$(grep -E '^[[:space:]]*(export[[:space:]]+)?RAMFS_COPY_BIN=' "$PAB" | sed -E "s/^[^=]*=//; s/[[:space:]]+#.*$//; s/^['\"]//; s/['\"]$//")
	if [ -z "$rcb" ]; then bad "(c) no RAMFS_COPY_BIN= in $PAB"
	elif echo " $rcb " | tr '\n' ' ' | grep -q ' /usr/bin/flock '; then ok "(c) RAMFS_COPY_BIN lists /usr/bin/flock"
	else bad "(c) RAMFS_COPY_BIN does not list /usr/bin/flock — slot_lock dies rc 18 in the sysupgrade ramfs: [$rcb]"; fi
else
	bad "(c) no $PAB"
fi

# ---- (d) built-in negative control: the lint against mutants of a copy of this tree -----------------------------------
# mut <FAIL|PASS> <name> <file under F> <kind> <arg> <text> [<FAIL line pattern>]
#   kind after:<ERE>  insert <text> after the first line matching <arg> at or after the first line matching <ERE>
#   kind append       append <text> to the file;  kind sed  run `sed -E <arg>` on the file (must change it); kind none
# a FAIL mutant passes the control only when the lint exits non-zero with a FAIL line matching the pattern (its section)
if [ -z "${S5LL_INNER:-}" ]; then
	T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
	frel=${F#"$R"/}
	mut(){ local want=$1 name=$2 file=$3 kind=$4 arg=$5 text=$6 pat=${7:-^FAIL} d=$T/r o rc
		rm -rf "$d"; mkdir -p "$d/feed" "$d/deploy"
		for p in "$R"/feed/*/files; do p=${p%/files}; mkdir -p "$d/feed/${p##*/}"; cp -a "$p/files" "$d/feed/${p##*/}/"; done
		cp -a "$R/deploy/provisioning" "$d/deploy/"
		local tf=$d/$frel/$file
		[ -f "$tf" ] || { bad "(d) $name: no $file in the copy — mutant not applied"; return; }
		cp "$tf" "$T/orig"
		case "$kind" in
			after:*) MUT_T=$text MUT_F=${kind#after:} MUT_A=$arg awk '{ print } !f && $0 ~ ENVIRON["MUT_F"] { f = 1 } f == 1 && $0 ~ ENVIRON["MUT_A"] { print ENVIRON["MUT_T"]; f = 2 }' "$T/orig" > "$tf" ;;
			none) ;;
			append) { cat "$T/orig"; printf '%s\n' "$text"; } > "$tf" ;;
			sed) sed -E "$arg" "$T/orig" > "$tf" ;;
		esac
		[ "$kind" = none ] || ! cmp -s "$T/orig" "$tf" || { bad "(d) $name: the mutant did not change $file — not applied"; return; }
		o=$(S5LL_INNER=1 bash "$SELF" "$d/$frel" 2>&1); rc=$?
		if [ "$want" = PASS ]; then
			[ "$rc" = 0 ] && ok "(d) $name: PASSes as it must ($(echo "$o" | tail -1))" || bad "(d) $name: must PASS, got rc=$rc: $(echo "$o" | grep '^FAIL' | head -2 | cut -c1-200 | tr '\n' ' ')"
		elif [ "$rc" != 0 ] && echo "$o" | grep -Eq "$pat"; then ok "(d) $name: FAILs as it must: $(echo "$o" | grep -E "$pat" | head -1 | cut -c1-150)"
		else bad "(d) $name: must FAIL ($pat), got rc=$rc: $(echo "$o" | grep '^FAIL' | head -2 | cut -c1-200 | tr '\n' ' ')"; fi
	}
	S=usr/sbin/batman-slot; RD=usr/lib/batman/rundir.sh; C='after:^cmd_commit\(\) \{'; SL=slot_lock
	TAB=$(printf '\t')
	mut PASS "unmodified tree" "$S" none "" ""
	# (b): a background child of a lock-holding verb (cmd_commit, right after slot_lock); r2 A M1–M13 and more
	mut FAIL "M5 plain background" "$S" "$C" "$SL" "${TAB}sleep 100 >/dev/null 2>&1 &" '^FAIL \(b\)'
	mut FAIL "M1 9>&- only in a comment" "$S" "$C" "$SL" "${TAB}sleep 100 & # TODO: 9>&-" '^FAIL \(b\)'
	mut FAIL "M2 9>&- on another command of the line" "$S" "$C" "$SL" "${TAB}true 9>&-; sleep 100 &" '^FAIL \(b\)'
	mut FAIL "M6 9>&- inside quotes" "$S" "$C" "$SL" "${TAB}echo \"9>&-\" >/dev/null; sleep 100 &" '^FAIL \(b\)'
	mut FAIL "M3 sh -c with a background inside" "$S" "$C" "$SL" "${TAB}sh -c \"sleep 100 >/dev/null 2>&1 &\"" '^FAIL \(b\)'
	mut FAIL "M3' sh -c single-quoted" "$S" "$C" "$SL" "${TAB}sh -c 'sleep 100 &'" '^FAIL \(b\)'
	mut FAIL "M4 \"\$( … & )\"" "$S" "$C" "$SL" "${TAB}x=\"\$(sleep 100 >/dev/null 2>&1 &)\"" '^FAIL \(b\)'
	mut FAIL "M4' bare \$( … & )" "$S" "$C" "$SL" "${TAB}x=\$(sleep 100 >/dev/null 2>&1 &)" '^FAIL \(b\)'
	mut FAIL "backticks with a background" "$S" "$C" "$SL" "${TAB}x=\`sleep 100 &\`" '^FAIL \(b\)'
	mut FAIL "eval of a background" "$S" "$C" "$SL" "${TAB}eval 'sleep 100 &'" '^FAIL \(b\)'
	mut FAIL "code kept in a variable" "$S" "$C" "$SL" "${TAB}J='sleep 100 &'; eval \"\$J\"" '^FAIL \(b\)'
	mut FAIL "trap with a background" "$S" "$C" "$SL" "${TAB}trap 'sleep 100 &' USR1" '^FAIL \(b\)'
	mut FAIL "M11 heredoc with an apostrophe, then a background" "$S" "$C" "$SL" "${TAB}cat >/dev/null <<EOT
it's
EOT
${TAB}sleep 100 &" '^FAIL \(b\)'
	mut FAIL "<<-'EOT' heredoc with a quote, then a background" "$S" "$C" "$SL" "${TAB}cat >/dev/null <<-'EOT'
${TAB}\"it's
${TAB}EOT
${TAB}sleep 100 &" '^FAIL \(b\)'
	mut FAIL "heredoc body fed to sh detaches" "$S" "$C" "$SL" "${TAB}sh <<EOT
sleep 100 &
EOT" '^FAIL \(b\)'
	mut FAIL "heredoc that never ends" "$S" "$C" "$SL" "${TAB}cat >/dev/null <<NEVER" '^FAIL \(b\).*never ends'
	mut FAIL "a quote that never closes" "$S" sed '$a\
echo "it' "" '^FAIL \(b\).*never closes'
	mut FAIL "M12 setsid through a variable" "$S" "$C" "$SL" "${TAB}SS=setsid; \$SS sleep 100 </dev/null >/dev/null 2>&1" '^FAIL \(b\)'
	mut FAIL "setsid name quoted" "$S" "$C" "$SL" "${TAB}SS=\"setsid\"; \$SS sleep 100 </dev/null >/dev/null 2>&1" '^FAIL \(b\)'
	mut FAIL "M13 \\-continuation, a second & without 9>&-" "$S" "$C" "$SL" "${TAB}setsid sleep 100 9>&- \\
${TAB}${TAB}</dev/null & sleep 5 &" '^FAIL \(b\)'
	mut FAIL "nohup (no &)" "$S" "$C" "$SL" "${TAB}nohup sleep 100 >/dev/null 2>&1" '^FAIL \(b\)'
	mut FAIL "start-stop-daemon -b" "$S" "$C" "$SL" "${TAB}start-stop-daemon -S -b -x /bin/sleep -- 100" '^FAIL \(b\)'
	mut FAIL "/etc/init.d/<x> start" "$S" "$C" "$SL" "${TAB}/etc/init.d/batman-foo start" '^FAIL \(b\)'
	mut FAIL "and-or list in the background, first command open" "$S" "$C" "$SL" "${TAB}true && sleep 100 9>&- &" '^FAIL \(b\)'
	mut FAIL "and-or list split over two lines" "$S" "$C" "$SL" "${TAB}true &&
${TAB}${TAB}sleep 100 9>&- &" '^FAIL \(b\)'
	mut FAIL "pipeline in the background" "$S" "$C" "$SL" "${TAB}sleep 100 | cat 9>&- &" '^FAIL \(b\)'
	mut FAIL "subshell in the background, 9>&- only inside" "$S" "$C" "$SL" "${TAB}( sleep 100 9>&- ) &" '^FAIL \(b\)'
	mut FAIL "brace group in the background" "$S" "$C" "$SL" "${TAB}{ sleep 100; } &" '^FAIL \(b\)'
	mut FAIL "the openmanetd start loses its 9>&-" "$S" sed 's/ 9>&- &$/ \&/' "" '^FAIL \(b\)'
	mut FAIL "slot_lock called in cmd_reboot" "$S" 'after:^cmd_reboot\(\) \{' '^cmd_reboot' "${TAB}slot_lock" '^FAIL \(b\) cmd_reboot calls slot_lock'
	# must PASS: the scan is not stricter than the rule
	mut PASS "background with its own 9>&-" "$S" "$C" "$SL" "${TAB}sleep 1 </dev/null >/dev/null 2>&1 9>&- &"
	mut PASS "group with 9>&- on the group" "$S" "$C" "$SL" "${TAB}( sleep 1; true ) 9>&- &"
	mut PASS "heredoc with an apostrophe, then a closed background" "$S" "$C" "$SL" "${TAB}cat >/dev/null <<'EOT'
it's \"odd
EOT
${TAB}sleep 1 9>&- &"
	mut PASS "a message that only says &" "$S" "$C" "$SL" "${TAB}warn \"a & b; setsid is not run here\""
	mut PASS "arithmetic & / <<" "$S" "$C" "$SL" "${TAB}x=\$(( (1 << 2) & 4 ))"
	# (a): who opens the lock (appended to rundir.sh, like its slot_busy reader); r2 A M7–M10 and more
	mut FAIL "M10 brace reader" "$RD" append "" 'slot_peek() { exec 7<"$RUNDIR/batman-slot.flock"; flock -s -n 7; }' '^FAIL \(a\)'
	mut FAIL "M7 alias variable of the lock path" "$RD" append "" 'LOCKF2=$RUNDIR/batman-slot.flock
slot_peek() { L=$LOCKF2; exec 7<"$L"; flock -s -n 7; }' '^FAIL \(a\)'
	mut FAIL "M8 path built from parts" "$RD" append "" 'slot_peek() { exec 7<"$RUNDIR/batman-slot.$EXT"; flock -s -n 7; }' '^FAIL \(a\)'
	mut FAIL "M8' path as a glob" "$RD" append "" 'slot_peek() { exec 7<"$RUNDIR"/batman-slot.*; flock -s -n 7; }' '^FAIL \(a\)'
	mut FAIL "M8'' prefix in a variable, suffix at the exec" "$RD" append "" 'SLKD=$RUNDIR/batman-slot
slot_peek() { exec 7<"$SLKD.flock"; }' '^FAIL \(a\)'
	mut FAIL "M9 bare exec after a ( … ) reader on the line" "$RD" append "" 'slot_peek() { ( exec 8<"$RUNDIR/batman-slot.flock" && flock -s -n 8 ); exec 7<"$RUNDIR/batman-slot.flock"; flock -s -n 7; }' '^FAIL \(a\)'
	mut FAIL "second redirection of one exec" "$RD" append "" 'slot_peek() { exec 6</dev/null 7<"$RUNDIR/batman-slot.flock"; }' '^FAIL \(a\)'
	mut FAIL "exec 7<> read-write" "$RD" append "" 'slot_peek() { exec 7<>"$RUNDIR/batman-slot.flock"; }' '^FAIL \(a\)'
	mut FAIL "multi-line subshell" "$RD" append "" 'slot_peek() { (
	exec 7<"$RUNDIR/batman-slot.flock"; flock -s -n 7
); }' '^FAIL \(a\)'
	mut FAIL "eval of the open" "$RD" append "" 'slot_peek() { eval "exec 7<$RUNDIR/batman-slot.flock"; }' '^FAIL \(a\)'
	mut FAIL "command exec" "$RD" append "" 'slot_peek() { command exec 7<"$RUNDIR/batman-slot.flock"; }' '^FAIL \(a\)'
	mut PASS "one-line ( … ) reader through an alias variable" "$RD" append "" 'LOCKF3=$RUNDIR/batman-slot.flock
slot_peek() { ( exec 7<"$LOCKF3" && flock -s -n 7 ) 2>/dev/null; }'
	# (b-lib): the files batman-slot sources run with the lock held
	mut FAIL "background in otatrace.sh" usr/lib/batman/otatrace.sh append "" 'otalog_bg() { sleep 100 & }' '^FAIL \(b-lib\)'
	mut FAIL "setsid in bootfacts.sh" usr/lib/batman/bootfacts.sh append "" 'bf_bg() { setsid sleep 100 </dev/null >/dev/null 2>&1; }' '^FAIL \(b-lib\)'
	mut FAIL "batman-slot sources a file not in the feed" "$S" 'after:^\[ -f /usr/lib/batman/otatrace\.sh \]' 'otatrace' '[ -r /usr/lib/batman/no-such-lib.sh ] && . /usr/lib/batman/no-such-lib.sh' '^FAIL \(b-lib\).*not in the feed'
	# (c) and the predates gate
	mut FAIL "/usr/bin/flock dropped from RAMFS_COPY_BIN" usr/lib/batman/platform-ab.sh sed 's#/usr/bin/flock ##' "" '^FAIL \(c\)'
	mut FAIL "slot_lock without flock (main before S5)" "$S" sed 's/flock -n 9/flock -n 7/' "" 'predates S5'
fi
echo "S5-LOCK-LINT checks=$n fail=$fail"
[ "$n" -gt 0 ] && [ "$fail" = 0 ]
