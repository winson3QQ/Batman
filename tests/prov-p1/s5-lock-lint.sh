#!/bin/bash
# tests/prov-p1/s5-lock-lint.sh <feed/batman-provision/files> — #254 P3 S5 (254-p3-impl §3.7.3, review r1 B-M3 / B-M4,
# harness review r3 A MAJOR-1 / B m4): the slot flock's source lints and the sysupgrade ramfs check, offline. Both lints
# are exact allowlists, not a shell parser: whether a background child keeps fd 9 depends on WHAT runs there (an
# external program: `9>&-` closes it; a shell function, eval or a builtin: the shell saves fd 9 to fd >= 10 for the
# redirection and keeps it — measured in dash and busybox ash, review r3 A leak4.out), which no static scan can tell. So
# every line that could matter is pinned byte for byte and judged by a person in a harness PR (#290); the one case that
# is run while the lock is held is tested by running it (s5-lock-release.sh).
#  A "line" = a logical line: `\`-newline joined (as the shell does), blank runs folded to one space, trimmed; whole-line
#  comments dropped. It is keyed "<file from the repo root> :: <enclosing top-level function, or -> :: <line>"; the
#  found keys must equal the list (as a multiset): a line not listed, or a listed line changed / moved / gone = FAIL.
#  (a) every line in a shell file under feed/*/files and deploy/provisioning with the word `exec` and a `<` / `>`: a
#      persistent open left on a caller's shell can hold the slot lock (B15-MAJOR-1: every later commit rc 14);
#  (b) in batman-slot and every shell file it sources (`. /path`, resolved in the feed tree, recursively — their code
#      runs with fd 9 holding the lock), every line that, after dropping `&&` and `N>&M` / `N<&M` with M one digit 0-8,
#      still has a `&` (a background job, `&>`, a copy of fd 9 `N>&9`, `>&-`, `$(( a & b ))`, a message), or the word
#      setsid / nohup / start-stop-daemon / eval / coproc / service, or `sh -c`, or `/etc/init.d/`. That is 13 lines
#      in feat/254-p3 47610d7, not the ~115 a bare `&` would list. Fail-closed for a background job or a copy of fd 9
#      (both need a `&` that is not one of the dropped forms). Not caught (residual, #254): obfuscation on purpose
#      (`printf '… \046' | sh`), and external programs batman-slot runs in the foreground (batman-config-save …);
#      cmd_reboot's background safety net is listed because cmd_reboot never holds the lock — checked below;
#  (c) RAMFS_COPY_BIN (usr/lib/batman/platform-ab.sh) lists /usr/bin/flock: sysupgrade stage 2 runs batman-slot in the
#      ramfs, busybox has no SH_STANDALONE, so without it every ssh sysupgrade dies rc 18 (the #89 class: ramfs without tr);
#  (d) negative control in the test: each bypass from reviews r2 / r3 (A muts.all + ma.sh, B mut.sh / mut2.sh) inserted
#      into a copy of the one file it targets must show up as an unlisted line. A product without the flock slot_lock
#      (main before S5) FAILs "predates S5". Nothing scanned / nothing found = FAIL.
set -u
F=$(readlink -f "${1:?usage: $0 <feed/batman-provision/files>}")
R=$(cd "$F/../../.." && pwd)
SLOT=$F/usr/sbin/batman-slot; PAB=$F/usr/lib/batman/platform-ab.sh
[ -s "$SLOT" ] || { echo "FAIL no $SLOT"; echo "S5-LOCK-LINT checks=0 fail=1"; exit 1; }
awk '/^slot_lock\(\) \{/,/^\}/' "$SLOT" | grep -q 'flock -n 9' || {
	echo "FAIL $SLOT predates S5 (no flock slot_lock): expected red until feat/254-p3 S5 lands (#254)"
	echo "S5-LOCK-LINT checks=0 fail=1"; exit 1; }
n=0; fail=0
ok(){ n=$((n + 1)); echo "ok   $*"; }; bad(){ n=$((n + 1)); fail=$((fail + 1)); echo "FAIL $*"; }

# ---- the allowlists: "<file> :: <function> :: <line>", the reason on the comment line above each ----------------------
ALLOW_A=$(cat <<'EOF'
# halow-setkey's own lock (not the slot lock), held by the whole script
deploy/provisioning/halow-setkey :: - :: command exec 9>"$RUNDIR/halow-setkey.lock" || { echo "halow-setkey: cannot open the lock — refusing (nothing changed)" >&2; [ "$P3" = 1 ] && exit 5; exit 2; }
feed/batman-provision/files/usr/bin/halow-setkey :: - :: command exec 9>"$RUNDIR/halow-setkey.lock" || { echo "halow-setkey: cannot open the lock — refusing (nothing changed)" >&2; [ "$P3" = 1 ] && exit 5; exit 2; }
# chanfix takes / drops halow-setkey's lock (not the slot lock)
feed/batman-provision/files/etc/uci-defaults/99-batman-chanfix :: - :: if ! type batman_rundir >/dev/null 2>&1 || ! batman_rundir 2>/dev/null || ! command -v flock >/dev/null 2>&1 || ! command exec 9>"$RUNDIR/halow-setkey.lock"; then
feed/batman-provision/files/etc/uci-defaults/99-batman-chanfix :: - :: lock_drop() { command exec 9>&- 2>/dev/null; }
# the slot lock's readers: a SHARED lock inside a subshell that ends on the line, so the caller never keeps it
deploy/provisioning/rundir.sh :: slot_busy :: ( exec 8<"$RUNDIR/batman-slot.flock" && flock -s -n 8 ) 2>/dev/null && return 1
feed/batman-provision/files/usr/lib/batman/rundir.sh :: slot_busy :: ( exec 8<"$RUNDIR/batman-slot.flock" && flock -s -n 8 ) 2>/dev/null && return 1
# payload-run's own lock (not the slot lock); payload-stop probes it in a subshell
feed/batman-provision/files/usr/bin/payload-run :: - :: exec 9>"$LOCK"
feed/batman-provision/files/usr/lib/batman/payload-stop.sh :: pstop_kill :: if ( exec 8>"$lock"; flock -n 8 ) 2>/dev/null; then rm -f "$pidf"; return 0; fi # nobody holds it: stale
# `docker exec` (a container command), not the shell's exec
feed/batman-provision/files/usr/bin/payload-run :: fact :: docker exec "$1" $3 sh -c "$2" >/dev/null 2>&1 &
feed/batman-provision/files/usr/bin/payload-run :: health_gate :: to=""; docker exec "$NAME" sh -c 'command -v timeout' >/dev/null 2>&1 && to="timeout 8" || log "WARN: $NAME has no timeout(1) — a hung health check is bounded by the CLI kill only"
# THE writer open of the slot lock, inside slot_lock()
feed/batman-provision/files/usr/sbin/batman-slot :: slot_lock :: exec 9>>"$LOCKF"
# cmd_write keeps the caller's stdin on fd 3 for the rootfs dd only, and closes it (not the lock)
feed/batman-provision/files/usr/sbin/batman-slot :: cmd_write :: exec 3<&0 0</dev/null # only the rootfs dd reads the caller's stdin
feed/batman-provision/files/usr/sbin/batman-slot :: cmd_write :: exec 3<&-
# cmd_reboot's safety net: `exec` inside the sh -c string replaces that shell (no fd opened); cmd_reboot never holds the lock
feed/batman-provision/files/usr/sbin/batman-slot :: cmd_reboot :: setsid sh -c "sleep 240; exec /usr/sbin/batman-reboot $n" </dev/null >/dev/null 2>&1 &
EOF
)
ALLOW_B=$(cat <<'EOF'
# eval of a fixed variable name (BATMAN_ALLOW_<verb>), foreground, nothing detaches
feed/batman-provision/files/usr/sbin/batman-slot :: allowed :: allowed() { [ "$(eval echo "\${BATMAN_ALLOW_$1:-0}")" = 1 ] || opf "/tmp/batman-slot.allow-$(echo "$1" | tr 'A-Z_' 'a-z-')"; }
# arithmetic `&` (throttled bits)
feed/batman-provision/files/usr/sbin/batman-slot :: power_ok :: [ $(( 0x$t & 0x1 )) -eq 0 ] || { warn "under-voltage now (throttled=0x$t)"; return 1; }
# `/etc/init.d/batpower running`: a foreground status query, starts nothing
feed/batman-provision/files/usr/sbin/batman-slot :: power_ok :: if [ -r "$RUNDIR/batpower.state" ] && /etc/init.d/batpower running >/dev/null 2>&1; then
# `&` inside a message
feed/batman-provision/files/usr/sbin/batman-slot :: p5_freshness_gate :: case "$out" in *unpersistable*) die_c 12 "p5 (config) cannot hold the running config: $keys contains forbidden characters (backtick \$ ( ) ; | & < > ') — change that value; '--save' cannot fix this. A reflash now would boot the fresh slot without it." ;; esac
# closes fd 3 (the caller's stdin copy), not the lock
feed/batman-provision/files/usr/sbin/batman-slot :: cmd_write :: exec 3<&-
# THE detached start while the lock is held: env (an external program) runs with fd 9 closed — run by s5-lock-release.sh
feed/batman-provision/files/usr/sbin/batman-slot :: addr_defer_release :: env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 9>&- &
# file tests on an init.d path in the mounted other slot, starts nothing
feed/batman-provision/files/usr/sbin/batman-slot :: rollback_lock_gate :: k=0; [ -f "$m/etc/init.d/batman-prov-lock" ] && [ -e "$m/etc/rc.d/S13batman-prov-lock" ] && k=1
# cmd_reboot's 240 s safety net: cmd_reboot never takes the lock (checked below), so there is no fd 9 to inherit
feed/batman-provision/files/usr/sbin/batman-slot :: cmd_reboot :: setsid sh -c "sleep 240; exec /usr/sbin/batman-reboot $n" </dev/null >/dev/null 2>&1 &
# prov-lock.sh (sourced in a subshell by the rollback gate): procd queries + a dropbear reload, foreground
feed/batman-provision/files/usr/lib/batman/prov-lock.sh :: prov_apply_lock :: if ! _pl_o=$(ubus -t 5 call service list '{"name":"dropbear"}' 2>/dev/null); then
feed/batman-provision/files/usr/lib/batman/prov-lock.sh :: prov_apply_lock :: "${PROV_DROPBEAR_INIT:-/etc/init.d/dropbear}" reload >/dev/null 2>&1
feed/batman-provision/files/usr/lib/batman/prov-lock.sh :: prov_apply_lock :: _pl_c=$(ubus -t 5 call service list '{"name":"dropbear"}' 2>/dev/null | jsonfilter -e '@.dropbear.instances[*].command' 2>/dev/null)
# bootfacts.sh: arithmetic `&` (bit masks)
feed/batman-provision/files/usr/lib/batman/bootfacts.sh :: bf_preq :: v=$(( 0x$h & 0x555 ))
feed/batman-provision/files/usr/lib/batman/bootfacts.sh :: bf_preq :: echo $(( (v & 1) | ((v >> 1) & 2) | ((v >> 2) & 4) | ((v >> 3) & 8) | ((v >> 4) & 16) | ((v >> 5) & 32) ))
EOF
)

# ---- the scan: lines <a|b> <file> <rel> -> "<rel> :: <fn> :: <line><TAB><LN>" for each line the mode picks ------------
IFS= read -r -d '' SCAN <<'AWK' || :
function cand(t,   x, o, nx) {
	if (mode == "a") return (t ~ /(^|[^A-Za-z0-9_])exec([^A-Za-z0-9_]|$)/ && t ~ /[<>]/)
	x = t; gsub(/&&/, " ", x); o = ""
	while (match(x, /[<>]&[0-8]/)) {   # N>&M / N<&M, M one digit 0-8 (not 9, not 1x): a plain fd copy
		nx = substr(x, RSTART + RLENGTH, 1)
		o = o substr(x, 1, RSTART - 1) (nx ~ /[0-9]/ ? substr(x, RSTART, RLENGTH) : " "); x = substr(x, RSTART + RLENGTH)
	}
	x = o x
	return (x ~ /&/ || t ~ /(^|[^A-Za-z0-9_.-])(setsid|nohup|start-stop-daemon|eval|coproc|service)([^A-Za-z0-9_.-]|$)/ \
		|| t ~ /sh -c/ || t ~ /\/etc\/init\.d\//)
}
function bsl(s,   k) { k = 0; while (k < length(s) && substr(s, length(s) - k, 1) == "\\") k++; return k }
function out(t) { gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
	if (t != "" && t !~ /^#/ && cand(t)) printf "%s :: %s :: %s\t%d\n", rel, (infn ? fn : "-"), t, ln }
{ l = $0; if (cont != "") l = cont l; else ln = NR; cont = "" }
bsl(l) % 2 { cont = substr(l, 1, length(l) - 1); next }
{
	st = (!infn && l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/)
	if (st) { fn = l; sub(/\(.*/, "", fn); infn = 1; ob = gsub(/[{]/, "{", l) - gsub(/[}]/, "}", l) }
	out(l)
	if (infn && (l ~ /^\}/ || (st && ob <= 0))) infn = 0
}
END { if (cont != "") out(cont) }
AWK
lines(){ REL=$3 awk -v mode="$1" 'BEGIN { rel = ENVIRON["REL"] } '"$SCAN" "$2"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# judge <allowlist> <found records>: the found keys must equal the list as a multiset. Prints "NEW <file>:<LN> (<fn>)
# <line>" for each found line not listed and "GONE <key>" for each listed line not found
judge(){
	printf '%s\n' "$1" | grep -v '^#' | grep . | LC_ALL=C sort > "$T/want"
	cut -f1 "$2" | LC_ALL=C sort > "$T/got"
	LC_ALL=C comm -23 "$T/got" "$T/want" | while IFS= read -r k; do
		K=$k awk -F'\t' '$1 == ENVIRON["K"] { split($1, p, / :: /); printf "NEW %s:%s (%s) %s\n", p[1], $2, p[2], substr($1, length(p[1]) + length(p[2]) + 9); exit }' "$2"
	done
	LC_ALL=C comm -13 "$T/got" "$T/want" | sed 's/^/GONE /'
}
report(){ # <tag> <allowlist> <found records>
	local nf r x; nf=$(grep -c . "$3"); r=$(judge "$2" "$3")
	[ "$nf" -gt 0 ] || bad "($1) no line found — nothing checked"
	[ -z "$r" ] && ok "($1) $nf line(s) found, each in the allowlist, every listed line found"
	while IFS= read -r x; do case "$x" in
		NEW*) bad "($1) line not in the allowlist — judge it and list it in a harness PR (#290): ${x#NEW }" ;;
		GONE*) bad "($1) allowlisted line not found (changed, moved or gone): ${x#GONE }" ;;
	esac; done <<< "$r"
}

# ---- (a) persistent fd opens: every shell file ---------------------------------------------------------------------
shf=()
while IFS= read -r f; do
	case "$f" in *.sh) ;; *) head -1 "$f" 2>/dev/null | grep -Eq '^#!.*(/sh|/ash|/bash|rc\.common)' || continue ;; esac
	shf+=("$f")
done < <(find "$R"/feed/*/files "$R/deploy/provisioning" -type f 2>/dev/null | sort)
[ "${#shf[@]}" -ge 10 ] && ok "(a) ${#shf[@]} shell files under feed/*/files + deploy/provisioning" || bad "(a) only ${#shf[@]} shell files found under $R/feed/*/files + deploy/provisioning"
for f in "${shf[@]}"; do lines a "$f" "${f#"$R"/}"; done > "$T/fa"
report a "$ALLOW_A" "$T/fa"

# ---- (b) batman-slot and what it sources, recursively ----------------------------------------------------------------
srcs(){ grep -v '^[[:space:]]*#' "$1" | grep -Eo '(^|[;&|({[:space:]])(\.|source)[[:space:]]+[^[:space:];&|)]+' | sed -E 's/^[;&|({[:space:]]*(\.|source)[[:space:]]+//' | tr -d "\"'"; }
bf=("$SLOT"); todo=$(srcs "$SLOT"); seen=" "
while [ -n "$todo" ]; do
	p=$(echo "$todo" | head -1); todo=$(echo "$todo" | sed 1d)
	case "$seen" in *" $p "*) continue ;; esac
	seen="$seen$p "
	case "$p" in
		/*) case "$p" in *'$'* | *'*'* | *'`'*) bad "(b) batman-slot sources '$p': not a literal path — cannot resolve it"; continue ;; esac ;;
		*) bad "(b) batman-slot sources '$p': not an absolute path — cannot resolve it"; continue ;;
	esac
	lf=$F$p; [ -f "$lf" ] || lf=$(ls -d "$R"/feed/*/files"$p" 2>/dev/null | head -1)
	[ -n "$lf" ] && [ -f "$lf" ] || { bad "(b) sourced $p is not in the feed tree ($R/feed/*/files) — not scanned"; continue; }
	bf+=("$lf"); todo=$(printf '%s\n%s\n' "$todo" "$(srcs "$lf")" | grep .)
done
[ "${#bf[@]}" -ge 2 ] && ok "(b) batman-slot + $(( ${#bf[@]} - 1 )) sourced file(s):$(for f in "${bf[@]:1}"; do printf '%s ' "${f##*/}"; done)" \
	|| bad "(b) batman-slot sources no shell file found in the feed tree (otatrace.sh / rundir.sh expected)"
for f in "${bf[@]}"; do lines b "$f" "${f#"$R"/}"; done > "$T/fb"
report b "$ALLOW_B" "$T/fb"
# the cmd_reboot entry holds only while fd 9 is never open there: cmd_reboot takes no lock and is dispatched by the
# `reboot` branch before the verb case, with no lock taken at top level before it
rb=$(awk '/^cmd_reboot\(\) \{/{s=NR} s && /^\}/{print s, NR; exit}' "$SLOT")
if [ -z "$rb" ]; then bad "(b) cmd_reboot() not found in batman-slot"
else
	rb_s=${rb% *}; rb_e=${rb#* }
	calls=$(grep -nE '(^|[^A-Za-z0-9_])cmd_reboot([^A-Za-z0-9_(]|$)' "$SLOT" | grep -v '^[0-9]*:[[:space:]]*#' | cut -d: -f1)
	vcase=$(grep -n '^case "[$][{]1:-[}]" in' "$SLOT" | head -1 | cut -d: -f1)
	toplock=$(sed -n "1,${calls:-0}p" "$SLOT" | awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/{f=1} f && /^\}/{f=0; next} !f' | grep -v '^[[:space:]]*#' | grep -Ec '(^|[^A-Za-z0-9_])(slot_lock|exec[[:space:]]+9)')
	if sed -n "${rb_s},${rb_e}p" "$SLOT" | grep -v '^[[:space:]]*#' | grep -Eq '(^|[^A-Za-z0-9_])slot_lock([^A-Za-z0-9_]|$)|exec[[:space:]]+9'; then
		bad "(b) cmd_reboot calls slot_lock / opens fd 9 — its background safety net would keep the lock"
	elif [ "$(echo "$calls" | grep -c .)" != 1 ]; then bad "(b) cmd_reboot called from $(echo "$calls" | grep -c .) places (want only the reboot branch): lines $(echo $calls)"
	elif [ -z "$vcase" ] || [ "$calls" -le "$rb_e" ] || [ "$calls" -ge "$vcase" ]; then bad "(b) cmd_reboot's call (line $calls) is not between its definition (end $rb_e) and the verb case (line ${vcase:-none})"
	elif ! sed -n "$((calls > 3 ? calls - 3 : 1)),${calls}p" "$SLOT" | grep -q 'if \[ "[$][{]1:-[}]" = reboot \]'; then bad "(b) cmd_reboot's call (line $calls) is not under the 'if [ \"\${1:-}\" = reboot ]' branch"
	elif [ "$toplock" != 0 ]; then bad "(b) top-level code before the reboot branch (line $calls) takes the lock: fd 9 would be open in cmd_reboot"
	else ok "(b) cmd_reboot takes no lock and is dispatched by the reboot branch (line $calls) before the verb case (line $vcase)"; fi
fi

# ---- (c) flock in the sysupgrade ramfs ----------------------------------------------------------------------------------
if [ -s "$PAB" ]; then
	rcb=$(grep -E '^[[:space:]]*(export[[:space:]]+)?RAMFS_COPY_BIN=' "$PAB" | sed -E "s/^[^=]*=//; s/[[:space:]]+#.*$//; s/^['\"]//; s/['\"]$//")
	if [ -z "$rcb" ]; then bad "(c) no RAMFS_COPY_BIN= in $PAB"
	elif echo " $rcb " | tr '\n' ' ' | grep -q ' /usr/bin/flock '; then ok "(c) RAMFS_COPY_BIN lists /usr/bin/flock"
	else bad "(c) RAMFS_COPY_BIN does not list /usr/bin/flock — slot_lock dies rc 18 in the sysupgrade ramfs: [$rcb]"; fi
else
	bad "(c) no $PAB"
fi

# ---- (d) negative control: each bypass, inserted into a copy of its file, must be an unlisted line --------------------
# "<a|b> <text>": b = after the slot_lock call in cmd_commit (batman-slot), a = appended to rundir.sh
nm=0; nmf=0
while IFS= read -r m; do
	case "$m" in ''|'#'*) continue ;; esac
	md=${m%% *}; mt=${m#* }; nm=$((nm + 1))
	case "$md" in
		b) src=$SLOT; MUT_T=$mt awk '{ print } !f && /^cmd_commit\(\) \{/ { f = 1 } f == 1 && /slot_lock/ { print "\t" ENVIRON["MUT_T"]; f = 2 }' "$src" > "$T/m" ;;
		a) src=$F/usr/lib/batman/rundir.sh; { cat "$src"; printf '%s\n' "$mt"; } > "$T/m" ;;
		s) src=$SLOT; sed -E "$mt" "$src" > "$T/m" ;;
	esac
	if cmp -s "$src" "$T/m"; then nmf=$((nmf + 1)); bad "(d) mutant not inserted: $mt"; continue; fi
	lines "${md/s/b}" "$T/m" "${src#"$R"/}" > "$T/fm"
	r=$(judge "$(if [ "$md" = a ]; then echo "$ALLOW_A"; else echo "$ALLOW_B"; fi)" "$T/fm")
	if [ "$md" = s ]; then echo "$r" | grep -q '^NEW ' && echo "$r" | grep -q '^GONE '; else echo "$r" | grep '^NEW ' | grep -qF -- "$mt"; fi \
		|| { nmf=$((nmf + 1)); bad "(d) bypass not caught ($md): $mt"; }
done <<'EOF'
# review r3 A (muts.all): F = the r2 parser's misses, G = `9>&-` that does not release (function / eval / builtin)
b sleep 100 a9>&- >/dev/null 2>&1 &
b : ${z:-$(sleep 100 >/dev/null 2>&1 &)}
b x="$(true "a"; sleep 100 >/dev/null 2>&1 &)"
b eval sleep 100 \>/dev/null 2\>\&1 \&
b J='sleep 100 >/dev/null 2>&1'"&"; eval "$J"
b /etc/init.d/batman-foo restart
b "/etc/init.d/batman-foo" start
b sleep 100 ${z:-9>&-} >/dev/null 2>&1 &
b SV=/etc/init.d/batman-foo; $SV start
b service batman-foo start
b case 1 in 1) sleep 100 >/dev/null 2>&1 & ;; esac
b f_x() { sleep 100 >/dev/null 2>&1 & }; f_x
b while false; do sleep 100 & done
b cat <<< "$(sleep 100 >/dev/null 2>&1 &)"
b x=${y#*&}; sleep 100 >/dev/null 2>&1 &
b ( sleep 100 >/dev/null 2>&1 & )
b SH="sh -c"; $SH 'sleep 100 >/dev/null 2>&1 &'
b busybox nohup sleep 100 >/dev/null 2>&1
b X='sleep 100 >/dev/null 2>&1 &'; $SHELL -c "$X"
b echo $((1)) & sleep 100 >/dev/null 2>&1 9>&-
b sleep 100 19>&- >/dev/null 2>&1 &
b exec sleep 100 >/dev/null 2>&1 &
b echo "${z:-$(sleep 100 >/dev/null 2>&1 &)}"
b sleep 100 &>/dev/null
b sh /etc/init.d/batman-foo start
b /etc/init.d/batman-foo boot
b hold_x() { /bin/sleep 100; }; hold_x 9>&- >/dev/null 2>&1 &
b eval "/bin/sleep 100" 9>&- &
b warn "x" 9>&- &
# review r2 / r3 B (mut.sh, mut2.sh): fd 9 copied to another fd (m4), detach helpers
b sleep 100 8>&9 9>&- &
b exec 8>&9; sleep 100 9>&- &
b sleep 100&
b if true; then sleep 100 & fi
b X=9; sleep 100 ${X}>&- &
b echo x | xargs -I{} sh -c 'sleep 100 &'
b start-stop-daemon --start --background --exec /bin/sleep -- 100
b busybox setsid sleep 100 </dev/null
b env setsid sleep 100
b ubus call service add '{}'
b flock -n 9 sleep 100 &
# a listed line changed in place (s = a sed on batman-slot): the openmanetd start without `9>&-`
s /openmanetd start/s/ 9>&- (&)$/ \1/
# review r3 A (ma.sh): (a) opens of the lock the r2 parser missed
a slot_peek() { exec 7<$(echo "$RUNDIR/batman-slot.flock"); flock -s -n 7; }
a slot_peek() { L=$(printf %s "$RUNDIR/batman-slot.flock"); exec 7<"$L"; flock -s -n 7; }
a slot_peek() { for L in "$RUNDIR"/batman-slot.flock; do exec 7<"$L"; done; flock -s -n 7; }
a slot_peek() { set -- "$RUNDIR/batman-slot.flock"; exec 7<"$1"; flock -s -n 7; }
a slot_peek() { exec 7<"$RUNDIR/batman-""slot.flock"; flock -s -n 7; }
a slot_peek() { exec 7<&9; }
a slot_peek() { cd "$RUNDIR" && exec 7<batman-slot.flock; }
EOF
[ "$nm" = 48 ] && [ "$nmf" = 0 ] && ok "(d) $nm bypasses, each inserted into a copy of its file, each an unlisted line" \
	|| bad "(d) negative control: $nmf of $nm bypass(es) not caught or not inserted (want 48, all caught)"

echo "S5-LOCK-LINT checks=$n fail=$fail"
[ "$n" -gt 0 ] && [ "$fail" = 0 ]
