#!/bin/bash
# scripts/test-tmp-trust.sh — mutation proof for scripts/check-tmp-trust.sh (#280 D6/N4): the check must pass
# on the tree as committed, and FAIL on every bypass form — one mutation each, applied to a throw-away copy.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
P=0; F=0
tok(){ echo "ok   $1"; P=$((P+1)); }
tbad(){ echo "FAIL $1"; F=$((F+1)); }
fresh(){ rm -rf "$W/r"; mkdir -p "$W/r"
	( cd "$REPO" && git ls-files -co --exclude-standard -z ) | ( cd "$REPO" && xargs -0 cp --parents -t "$W/r" ) 2>/dev/null
	( cd "$W/r" && git init -q && git add -A >/dev/null 2>&1 ); }
check(){ CHECK_TMP_TRUST_ROOT="$W/r" bash "$REPO/scripts/check-tmp-trust.sh" >"$W/out" 2>&1; }
# $1 name, $2 file (repo-relative), $3 line appended to it
mut(){ fresh; printf '%s\n' "$3" >> "$W/r/$2"; ( cd "$W/r" && git add -A >/dev/null 2>&1 )
	if check; then tbad "mutation not caught: $1"; else grep -q "UNTRUSTED $2:" "$W/out" && tok "caught: $1" || tbad "failed but not on $2: $1"; fi; }

fresh; check && tok "clean tree passes" || { tbad "clean tree fails"; sed -n '1,20p' "$W/out"; }
A=feed/batman-provision/files/usr/bin/batman-autocommit
mut "a decision marker back in /tmp"            $A 'DECIDED=/tmp/autocommit.decided'
mut "a \${X:-/tmp} default"                     feed/batman-provision/files/usr/bin/payload-run 'RUNDIR="${PAYLOAD_RUNDIR:-/tmp}"'
mut "a \$\$ temp name"                           feed/batman-provision/files/usr/sbin/batman-slot 'MBR_FILE=$RUNDIR/batman-slot.mbr.$$'
mut "mkdir -p of a predictable /tmp dir"        feed/batman-provision/files/www/cgi-bin/bundle 'd=/tmp/report; mkdir -p "$d"'
mut "an operator flag without opf"              feed/batman-provision/files/usr/bin/joinwatch 'elif [ -f /tmp/batman-autocommit.hold ] && [ -O /tmp/batman-autocommit.hold ]; then :; fi'
mut "the run dir spelled through /var (B1)"     feed/batman-provision/files/usr/lib/batman/platform-ab.sh 'dev=$(cat /var/run/batman/batdata.dev)'
mut "the run dir literal outside rundir.sh"     feed/batman-provision/files/usr/bin/halow-status 'R=/tmp/run/batman'
mut "/dev/shm"                                  feed/batman-provision/files/usr/bin/batpower 'MOCK=/dev/shm/batpower.mock'
mut "/var/lock"                                 feed/batman-provision/files/usr/bin/batpower 'L=/var/lock/batpower'
mut "harness: root runs a staged /tmp script"   scripts/daily-validation.sh '  fssh "$n" 10 "sh /tmp/x.sh"'
mut "node script: /tmp output"                  scripts/node/soak-node.sh 'echo 1 > /tmp/dv-x.cnt'
mut "a new node file under deploy/"             deploy/provisioning/new-tool.sh 'echo x > /tmp/new-tool.state'
# a waiver needs a reason
fresh; printf '%s\n' 'X=/tmp/y   # tmp-trust: ok' >> "$W/r/$A"; ( cd "$W/r" && git add -A >/dev/null 2>&1 )
check && tbad "reasonless waiver accepted" || { grep -q 'WAIVER WITHOUT REASON' "$W/out" && tok "reasonless waiver refused" || tbad "waiver failure not reported"; }
# comments are not code
fresh; printf '%s\n' '# a comment about /tmp/autocommit.decided is fine' >> "$W/r/$A"; ( cd "$W/r" && git add -A >/dev/null 2>&1 )
check && tok "a comment mentioning /tmp is not flagged" || tbad "comment flagged"

echo "================ test-tmp-trust: $P passed, $F failed ================"
[ "$F" = 0 ]
