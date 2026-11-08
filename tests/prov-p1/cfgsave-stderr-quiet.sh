#!/bin/bash
# tests/prov-p1/cfgsave-stderr-quiet.sh <repo root> — #320 (docs/design/320-cfgsave-stderr-quiet.md §6): busybox ash
# prints "can't open <file>" BEFORE a later `2>/dev/null` (or `>/dev/null 2>&1`) takes effect in `cmd < "$F" 2>/dev/null`,
# so every such redirect-read in the product tree is written `{ cmd < "$F"; } 2>/dev/null`. Three parts, no root:
#   1. lint, zero exceptions, over feed/*/files: an input redirect followed on the same simple command by a stderr
#      discard is a hit (self-test: every noisy spelling hits, every quiet form does not);
#   2. the #202 A3 write-amplification guard, extracted from the product batman-config-save, run under busybox ash:
#      $WRITES missing -> stderr empty, wn=0 wl=0, rc 0; "25 90" -> rc 1 rate-limited; "5 90" -> counts kept;
#   3. negative control: a mutant with the old A3 line back -> stderr has "can't open", lint 1 hit.
# Harness-first (#290): on a product that still has the old lines, part 1 and part 2 FAIL — that run IS the negative
# control. Zero cases = FAIL. Every FAIL line starts "FAIL cfgsave-stderr-quiet:"; last line "... fails=N".
# Known limits (design §6): a `<` inside a quoted string followed by a space, or an arithmetic `a < b`, on a line that
# also discards stderr is a hit too — split that line; a command continued with `\` is not scanned as one line.
set -u
R=$(cd "${1:?usage: $0 <repo root>}" 2>/dev/null && pwd) || { echo "FAIL cfgsave-stderr-quiet: no such dir $1"; echo "CFGSAVE-STDERR-QUIET cases=0 fails=1"; exit 1; }
CS=$R/feed/batman-provision/files/usr/bin/batman-config-save
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cases=0; fails=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL cfgsave-stderr-quiet: $*"; fails=$((fails+1)); }
fin(){ echo "CFGSAVE-STDERR-QUIET cases=$cases fails=$fails"; [ "$cases" -gt 0 ] && [ "$fails" = 0 ]; }
[ -f "$CS" ] || { no "no product batman-config-save at $CS"; fin; exit 1; }
BB=$(command -v busybox 2>/dev/null) || { no "no busybox on this host — the A3 block must run under the node's shell (busybox ash)"; fin; exit 1; }

# ---- 1. lint ----------------------------------------------------------------------------------------------------
# A `<` at the start of a word (preceded by start of line, blank or an opening paren), an operand starting with a
# quote, ~, $, /, letter or dot, then — with no ; | & in between, i.e. the same simple command — a stderr discard:
# 2>/dev/null, 2> /dev/null, 2>>/dev/null, 2>&-, or >/dev/null 2>&1 (busybox prints before any of them applies).
# Quiet by construction: the brace form (`; }` intervenes), `<<` here-docs, `<&` dups, `<2>` kmsg priorities, a `<`
# glued to the previous char (sed/awk programs, `\<`), and `2>/dev/null </dev/null` (nothing after the redirect).
# An operand of /dev/null itself cannot fail to open and is excluded.
RE="(^|[[:space:]()])<[[:space:]]*[\"'~\$/A-Za-z_.][^;|&]*[[:space:]](2>>?[[:space:]]*/dev/null|2>&-|>[[:space:]]*/dev/null[[:space:]]+2>&1)"
lint(){ grep -nE "$RE" "$@" | grep -vE '<[[:space:]]*/dev/null'; }
cases=$((cases+1))
noisy='read -r a b < "$F" 2>/dev/null || a=0
v=$(tr "\n" " " < /etc/x 2>/dev/null | sed 1p)
if uci batch < "$TMP" 2>/dev/null; then
cmd < "$F" 2> /dev/null
cmd < "$F" 2>&-
cmd < "$F" 2>>/dev/null
cmd < "$F" >/dev/null 2>&1
cmd <'"'"'$F'"'"' 2>/dev/null
x=$(wc -c <~/f 2>/dev/null)'
n=$(printf '%s\n' "$noisy" > "$T/noisy"; lint "$T/noisy" | wc -l)
[ "$n" = 9 ] && ok "lint self-test: every noisy spelling is a hit (9/9)" || no "lint self-test: $n/9 noisy spellings matched"
cases=$((cases+1))
quiet='{ read -r a b < "$F"; } 2>/dev/null || a=0
v=$({ tr "\n" " " < /etc/x; } 2>/dev/null | sed 1p)
echo "<2>x: $*" > /dev/kmsg 2>/dev/null
cat <<EOT 2>/dev/null
cmd 2>/dev/null </dev/null
cmd </dev/null >/dev/null 2>&1
cmd < /dev/null 2>/dev/null
exec 3<&0 2>/dev/null
awk '"'"'$1<2'"'"' f 2>/dev/null
[ "$a" \< "$b" ] 2>/dev/null
sed "s/<x/y/" f 2>/dev/null
grep -q "<title" f 2>/dev/null'
q=$(printf '%s\n' "$quiet" > "$T/quiet"; lint "$T/quiet")
[ -z "$q" ] && ok "lint self-test: brace form, kmsg priority, here-doc, reversed order, dup, /dev/null operand, glued < are not hits (12/12)" || no "lint self-test: a quiet form is a hit: $(echo "$q" | tr '\n' ' ')"
cases=$((cases+1))
hits=$(cd "$R" && grep -rnE "$RE" feed/*/files 2>/dev/null | grep -vE '<[[:space:]]*/dev/null')
if [ -z "$hits" ]; then ok "lint: no unguarded redirect-read in feed/*/files"
else printf '%s\n' "$hits" | sed 's/^/       /'; no "lint: $(printf '%s\n' "$hits" | wc -l) unguarded redirect-read(s) in feed/*/files, first $(printf '%s\n' "$hits" | head -1 | cut -d: -f1,2) — busybox ash prints \"can't open\" before 2> applies; write { cmd < f; } 2>/dev/null (a '<' inside a string: split the line) (#320)"; fi

# ---- 2. the A3 block under busybox ash --------------------------------------------------------------------------
# the product comment line is the marker; the block ends at the next column-0 `fi` and is bounded (<= 15 lines)
a3(){ awk '/^# write-amplification guard \(#202 A3\)/{p=1} p{print} p&&/^fi$/{exit}' "$1"; }
# run_a3 <file> <writes content|-> : $T/out $T/err $T/rc
run_a3(){
	local blk; blk=$(a3 "$1")
	printf '%s\n' "$blk" | grep -q 'read -r wn wl' || return 9
	rm -rf "$T/w"; mkdir -p "$T/w/stage" "$T/w/mnt"; [ "$2" = - ] || echo "$2" > "$T/w/cfgsave-writes"
	{ echo 'set -u; mode=--on-join; RDOK=1; STAGE=$W/stage; MNT=$W/mnt; WRITES=$W/cfgsave-writes'
	  echo 'up(){ echo 100; }; err(){ echo "batman-config-save: $*" >&2; }; umount(){ :; }'
	  printf '%s\n' "$blk"; echo 'echo "wn=$wn wl=$wl"'; } > "$T/a3.sh"
	W=$T/w "$BB" sh "$T/a3.sh" > "$T/out" 2> "$T/err"; echo $? > "$T/rc"
}
cases=$((cases+1)); blk=$(a3 "$CS"); n=$(printf '%s\n' "$blk" | wc -l); last=$(printf '%s\n' "$blk" | tail -1)
if [ "$n" -ge 5 ] && [ "$n" -le 15 ] && [ "$last" = fi ] && printf '%s\n' "$blk" | grep -q 'read -r wn wl'; then ok "A3 block extracted from the product ($n lines, ends at fi)"
else no "A3 block not extracted from $CS: $n lines, last=[$last] (marker '# write-amplification guard (#202 A3)' to the next column-0 'fi', 5..15 lines, must contain 'read -r wn wl')"; fin; exit 1; fi
cases=$((cases+1)); run_a3 "$CS" -
if [ "$(cat "$T/rc")" = 0 ] && [ ! -s "$T/err" ] && grep -qx 'wn=0 wl=0' "$T/out"; then ok "A3, \$WRITES missing: rc 0, stderr empty, wn=0 wl=0"
else no "A3, \$WRITES missing: rc=$(cat "$T/rc") stdout=[$(tr '\n' ' ' < "$T/out")] stderr=[$(tr '\n' ' ' < "$T/err" | cut -c1-200)]"; fi
cases=$((cases+1)); run_a3 "$CS" "25 90"
if [ "$(cat "$T/rc")" = 1 ] && grep -q 'write rate-limited (25 writes this boot)' "$T/err"; then ok "A3, 25 writes 10 s ago: rc 1, rate-limited"
else no "A3, 25 writes 10 s ago: rc=$(cat "$T/rc") stderr=[$(tr '\n' ' ' < "$T/err" | cut -c1-200)] — the extracted block lost its logic"; fi
cases=$((cases+1)); run_a3 "$CS" "5 90"
if [ "$(cat "$T/rc")" = 0 ] && [ ! -s "$T/err" ] && grep -qx 'wn=5 wl=90' "$T/out"; then ok "A3, 5 writes: rc 0, counts kept (wn=5 wl=90)"
else no "A3, 5 writes: rc=$(cat "$T/rc") stdout=[$(tr '\n' ' ' < "$T/out")] stderr=[$(tr '\n' ' ' < "$T/err" | cut -c1-200)]"; fi

# ---- 3. negative control: the old A3 line back ------------------------------------------------------------------
sed 's/{ read -r wn wl < "\$WRITES"; } 2>\/dev\/null/read -r wn wl < "$WRITES" 2>\/dev\/null/' "$CS" > "$T/mutant"
if cmp -s "$CS" "$T/mutant"; then
	if [ -n "$hits" ]; then echo "note: the product still carries the old A3 line (pre-#320) — the \$WRITES-missing case above is the negative control"
	else cases=$((cases+1)); no "mutant pattern stale: the product has no lint hit, yet the fixed A3 line '{ read -r wn wl < \"\$WRITES\"; } 2>/dev/null' is not there — update the mutant sed in this test"; fi
else
	cases=$((cases+1)); run_a3 "$T/mutant" -
	if grep -q "can't open" "$T/err" && [ "$(cat "$T/rc")" = 0 ] && grep -qx 'wn=0 wl=0' "$T/out"; then ok "mutant (old line): stderr has \"can't open\", values unchanged — the stderr assertion discriminates"
	else no "mutant (old line) did not reproduce: rc=$(cat "$T/rc") stderr=[$(tr '\n' ' ' < "$T/err" | cut -c1-200)]"; fi
	cases=$((cases+1)); m=$(lint "$T/mutant" | wc -l)
	[ "$m" = 1 ] && ok "mutant (old line): lint 1 hit" || no "mutant (old line): lint $m hits, want 1"
fi
fin
