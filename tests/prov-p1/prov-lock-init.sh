#!/bin/bash
# tests/prov-p1/prov-lock-init.sh <batman-prov-lock init> <prov-lock.sh> — #254 claim-lock fix §5.4 / §11.2: the S13
# boot-time lock, under busybox ash, against a directory standing in for p5, fake uci / ubus / logger. Covers the
# decision (p5 state × p6 last_known_state × identity × shadow-root) and the convergence of root to p5. No root.
# A run that executes zero cases FAILs.
set -u
INIT=$(readlink -f "${1:?usage: $0 <init> <prov-lock.sh>}"); LIB=$(readlink -f "${2:?}")
[ -f "$INIT" ] && [ -f "$LIB" ] || { echo "FAIL missing $INIT or $LIB"; exit 1; }
command -v busybox >/dev/null || { echo "FAIL busybox missing"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$T/bin; mkdir -p "$B"; fails=0; cases=0
ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
cat > "$B/uci" <<'EOF'
#!/bin/sh
db=$UCI_DB; [ "$1" = -q ] && shift
case "$1" in
show) grep "^$2[.=]" "$db" | sed "s/=\(.*\)$/='\1'/; s/^\([^=]*\)='\(dropbear\|system\)'$/\1=\2/" ;;
get)  k=$(echo "$2" | sed 's/^system\.@system\[0\]/system.sys0/'); sed -n "s/^$k=//p" "$db" ;;
set)  k=$(echo "${2%%=*}" | sed 's/^system\.@system\[0\]/system.sys0/'); v=${2#*=}
      grep -v "^$k=" "$db" > "$db.n"; echo "$k=$v" >> "$db.n"; mv "$db.n" "$db" ;;
commit) echo "$2" >> "$UCI_DB.commits" ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >> "$UCI_DB.ubus"\nexit 4\n' > "$B/ubus"   # S13 must never need ubus (--no-reload)
printf '#!/bin/sh\necho "$*" >> "$UCI_DB.log"\n' > "$B/logger"
printf '#!/bin/sh\nexit 0\n' > "$B/sync"
chmod +x "$B"/*
H5='$6$p5p5p5p5p5p5p5p5$5555555555555555555555555555555555555555555555555555555555555555555555555555555555555.'
HL='$6$livelivelivelive$LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL'

# mk <p5 state|absent|bad> <identity same|diff> <shadow-root line|-> <live root field> <locked 0|1>
mk(){
	S=$T/c$cases; rm -rf "$S"; mkdir -p "$S/p5/identity/prov" "$S/provd/identity" "$S/etc"
	echo "abc  node.key" > "$S/provd/identity/sha256"
	if [ "$2" = same ]; then cp "$S/provd/identity/sha256" "$S/p5/identity/prov/sha256"; else echo "zzz  node.key" > "$S/p5/identity/prov/sha256"; fi
	case "$1" in
		absent) rm -rf "$S/p5" ;;
		bad) echo "garbage" > "$S/p5/prov.meta" ;;
		*) printf 'cbor-%s' "$1" > "$S/p5/prov.cbor"; echo "v=1 state=$1 gen=2 sha=$(sha256sum < "$S/p5/prov.cbor" | cut -c1-64)" > "$S/p5/prov.meta" ;;
	esac
	[ "$3" = - ] || { [ -d "$S/p5" ] && echo "$3" > "$S/p5/identity/shadow-root"; }
	printf 'root:%s:0:0:99999:7:::\n' "$4" > "$S/etc/shadow"; chmod 600 "$S/etc/shadow"
	v=on; t=0; [ "$5" = 1 ] && { v=off; t=1; }
	printf 'dropbear.main=dropbear\ndropbear.main.PasswordAuth=%s\ndropbear.main.RootPasswordAuth=%s\nsystem.sys0=system\nsystem.sys0.ttylogin=%s\n' "$v" "$v" "$t" > "$S/uci"
}
# run [LKS]: S13 start()
run(){
	env -i PATH="$B:/usr/bin:/bin" UCI_DB="$S/uci" PROV_SHADOW="$S/etc/shadow" PROV_STATE="$S/state" \
		PROV_LOCK_TEST_P5="$S/p5" PROV_LOCK_TEST_PROVD="$S/provd" PROV_LOCK_TEST_LIB="$LIB" PROV_LOCK_TEST_LKS="${1:--}" \
		timeout 20 busybox sh -c ". '$INIT'; start" </dev/null >/dev/null 2>&1
	RC=$?
}
root(){ grep '^root:' "$S/etc/shadow" | cut -d: -f2; }
locked(){ grep -q '^dropbear.main.PasswordAuth=off$' "$S/uci" && grep -q '^system.sys0.ttylogin=1$' "$S/uci"; }
expect(){ local n=$1; cases=$((cases + 1)); if eval "$2"; then ok "$n"; else no "$n — rc=$RC root=[$(root)] uci=[$(tr '\n' ' ' < "$S/uci")] log=[$(cat "$S/uci.log" 2>/dev/null | tr '\n' ' ')]"; fi; }

mk claimed same "root:$H5:19000:0:99999:7:::" "" 0; run
expect "claimed, same identity, empty live root: locked, root = p5 hash" 'locked && [ "$(root)" = "$H5" ] && [ "$RC" = 0 ]'
expect "S13 never calls ubus (--no-reload)" '[ ! -s "$S/uci.ubus" ]'
mk claimed same "root:$H5:19000:0:99999:7:::" "$HL" 1; run
expect "claimed, live has another hash: root converges to p5" '[ "$(root)" = "$H5" ]'
mk member same "root:$H5:19000:0:99999:7:::" "" 0; run
expect "member: locked + converged" 'locked && [ "$(root)" = "$H5" ]'
mk claimed diff "root:$H5:19000:0:99999:7:::" "" 0; run
expect "identity differs: locked, NOT converged (empty -> !)" 'locked && [ "$(root)" = "!" ]'
mk claimed same "root:plaintext:1" "" 0; run
expect "invalid shadow-root: locked, not converged" 'locked && [ "$(root)" = "!" ]'
mk claimed same - "$HL" 0; run
expect "no shadow-root on p5: locked, live hash kept" 'locked && [ "$(root)" = "$HL" ]'
mk unclaimed same "root:$H5:19000:0:99999:7:::" "" 0; run claimed
expect "p5 unclaimed + p6 claimed (any): locked, NOT converged (a previous owner's shadow-root)" 'locked && [ "$(root)" = "!" ]'
mk unclaimed same "root:$H5:19000:0:99999:7:::" "" 0; run -
expect "p5 unclaimed + p6 none: untouched" '! locked && [ -z "$(root)" ]'
mk legacy same "root:$H5:19000:0:99999:7:::" "$HL" 0; run legacy
expect "legacy: untouched (dev / operator nodes keep today's rules)" '! locked && [ "$(root)" = "$HL" ]'
mk bad same - "" 0; run
expect "p5 meta bad: locked (fail-secure)" 'locked && [ "$(root)" = "!" ]'
mk absent same - "" 0; run claimed
expect "p5 unreadable + p6 claimed: locked" 'locked && [ "$(root)" = "!" ]'
mk absent same - "" 0; run -
expect "p5 unreadable + p6 none: untouched" '! locked'
mk claimed same "root:$H5:19000:0:99999:7:::" "$H5" 1; : > "$S/uci.commits"; run
expect "already locked and converged: nothing written (idempotent)" '[ ! -s "$S/uci.commits" ] && [ "$(root)" = "$H5" ]'
# v8 (§5.3): S13 converges every hash musl can verify ($1$ / $5$ too: busybox passwd defaults to $5$) and only those
P55='$5$p5p5p5p5p5p5p5p5$'"$(printf '5%.0s' $(seq 43))"; P51='$1$p5p5p5p5$'"$(printf '1%.0s' $(seq 22))"
mk claimed same "root:$P55:19000:0:99999:7:::" "$HL" 1; run
expect "p5 \$5\$ (busybox passwd default): converged" 'locked && [ "$(root)" = "$P55" ]'
mk claimed same "root:$P51:19000:0:99999:7:::" "$HL" 1; run
expect "p5 \$1\$ (passwd -a md5): converged" 'locked && [ "$(root)" = "$P51" ]'
mk claimed same "root:\$6\$short\$abc:19000:0:99999:7:::" "" 0; run
expect "p5 malformed \$6\$ (wrong hash length): locked, NOT converged" 'locked && [ "$(root)" = "!" ]'
mk claimed same "root:\$6\$rounds=999\$salt\$$(printf 'c%.0s' $(seq 86)):19000:0:99999:7:::" "$HL" 1; run
expect "p5 rounds=999 (musl rewrites it: never verifies): NOT converged" 'locked && [ "$(root)" = "$HL" ]'

[ "$cases" -ge 14 ] || no "only $cases cases ran"
echo "prov-lock-init: $cases cases, $fails failed"
[ "$fails" = 0 ]
