#!/bin/bash
# tests/prov-p1/s5-lock-lint.sh <feed/batman-provision/files> — #254 P3 S5 (254-p3-impl §3.7.3, review r1 B-M3 / B-M4):
# the slot flock's two source lints and the sysupgrade ramfs check, offline.
#  (a) every `exec N<` / `exec N>` that opens the slot lock file (batman-slot.flock, or a variable set to it: $LOCKF …)
#      in any shell file under feed/*/files and deploy/provisioning is either batman-slot's ONE writer open inside
#      slot_lock(), or a reader inside a one-line `( … )` subshell (a brace group / plain exec would leave the shared
#      lock on the caller's shell: B15-MAJOR-1, every later `batman-slot commit` rc 14). A multi-line subshell is
#      refused too (fail-closed: rewrite it on one line);
#  (b) in batman-slot every detaching line — a background `&` (not `&&`, `2>&1`, `>&N`, `<&N`, `$(( ))`, quoted or
#      commented text), `setsid`, `nohup`, `start-stop-daemon`, `/etc/init.d/<x> start` — carries `9>&-` (a child that
#      inherits fd 9 keeps the lock after the verb returns). One exception: cmd_reboot, and only while it never calls
#      slot_lock / opens fd 9 and is dispatched by the `reboot` branch before the verb `case` (so fd 9 is never open);
#  (c) RAMFS_COPY_BIN (usr/lib/batman/platform-ab.sh) lists /usr/bin/flock: sysupgrade stage 2 runs batman-slot in the
#      ramfs, busybox has no SH_STANDALONE, so without it every ssh sysupgrade dies rc 18 (the #89 class: ramfs without tr).
# Negative controls (each FAILs): `9>&-` removed at the openmanetd start; a new `foo &` in cmd_commit; rundir.sh's
# `( exec 8<… )` as a brace group; slot_lock called in cmd_reboot; /usr/bin/flock dropped from RAMFS_COPY_BIN. A product
# without the flock slot_lock (main before S5) FAILs "predates S5". Nothing scanned / nothing found = FAIL.
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
trim(){ sed 's/^[[:space:]]*//' | cut -c1-"${1:-100}"; }

# ---- (a) who opens the lock file ------------------------------------------------------------------------------------
files=0; writers=0; readers=0
while IFS= read -r f; do
	case "$f" in *.sh) ;; *) head -1 "$f" 2>/dev/null | grep -Eq '^#!.*(/sh|/ash|/bash|rc\.common)' || continue ;; esac
	files=$((files + 1))
	# the names that hold the lock path in this file (LOCKF=$RUNDIR/batman-slot.flock …), as an ERE alternation
	vars=$(grep -Eo '(^|[[:space:];])[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*batman-slot\.flock' "$f" | sed -E 's/^[[:space:];]*//; s/=.*//' | sort -u | paste -sd'|')
	pat='batman-slot\.flock'
	[ -n "$vars" ] && pat="$pat|[\$][{]?($vars)([^A-Za-z0-9_]|$)"
	slot_range=""
	[ "$f" = "$SLOT" ] && slot_range=$(awk '/^slot_lock\(\) \{/{s=NR} s && /^\}/{print s, NR; exit}' "$f")
	rel=${f#"$R"/}
	while IFS=: read -r ln line; do
		echo "$line" | grep -Eq "$pat" || continue
		if [ -n "$slot_range" ] && [ "$ln" -gt "${slot_range% *}" ] && [ "$ln" -lt "${slot_range#* }" ] \
			&& echo "$line" | grep -Eq '^[[:space:]]*exec 9>>"?[$][{]?LOCKF[}]?"?[[:space:]]*$'; then
			writers=$((writers + 1)); ok "(a) $rel:$ln the writer open, inside slot_lock(): $(echo "$line" | trim)"
		elif echo "$line" | grep -Eq '[(][[:space:]]*(command[[:space:]]+)?exec[[:space:]]+[0-9]+<[^)]*[)]'; then
			readers=$((readers + 1)); ok "(a) $rel:$ln a reader open inside ( … ): $(echo "$line" | trim 90)"
		else
			bad "(a) $rel:$ln opens the slot lock outside slot_lock() and not in a one-line ( … ) subshell: $(echo "$line" | trim 110)"
		fi
	done < <(grep -nE '(^|[^A-Za-z0-9_])exec[[:space:]]+[0-9]+(<|>)' "$f")
done < <(find "$R"/feed/*/files "$R/deploy/provisioning" -type f 2>/dev/null | sort)
[ "$files" -ge 10 ] && ok "(a) scanned $files shell files" || bad "(a) only $files shell files scanned under $R/feed/*/files + deploy/provisioning"
[ "$writers" = 1 ] && ok "(a) exactly one writer open" || bad "(a) writer opens in slot_lock(): $writers, want 1"
[ "$readers" -ge 1 ] && ok "(a) $readers reader open(s) found and checked" || bad "(a) no reader open found (rundir.sh slot_busy?) — nothing checked"

# ---- (b) detaching lines in batman-slot -------------------------------------------------------------------------------
rb=$(awk '/^cmd_reboot\(\) \{/{s=NR} s && /^\}/{print s, NR; exit}' "$SLOT")
[ -n "$rb" ] || bad "(b) cmd_reboot() not found in batman-slot"
rb_s=${rb% *}; rb_e=${rb#* }
# per line: drop quoted text (the quote state carries across lines), escapes, comments, $(( … )), &&, N>&M, N<&M, &>;
# what is left detaches if it has a `&`, setsid / nohup / start-stop-daemon, or /etc/init.d/<x> start
det=$(awk '
	{ out = ""; L = $0; i = 1
	  while (i <= length(L)) {
		c = substr(L, i, 1)
		if (q == "s") { if (c == "\047") q = ""; i++; continue }
		if (q == "d") { if (c == "\\") { i += 2; continue } if (c == "\"") q = ""; i++; continue }
		if (c == "\\") { i += 2; continue }
		if (c == "\047") { q = "s"; i++; continue }
		if (c == "\"") { q = "d"; i++; continue }
		if (c == "#" && (i == 1 || substr(L, i - 1, 1) ~ /[ \t;]/)) break
		out = out c; i++
	  }
	  u = out
	  while (match(u, /\$\(\(/)) { e = index(substr(u, RSTART), "))"); if (!e) break; u = substr(u, 1, RSTART - 1) substr(u, RSTART + e + 1) }
	  gsub(/&&/, "", u); gsub(/[0-9]*[<>]&[0-9-]+/, "", u); gsub(/&>>?/, "", u)
	  if (u ~ /&/ || u ~ /(^|[^A-Za-z0-9_.-])(setsid|nohup|start-stop-daemon)([^A-Za-z0-9_.-]|$)/ || u ~ /\/etc\/init\.d\/[^ ]+[ \t]+start/) print NR ":" $0
	}' "$SLOT")
nd=0
while IFS=: read -r ln line; do
	[ -n "$ln" ] || continue
	nd=$((nd + 1)); s=$(echo "$line" | trim)
	if echo "$line" | grep -q '9>&-'; then ok "(b) :$ln detaches with fd 9 closed: $s"
	elif [ -n "$rb" ] && [ "$ln" -gt "$rb_s" ] && [ "$ln" -lt "$rb_e" ]; then ok "(b) :$ln in cmd_reboot (fd 9 never open there, checked below): $s"
	else bad "(b) :$ln detaches WITHOUT 9>&- (the child would keep the slot lock): $s"; fi
done <<< "$det"
[ "$nd" -ge 2 ] && ok "(b) $nd detaching lines found and checked" || bad "(b) only $nd detaching lines found (want the openmanetd start + the reboot safety net) — the scan is broken"
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

# ---- (c) flock in the sysupgrade ramfs ----------------------------------------------------------------------------------
if [ -s "$PAB" ]; then
	rcb=$(grep -E '^[[:space:]]*(export[[:space:]]+)?RAMFS_COPY_BIN=' "$PAB" | sed -E "s/^[^=]*=//; s/[[:space:]]+#.*$//; s/^['\"]//; s/['\"]$//")
	if [ -z "$rcb" ]; then bad "(c) no RAMFS_COPY_BIN= in $PAB"
	elif echo " $rcb " | tr '\n' ' ' | grep -q ' /usr/bin/flock '; then ok "(c) RAMFS_COPY_BIN lists /usr/bin/flock"
	else bad "(c) RAMFS_COPY_BIN does not list /usr/bin/flock — slot_lock dies rc 18 in the sysupgrade ramfs: [$rcb]"; fi
else
	bad "(c) no $PAB"
fi
echo "S5-LOCK-LINT checks=$n fail=$fail"
[ "$n" -gt 0 ] && [ "$fail" = 0 ]
