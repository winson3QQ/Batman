#!/bin/bash
# tests/prov-p1/prov-apply-lock.sh <prov-lock.sh> — #254 claim-lock fix (docs/design/254-claim-lock-fix.md §5.3, §11.2):
# the ONE lock implementation prov_apply_lock, run under busybox ash against fake uci / ubus / jsonfilter / dropbear
# init in a temp root. Every step's failure is induced; no root needed. PASS/FAIL per case; rc 0 only if all pass.
# A run that executes zero cases FAILs.
set -u
LIB=$(readlink -f "${1:?usage: $0 <prov-lock.sh>}")
command -v busybox >/dev/null || { echo "FAIL busybox missing"; exit 1; }
T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
B=$T/bin; mkdir -p "$B"
fails=0; cases=0
ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }

# ---- fakes ---------------------------------------------------------------------------------------------------------
cat > "$B/uci" <<'EOF'
#!/bin/sh
# flat store "key=value" in $UCI_DB; supports: -q show <cfg>, set k=v, commit <cfg>
db=$UCI_DB; [ "$1" = -q ] && shift
case "$1" in
show) grep "^$2[.=]" "$db" | sed "s/=\(.*\)$/='\1'/; s/^\([^=]*\)='\(dropbear\|system\)'$/\1=\2/" ;;
set)  k=$(echo "${2%%=*}" | sed 's/^system\.@system\[0\]/system.sys0/'); v=${2#*=}
      grep -v "^$k=" "$db" > "$db.n"; echo "$k=$v" >> "$db.n"; mv "$db.n" "$db"; [ -z "${UCI_SET_FAIL:-}" ] ;;
commit) echo "$2" >> "$UCI_DB.commits"; [ "${UCI_COMMIT_FAIL:-}" != "$2" ] ;;
*) exit 1 ;;
esac
EOF
cat > "$B/ubus" <<'EOF'
#!/bin/sh
echo "$*" >> "$UBUS_LOG"
[ -n "${UBUS_FAIL:-}" ] && exit 4
cat "$UBUS_JSON"
EOF
cat > "$B/jsonfilter" <<'EOF'
#!/bin/sh
sed -n 's/.*"command": \(\[.*\]\).*/\1/p'
EOF
cat > "$T/dropbear.init" <<'EOF'
#!/bin/sh
echo "$1" >> "$UBUS_LOG.init"
[ -n "${RELOAD_NOOP:-}" ] && exit 0
# reload: every instance gets -s -g when every section is locked (the real init reads uci, dropbear.init:322-327)
grep -q 'PasswordAuth=on' "$UCI_DB" && exit 0
# fault seams for the read-back (code review A-M2): only the FIRST instance reloaded / only -s, no -g
if [ -n "${RELOAD_PARTIAL:-}" ]; then
	sed -i '0,/"command": \[ "\/usr\/sbin\/dropbear", "-F"/s//"command": [ "\/usr\/sbin\/dropbear", "-F", "-s", "-g"/' "$UBUS_JSON"; exit 0
fi
if [ -n "${RELOAD_S_ONLY:-}" ]; then
	sed -i 's/"command": \[ "\/usr\/sbin\/dropbear", "-F"/"command": [ "\/usr\/sbin\/dropbear", "-F", "-s"/' "$UBUS_JSON"; exit 0
fi
sed -i 's/"command": \[ "\/usr\/sbin\/dropbear", "-F"/"command": [ "\/usr\/sbin\/dropbear", "-F", "-s", "-g"/' "$UBUS_JSON"
EOF
cat > "$B/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >> "$UBUS_LOG.logger"
EOF
cat > "$B/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$B"/* "$T/dropbear.init"
HASH='$6$abcdefghijklmnop$0123456789012345678901234567890123456789012345678901234567890123456789012345678901234/'

# setup <root-field> [instances]: fresh state
setup(){
	S=$T/c$cases; rm -rf "$S"; mkdir -p "$S/etc" "$S/state"
	printf 'root:%s:0:0:99999:7:::\ndaemon:*:0:0:99999:7:::\n' "$1" > "$S/etc/shadow"; chmod 600 "$S/etc/shadow"
	{ echo "dropbear.main=dropbear"; echo "dropbear.main.PasswordAuth=on"; echo "dropbear.main.RootPasswordAuth=on"
	  [ "${2:-1}" = 2 ] && { echo "dropbear.lan2=dropbear"; echo "dropbear.lan2.PasswordAuth=on"; echo "dropbear.lan2.RootPasswordAuth=on"; }
	  echo "system.sys0=system"; echo "system.sys0.ttylogin=0"; } > "$S/uci"
	i=1; { echo '{ "dropbear": { "instances": {'; while [ "$i" -le "${2:-1}" ]; do
		echo "\"instance$i\": { \"command\": [ \"/usr/sbin/dropbear\", \"-F\", \"-p\", \"22\" ] },"; i=$((i + 1)); done; echo '} } }'; } > "$S/ubus.json"
	: > "$S/ubus.log"
}
# run [env...] -- <args> : runs prov_apply_lock under busybox ash with stdin from $STDIN (default /dev/null)
run(){
	local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
	OUT=$(env -i PATH="$B:/usr/bin:/bin" UCI_DB="$S/uci" UBUS_JSON="$S/ubus.json" UBUS_LOG="$S/ubus.log" \
		PROV_SHADOW="$S/etc/shadow" PROV_STATE="$S/state" PROV_DROPBEAR_INIT="$T/dropbear.init" "${envs[@]}" \
		timeout 20 busybox sh -c ". '$LIB'; prov_apply_lock $*" < "${STDIN:-/dev/null}" 2>&1); RC=$?
	LAST=$(printf '%s\n' "$OUT" | tail -1)
}
root_field(){ grep '^root:' "$S/etc/shadow" | cut -d: -f2; }
uv(){ sed -n "s/^$1=//p" "$S/uci"; }
expect(){ # expect <case name> <condition string, evaluated here: values are never spliced into code>
	local n=$1; cases=$((cases + 1)); if eval "$2"; then ok "$n"; else no "$n — rc=$RC last=[$LAST] root=[$(root_field)] lock=[$(cat "$S/state/lock-status" 2>/dev/null)]"; fi; }
locked_uci(){ [ "$(uv dropbear.main.PasswordAuth)" = off ] && [ "$(uv dropbear.main.RootPasswordAuth)" = off ] && [ "$(uv system.sys0.ttylogin)" = 1 ]; }
printf '%s\n' "$HASH" > "$T/hash.in"

# 1 normal: hash written, uci locked, reload + read-back, LOCKED
setup ""; STDIN=$T/hash.in run -- --hash-stdin
expect "hash-stdin: all steps ok" '[ "$RC" = 0 ] && [ "$LAST" = "LOCK ok rc=0" ]'
expect "hash-stdin: root = hash, other lines intact" '[ "$(root_field)" = "$HASH" ] && grep -q "^daemon:\*:" "$S/etc/shadow"'
expect "hash-stdin: uci locked" 'locked_uci'
expect "hash-stdin: dropbear reloaded and read back" 'grep -q reload "$S/ubus.log.init" && grep -q -- "\"-s\", \"-g\"" "$S/ubus.json"'
expect "hash-stdin: lock-status LOCKED" '[ "$(cat "$S/state/lock-status")" = LOCKED ]'
expect "hash-stdin: shadow stays 0600" '[ "$(stat -c %a "$S/etc/shadow")" = 600 ]'
expect "hash-stdin: no temp file left" '! ls -A "$S/etc" | grep -q "^\.shadow\."'

# 2 no flag: stdin is NEVER read (a stdin that never ends must not block); empty root -> '!'
setup ""; mkfifo "$T/never"; ( sleep 30 > "$T/never" ) & SP=$!
# shellcheck disable=SC2034  # t0 is read inside the eval'd condition below
t0=$SECONDS; STDIN=$T/never run -- ; kill $SP 2>/dev/null; wait $SP 2>/dev/null
expect "no flag: returns at once although stdin never ends" '[ $((SECONDS - t0)) -lt 15 ] && [ "$RC" = 0 ]'
expect "no flag: empty root -> '!'" '[ "$(root_field)" = "!" ]'
rm -f "$T/never"
setup "$HASH"; run --
expect "no flag: an existing \$ hash is kept" '[ "$(root_field)" = "$HASH" ]'

# 3 invalid root fields are refused, shadow untouched
for bad in 'plain' '$6$a:b' '' '!' '$6$short$abc' '$6$rounds=999$salt$0123456789012345678901234567890123456789012345678901234567890123456789012345678901234/'; do
	setup ""; printf '%s\n' "$bad" > "$T/bad.in"; STDIN=$T/bad.in run -- --hash-stdin
	expect "bad field [$bad] -> rc 3, shadow untouched" '[ "$RC" = 3 ] && [ -z "$(root_field)" ]'
done
# v8 (§5.3): --hash-stdin takes every hash musl can verify, $5$ / $1$ included
for good in '$5$abcdefghijklmnop$0123456789012345678901234567890123456789012' '$1$abcdefgh$0123456789012345678901'; do
	setup ""; printf '%s\n' "$good" > "$T/good.in"; STDIN=$T/good.in run -- --hash-stdin
	expect "--hash-stdin [${good%%\$0*}…] -> rc 0, written" '[ "$RC" = 0 ] && [ "$(root_field)" = "$good" ]'
done
# --restore-stdin writes a $… / !… field back as is, anything else as "!" (same rule as the helper's RestoreRoot)
setup "$HASH"; printf '%s\n' 'garbage' > "$T/g.in"; STDIN=$T/g.in run -- --restore-stdin --no-reload
expect "restore-stdin [garbage] -> \"!\"" '[ "$RC" = 0 ] && [ "$(root_field)" = "!" ]'
setup "$HASH"; printf '%s\n' '$6$short$abc' > "$T/g.in"; STDIN=$T/g.in run -- --restore-stdin --no-reload
expect "restore-stdin [\$6\$short\$abc] -> written back as is (the previous field, not judged)" '[ "$RC" = 0 ] && [ "$(root_field)" = "\$6\$short\$abc" ]'

# 4 step 1 fails (uci commit) -> rc 1, the given hash is NOT written, empty root -> '!', LOCK-INCOMPLETE
setup ""; STDIN=$T/hash.in run UCI_COMMIT_FAIL=system -- --hash-stdin
expect "uci commit fails -> rc 1 / LOCK uci" '[ "$RC" = 1 ] && [ "$LAST" = "LOCK uci rc=1" ]'
expect "uci fail: hash not written, empty root -> '!'" '[ "$(root_field)" = "!" ]'
expect "uci fail: lock-status LOCK-INCOMPLETE" '[ "$(cat "$S/state/lock-status")" = LOCK-INCOMPLETE ]'

# 5 step 2: ubus failure is a failure (fail-closed), not "dropbear not running"
setup ""; STDIN=$T/hash.in run UBUS_FAIL=1 -- --hash-stdin
expect "ubus fails -> rc 2 / LOCK dropbear" '[ "$RC" = 2 ] && [ "$LAST" = "LOCK dropbear rc=2" ]'
expect "ubus fail: hash not written, empty root -> '!'" '[ "$(root_field)" = "!" ]'
# reload did not take effect (read-back lacks -s -g)
setup ""; STDIN=$T/hash.in run RELOAD_NOOP=1 -- --hash-stdin
expect "read-back without -s -g -> rc 2" '[ "$RC" = 2 ]'
# no dropbear instance (not running) -> step 2 skipped, rc 0
setup ""; echo '{ "dropbear": { } }' > "$S/ubus.json"; STDIN=$T/hash.in run -- --hash-stdin
expect "dropbear not running -> step 2 skipped, rc 0" '[ "$RC" = 0 ] && ! grep -q reload "$S/ubus.log.init" 2>/dev/null'

# 6 --no-reload: ubus never called
setup ""; STDIN=$T/hash.in run UBUS_FAIL=1 -- --hash-stdin --no-reload
expect "--no-reload: no ubus call, rc 0" '[ "$RC" = 0 ] && [ ! -s "$S/ubus.log" ]'

# 7 every dropbear section is locked and every instance read back
setup "" 2; STDIN=$T/hash.in run -- --hash-stdin
expect "two sections: both locked, rc 0" '[ "$RC" = 0 ] && [ "$(uv dropbear.lan2.PasswordAuth)" = off ] && [ "$(uv dropbear.lan2.RootPasswordAuth)" = off ]'
# the read-back discriminates (code review A-M2): one of two instances not reloaded / -s without -g -> step 2 fails
setup "" 2; STDIN=$T/hash.in run RELOAD_PARTIAL=1 -- --hash-stdin
expect "read-back: one of two instances without -s -g -> rc 2, hash not written" '[ "$RC" = 2 ] && [ "$(root_field)" = "!" ]'
setup ""; STDIN=$T/hash.in run RELOAD_S_ONLY=1 -- --hash-stdin
expect "read-back: -s without -g -> rc 2, hash not written" '[ "$RC" = 2 ] && [ "$(root_field)" = "!" ]'

# 8 --restore-stdin writes the field even when step 1 fails (the helper's restore after a failed --save); its rc is
#   step 3's alone (code review B-m3) and lock-status still says the doors are not locked
setup "$HASH"; printf '%s\n' '!' > "$T/bang.in"; STDIN=$T/bang.in run UCI_COMMIT_FAIL=dropbear -- --restore-stdin --no-reload
expect "restore-stdin: written although uci failed, rc 0 (restore done), LOCK-INCOMPLETE" '[ "$RC" = 0 ] && [ "$(root_field)" = "!" ] && [ "$(cat "$S/state/lock-status")" = LOCK-INCOMPLETE ]'
setup "$HASH"; chmod 555 "$S/etc"; printf '%s\n' '!' > "$T/bang.in"; STDIN=$T/bang.in run -- --restore-stdin --no-reload; chmod 755 "$S/etc"
[ "$(id -u)" = 0 ] || expect "restore-stdin: shadow not writable -> rc 3" '[ "$RC" = 3 ]'
OLD='$6$oldoldoldoldoldo$9999999999999999999999999999999999999999999999999999999999999999999999999999999999999.'
setup "$HASH"; printf '%s\n' "$OLD" > "$T/old.in"; STDIN=$T/old.in run -- --restore-stdin --no-reload
expect "restore-stdin: old hash back, rc 0" '[ "$RC" = 0 ] && [ "$(root_field)" = "$OLD" ]'

# 9 shadow write fails (directory not writable -> mktemp fails) -> rc 3, original intact
if [ "$(id -u)" != 0 ]; then
	setup ""; chmod 555 "$S/etc"; STDIN=$T/hash.in run -- --hash-stdin --no-reload; chmod 755 "$S/etc"
	expect "shadow dir read-only -> rc 3 / LOCK shadow, original intact" '[ "$RC" = 3 ] && [ "$LAST" = "LOCK shadow rc=3" ] && [ -z "$(root_field)" ]'
else echo "NOTE running as root: the read-only-dir case is meaningless and not counted"; fi

# 10 bad argument
setup ""; run -- --bogus
expect "unknown flag -> rc 9" '[ "$RC" = 9 ]'

# 11 prov_lock_decision with and without `any`
d(){ env -i PATH=/usr/bin:/bin busybox sh -c ". '$LIB'; prov_lock_decision $*"; }
cases=$((cases + 1)); r="$(d 1 ok unclaimed claimed) $(d 1 ok unclaimed claimed any) $(d 1 ok legacy - any) $(d 1 ok claimed -) $(d 1 bad - -) $(d 0 - - member) $(d 0 - - unclaimed any)"
[ "$r" = "TODAY LOCK TODAY LOCK LOCK LOCK TODAY" ] && ok "prov_lock_decision table ($r)" || no "prov_lock_decision table: $r"

[ "$cases" -ge 20 ] || { no "only $cases cases ran"; }
echo "prov-apply-lock: $cases cases, $fails failed"
[ "$fails" = 0 ]
