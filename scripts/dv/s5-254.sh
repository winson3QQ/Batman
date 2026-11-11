# shellcheck shell=bash
# scripts/dv/s5-254.sh — the #254 P3 S5 read-only node checks, sourced by daily-validation.sh (tier A, every run, every
# fleet node; nothing on the node is changed except what fw-boot-254.sh lists under "Side effects": the p5 verdict file
# precheck-node rewrites, B's boot FAT mounted read-only for the length of `bootinfo B`, the harness's pid file):
#   chk_fw_boot_254 <node...>      prov-fw-boot-254 (254-p3-impl §3.8.1 (2), §3.8.2, §3.7.3; 254-h4 §8.3 / A.12):
#                                  scripts/node/fw-boot-254.sh with the slot-lock lib prepended
#   chk_release_key_254 <node...>  release-key-254 (254-p3-impl §3.7.1-2, review B-M6): the image trusts the test root T
#                                  exactly when its stamp says bench (/rom/etc/batman-build BATMAN_BENCH_TRUST=T, firmware
#                                  scripts/stamp-batman-build.sh --bench T; the version then carries ".bench"). T's
#                                  private key is derivable by anyone (tests/keys/README.md): a non-bench image that
#                                  trusts T accepts any update. What the image trusts is read the way the helper reads it
#                                  (release.LoadTrust, feed/batman-prov/src/release/release.go:84-125; review r2 A-m2 /
#                                  B-m10): /rom/usr/share/batman/release-root.pub AND release-min-serial, each a regular
#                                  file of one line (<= 256 bytes, at most one trailing newline) — both absent = trusts
#                                  none (wsl / ci builds); both well-formed (a 04 + 128 hex point, a serial 1-9 digits
#                                  without a leading 0) = trusts that point; anything else (one file only, two lines, a
#                                  bad value) = "bad": FAIL. The helper's own on-curve test is not repeated here; the
#                                  status key 15 cross-check (rk_judge's 4th argument, prov-update-254) covers it.
# Verdicts: any FAIL -> rc 1; else any INVALID (a node that cannot be judged: lock busy, a verb that stopped before the
# lock) -> SKIP-REASON + rc 3 (daily-validation reports it as SKIP, as loudly as a FAIL, and the run cannot exit 0); all
# PASS -> rc 0; no node or a node that printed no verdict -> FAIL (never an empty PASS). A pre-S5 node is a FAIL line
# "pre-S5 image <ver>" with a KNOWN entry that expires (scripts/validation-known-failures.txt; review r2 B-MAJOR-1).
S5_SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8)
s5_ssh(){ local n=$1 t=$2; shift 2; timeout "$t" ssh "${S5_SSHO[@]}" "root@$n" "$@" | tr -d '\r'; }
s5_field(){ printf ' %s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p" | head -1; }   # key=value of a line
# s5_sum <unit> <fails> <invalids> <checked>: the suite's exit status from the per-node verdicts
s5_sum(){
	[ "$4" -gt 0 ] || { echo "FAIL $1: no node checked"; return 1; }
	[ "$2" -gt 0 ] && return 1
	[ "$3" -gt 0 ] && { echo "SKIP-REASON: $1: $3 node(s) INVALID (not judged, see the INVALID lines)"; return 3; }
	return 0; }
chk_fw_boot_254(){
	local n o nf=0 ni=0 c=0
	for n in "$@"; do
		c=$((c + 1))
		o=$(cat "$REPO/scripts/node/slotlock-lib-254.sh" "$REPO/scripts/node/fw-boot-254.sh" | s5_ssh "$n" 300 sh -s 2>&1)
		echo "$o" | sed -E "s/^(PASS|FAIL|INVALID|INFO|RESULT) /\1 $n: /"
		case "$(grep '^RESULT prov-fw-boot-254 ' <<< "$o" | tail -1)" in
			"RESULT prov-fw-boot-254 PASS") grep -q '^FAIL' <<< "$o" && nf=$((nf + 1)) ;;
			"RESULT prov-fw-boot-254 INVALID") grep -q '^FAIL' <<< "$o" && nf=$((nf + 1)) || ni=$((ni + 1)) ;;
			"RESULT prov-fw-boot-254 FAIL") nf=$((nf + 1)) ;;
			*) echo "FAIL prov-fw-boot-254: $n: no verdict (unreachable, or the script died): $(tail -1 <<< "$o")"; nf=$((nf + 1)) ;;
		esac
	done
	s5_sum prov-fw-boot-254 "$nf" "$ni" "$c"; }
# rk_fpr <point hex>: release.Fingerprint as status key 15 prints it (sha256 of the 65-byte point, first 8 bytes, hex)
rk_fpr(){ printf "$(sed 's/../\\x&/g' <<< "$1")" | sha256sum | cut -c1-16; }
# rk_judge <node> <the node's "RK ..." line> <T.pub hex> [<status key 15 trust>]: one PASS / FAIL line; rc 0 / 1
rk_judge(){
	local n=$1 l=$2 t=$3 st=${4:-} pub ser bench ver stamp st_want u=release-key-254
	[[ $t =~ ^04[0-9a-f]{128}$ ]] || { echo "FAIL $u: $n: the harness's tests/keys/T.pub is not one P-256 point [$t]"; return 1; }
	case "$l" in "RK "*) ;; *) echo "FAIL $u: $n: no answer [$l]"; return 1 ;; esac
	pub=$(s5_field "$l" pub); ser=$(s5_field "$l" ser); bench=$(s5_field "$l" bench); ver=$(s5_field "$l" ver); stamp=$(s5_field "$l" stamp)
	[ "$stamp" = rom ] || { echo "FAIL $u: $n: no image stamp /rom/etc/batman-build"; return 1; }
	[ -n "$pub" ] && [ -n "$ser" ] || { echo "FAIL $u: $n: the answer lacks pub= / ser= [$l]"; return 1; }
	case "$bench" in -) ;; T) ;; *) echo "FAIL $u: $n ($ver): BATMAN_BENCH_TRUST=[$bench] — the stamp knows only T"; return 1 ;; esac
	# what the helper trusts (LoadTrust): none / the point / bad
	if [ "$pub" = - ] && [ "$ser" = - ]; then pub=none
	elif ! [[ $pub =~ ^04[0-9a-f]{128}$ && $ser =~ ^[1-9][0-9]{0,9}$ ]]; then
		echo "FAIL $u: $n ($ver): the image's release key files are bad for the helper (LoadTrust: both or neither, one line each, a point and a serial): release-root.pub=[${pub:0:24}] release-min-serial=[${ser:0:12}] — it trusts no root and refuses every update (state bad)"; return 1
	fi
	if [ -n "$st" ]; then
		if [ "$pub" = none ]; then st_want=none; else st_want=$(rk_fpr "$pub"); fi
		[ "$st" = "$st_want" ] || { echo "FAIL $u: $n ($ver): the helper's status key 15 trust=[$st] but /rom gives [$st_want] — the files and the helper disagree"; return 1; }
	fi
	if [ "$pub" = "$t" ]; then
		[ "$bench" = T ] || { echo "FAIL $u: $n ($ver): the image trusts the TEST root T but its stamp is not a bench build (no BATMAN_BENCH_TRUST=T): anyone can sign an update it accepts"; return 1; }
		case "$ver" in *.bench*) ;; *) echo "FAIL $u: $n ($ver): a bench stamp whose version lacks .bench"; return 1 ;; esac
		echo "PASS $u: $n ($ver): bench build, trusts T (min serial $ser), stamp BATMAN_BENCH_TRUST=T${st:+, status trust=$st agrees}"; return 0
	fi
	[ "$bench" = T ] && { echo "FAIL $u: $n ($ver): the stamp says bench (BATMAN_BENCH_TRUST=T) but the image does not trust T (release-root.pub=[${pub:0:20}…])"; return 1; }
	case "$pub" in
		none) echo "PASS $u: $n ($ver): trusts none (no release-root.pub, no release-min-serial; not a bench build)${st:+, status trust=$st agrees}" ;;
		*) echo "PASS $u: $n ($ver): trusts a root that is not T (${pub:0:20}…, min serial $ser), not a bench build${st:+, status trust=$st agrees}" ;;
	esac; return 0; }
# the node's facts, one line; values never contain spaces ("-" = absent). Each key file as the helper reads it:
# "-" absent, "notreg" not a regular file, "long" > 256 bytes, "lines" more than one line, "empty", else the line
# (blanks / CR shown as "_", so they never pass the judge's patterns)
RK_Q='d=/rom/usr/share/batman; s=/rom/etc/batman-build
kf(){ f=$d/$1; if [ ! -e "$f" ]; then echo -; elif [ ! -f "$f" ]; then echo notreg; elif [ "$(wc -c < "$f")" -gt 256 ]; then echo long
elif [ "$(tr -cd "\n" < "$f" | wc -c)" -gt 1 ] || { [ "$(tr -cd "\n" < "$f" | wc -c)" = 1 ] && [ -n "$(tail -c 1 "$f")" ]; }; then echo lines
else v=$(tr -d "\n" < "$f" | tr " \r\t" "___"); echo "${v:-empty}"; fi; }
b=$(sed -n "s/^BATMAN_BENCH_TRUST=//p" $s 2>/dev/null | head -1 | tr -d " "); echo "RK ver=$(sed -n "s/^BATMAN_VERSION=//p" $s 2>/dev/null | head -1) bench=${b:--} pub=$(kf release-root.pub) ser=$(kf release-min-serial) stamp=$([ -f $s ] && echo rom || echo none)"'
chk_release_key_254(){
	local n l t nf=0 c=0
	t=$(tr -d '\r\n' < "$REPO/tests/keys/T.pub" 2>/dev/null)
	for n in "$@"; do
		c=$((c + 1)); l=$(s5_ssh "$n" 30 "$RK_Q" 2>/dev/null | grep '^RK ' | tail -1); echo "$n: $l"
		rk_judge "$n" "$l" "$t" || nf=$((nf + 1))
	done
	s5_sum release-key-254 "$nf" 0 "$c"; }
