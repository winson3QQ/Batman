#!/bin/bash
# tests/prov-p1/prov-root-hash.sh <prov-lock.sh> — #254 claim-lock fix §5.3 v8 / §11.2: prov_root_hash_ok accepts exactly
# the root fields musl crypt() can verify a password against ($1$ / $5$ / $6$ with musl's limits, crypt_md5.c:183,
# crypt_sha256.c:182-186, crypt_sha512.c:203-207, 240-277) and nothing else. Runs under busybox ash. Vectors: every
# rule in both directions + 3 x 40 openssl-generated hashes; each rule also has a one-line mutant of the function that
# must make at least one vector FAIL (the vectors really discriminate). A run that executes zero cases FAILs.
set -u
LIB=$(readlink -f "${1:?usage: $0 <prov-lock.sh>}"); [ -f "$LIB" ] || { echo "FAIL missing $LIB"; exit 1; }
command -v busybox >/dev/null || { echo "FAIL busybox missing"; exit 1; }
command -v openssl >/dev/null || { echo "FAIL openssl missing (cross-check cannot run)"; exit 1; }
busybox sh -c '. "$1"; type prov_root_hash_ok >/dev/null 2>&1' _ "$LIB" || { echo "FAIL prov_root_hash_ok() missing from $LIB (pre-v8 product)"; echo "PROV-ROOT-HASH cases=0 fails=1"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H22=$(printf 'a%.0s' $(seq 22)); H43=$(printf 'b%.0s' $(seq 43)); H86=$(printf 'c%.0s' $(seq 86))
S8=abcdefgh; S16=abcdefghijklmnop
{
	# accepted (A) / rejected (R): one per line, "<A|R> <field>"
	echo "A \$1\$$S8\$$H22"
	echo "A \$1\$\$$H22"
	echo "A \$5\$$S16\$$H43"
	echo "A \$6\$$S16\$$H86"
	echo "A \$6\$\$$H86"
	echo "A \$6\$rounds=1000\$salt\$$H86"
	echo "A \$6\$rounds=9999999\$salt\$$H86"
	echo "A \$5\$rounds=5000\$salt\$$H43"
	echo "A \$6\$s.l/t\$$H86"
	echo "A \$6\$s=lt\$$H86"
	echo "R \$1\$${S8}x\$$H22"
	echo "R \$5\$${S16}x\$$H43"
	echo "R \$6\$${S16}x\$$H86"
	echo "R \$1\$salt\$${H22}x"
	echo "R \$1\$salt\$${H22%a}"
	echo "R \$5\$salt\$${H43%b}"
	echo "R \$6\$salt\$${H86}c"
	echo "R \$6\$rounds=999\$salt\$$H86"
	echo "R \$6\$rounds=05000\$salt\$$H86"
	echo "R \$6\$rounds=10000000\$salt\$$H86"
	echo "R \$6\$rounds=\$salt\$$H86"
	echo "R \$6\$rounds=x\$salt\$$H86"
	echo "A \$6\$rounds=5000\$rounds=5\$$H86"   # musl: after one rounds= the rest is salt (here "rounds=5")
	echo "R \$6\$rounds=5000\$rounds=5000\$salt\$$H86"   # salt "rounds=5000", then a hash part of the wrong length
	echo "R \$6\$rounds=5000"
	echo "R \$6\$salt"
	echo "R \$6\$salt\$${H86%c}!"
	echo "R \$6\$salt\$${H86%c}-"
	echo "R \$2b\$10\$$H43"
	echo "R \$7\$salt\$$H86"
	echo "R abcdefghijklm"
	echo "R !"
	echo "R !\$6\$salt\$$H86"
	echo "R \$6\$sa:lt\$$H86"
	echo "R \$6\$salt\$${H86%c}:"
} > "$T/vec"
printf 'R \n' >> "$T/vec"
# run <lib> -> "<A|R> <got A|R> <field>" lines
run(){ busybox sh -c '. "$1"; while IFS= read -r l; do w=${l%% *}; f=${l#? }; if prov_root_hash_ok "$f"; then g=A; else g=R; fi; echo "$w $g $f"; done < "$2"' _ "$1" "$T/vec"; }
cases=0; fails=0
while read -r w g f; do cases=$((cases + 1)); [ "$w" = "$g" ] && echo "PASS $w [$f]" || { echo "FAIL want $w got $g [$f]"; fails=$((fails + 1)); }; done < <(run "$LIB")
# a newline inside the field (cannot be a vector line)
nl=$(busybox sh -c '. "$1"; prov_root_hash_ok "$(printf "\$6\$salt\$%s\nx" "$2")" && echo A || echo R' _ "$LIB" "$H86")
cases=$((cases + 1)); [ "$nl" = R ] && echo "PASS R [newline in field]" || { echo "FAIL newline accepted"; fails=$((fails + 1)); }
# cross-check: openssl-generated (random password + salt) must all be accepted
: > "$T/x"; for a in 1 5 6; do for _ in $(seq 40); do openssl rand -base64 12 | openssl passwd -$a -stdin | sed 's/^/A /' >> "$T/x"; done; done
xn=$(busybox sh -c '. "$1"; n=0; while IFS= read -r l; do prov_root_hash_ok "${l#A }" || { echo "REJECTED ${l#A }" >&2; n=$((n + 1)); }; done < "$2"; echo $n' _ "$LIB" "$T/x")
cases=$((cases + 1)); [ "$xn" = 0 ] && echo "PASS openssl cross-check: 120/120 accepted" || { echo "FAIL openssl cross-check: $xn of 120 rejected"; fails=$((fails + 1)); }
# mutants: each removes one rule; the vectors must catch it
mut(){ local name=$1 from=$2 to=$3 n; cp "$LIB" "$T/m.sh"
	awk -v f="$from" -v t="$to" 'BEGIN{d=0} !d && index($0, f) { i = index($0, f); $0 = substr($0, 1, i - 1) t substr($0, i + length(f)); d=1 } { print } END { if (!d) exit 3 }' "$LIB" > "$T/m.sh" || { echo "FAIL mutant $name: anchor not found"; fails=$((fails + 1)); return; }
	n=$(run "$T/m.sh" | awk '$1 != $2' | wc -l); cases=$((cases + 1))
	[ "$n" -gt 0 ] && echo "PASS mutant $name caught ($n vectors)" || { echo "FAIL mutant $name NOT caught"; fails=$((fails + 1)); }; }
mut no-salt-max '[ "${#_rh_s}" -le "$_rh_sm" ] || return 1' ':'
mut no-hash-len '[ "${#_rh_x}" = "$_rh_hl" ] || return 1' ':'
mut no-hash-charset 'case "$_rh_x" in *[!./0-9A-Za-z]*) return 1 ;; esac' ':'
mut no-rounds-min '[ "${#_rh_n}" -le 7 ] && [ "$_rh_n" -ge 1000 ] || return 1' '[ "${#_rh_n}" -le 7 ] || return 1'
mut no-rounds-max '[ "${#_rh_n}" -le 7 ] && [ "$_rh_n" -ge 1000 ] || return 1' '[ "$_rh_n" -ge 1000 ] || return 1'
mut leading-zero "''|0*|*[!0-9]*) return 1" "''|*[!0-9]*) return 1"
mut no-colon 'case "$_rh" in *:*|*' 'case "$_rh" in *::::*|*'
mut unknown-prefix "'\$6\$'*) _rh_sm=16; _rh_hl=86 ;;" "'\$6\$'*|'\$7\$'*) _rh_sm=16; _rh_hl=86 ;;"
echo "PROV-ROOT-HASH cases=$cases fails=$fails"; [ "$cases" -gt 0 ] && [ "$fails" = 0 ]
