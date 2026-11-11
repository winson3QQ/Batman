# shellcheck shell=bash
# scripts/dv/s5-254.sh — the #254 P3 S5 read-only node checks, sourced by daily-validation.sh (tier A, every run, every
# fleet node; nothing on the node is changed except the p5 verdict file precheck-node rewrites, see fw-boot-254.sh):
#   chk_fw_boot_254 <node...>      prov-fw-boot-254 (254-p3-impl §3.8.1 (2), §3.8.2, §3.7.3; 254-h4 §8.3 / A.12):
#                                  scripts/node/fw-boot-254.sh with the slot-lock lib prepended
#   chk_release_key_254 <node...>  release-key-254 (254-p3-impl §3.7.1-2, review B-M6): the image trusts the test root T
#                                  (/rom/usr/share/batman/release-root.pub = tests/keys/T.pub) exactly when its stamp
#                                  says bench (/rom/etc/batman-build BATMAN_BENCH_TRUST=T, firmware
#                                  scripts/stamp-batman-build.sh --bench T; the version then carries ".bench"). T's
#                                  private key is derivable by anyone (tests/keys/README.md): a non-bench image that
#                                  trusts T accepts any update. No key file = "trusts none" (wsl / ci builds).
# Verdicts: any FAIL -> rc 1; else any INVALID (a node that cannot be judged: pre-S5 image, lock busy) -> SKIP-REASON +
# rc 3 (daily-validation reports it as SKIP, as loudly as a FAIL, and the run cannot exit 0); all PASS -> rc 0; no node or
# a node that printed no verdict -> FAIL (never an empty PASS).
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
# rk_judge <node> <the node's "RK ..." line> <T.pub hex>: one PASS / FAIL line; rc 0 / 1
rk_judge(){
	local n=$1 l=$2 t=$3 pub bench ver stamp u=release-key-254
	[[ $t =~ ^04[0-9a-f]{128}$ ]] || { echo "FAIL $u: $n: the harness's tests/keys/T.pub is not one P-256 point [$t]"; return 1; }
	case "$l" in "RK "*) ;; *) echo "FAIL $u: $n: no answer [$l]"; return 1 ;; esac
	pub=$(s5_field "$l" pub); bench=$(s5_field "$l" bench); ver=$(s5_field "$l" ver); stamp=$(s5_field "$l" stamp)
	[ "$stamp" = rom ] || { echo "FAIL $u: $n: no image stamp /rom/etc/batman-build"; return 1; }
	case "$bench" in -) ;; T) ;; *) echo "FAIL $u: $n ($ver): BATMAN_BENCH_TRUST=[$bench] — the stamp knows only T"; return 1 ;; esac
	if [ "$pub" = "$t" ]; then
		[ "$bench" = T ] || { echo "FAIL $u: $n ($ver): the image trusts the TEST root T but its stamp is not a bench build (no BATMAN_BENCH_TRUST=T): anyone can sign an update it accepts"; return 1; }
		case "$ver" in *.bench*) ;; *) echo "FAIL $u: $n ($ver): a bench stamp whose version lacks .bench"; return 1 ;; esac
		echo "PASS $u: $n ($ver): bench build, trusts T, stamp BATMAN_BENCH_TRUST=T"; return 0
	fi
	[ "$bench" = T ] && { echo "FAIL $u: $n ($ver): the stamp says bench (BATMAN_BENCH_TRUST=T) but the image does not trust T (release-root.pub=[${pub:0:20}…])"; return 1; }
	case "$pub" in
		-) echo "PASS $u: $n ($ver): trusts none (no release-root.pub; not a bench build)" ;;
		04*) echo "PASS $u: $n ($ver): trusts a root that is not T (${pub:0:20}…), not a bench build" ;;
		*) echo "FAIL $u: $n ($ver): release-root.pub is not a P-256 point [${pub:0:40}]"; return 1 ;;
	esac; return 0; }
# the node's facts, one line; values never contain spaces ("-" = absent)
RK_Q='p=/rom/usr/share/batman/release-root.pub; s=/rom/etc/batman-build; k=$(head -c 300 $p 2>/dev/null | head -1 | tr -d " \r"); [ -f $p ] || k=-; [ -n "$k" ] || k=empty
b=$(sed -n "s/^BATMAN_BENCH_TRUST=//p" $s 2>/dev/null | head -1 | tr -d " "); echo "RK ver=$(sed -n "s/^BATMAN_VERSION=//p" $s 2>/dev/null | head -1) bench=${b:--} pub=$k stamp=$([ -f $s ] && echo rom || echo none)"'
chk_release_key_254(){
	local n l t nf=0 c=0
	t=$(tr -d '\r\n' < "$REPO/tests/keys/T.pub" 2>/dev/null)
	for n in "$@"; do
		c=$((c + 1)); l=$(s5_ssh "$n" 30 "$RK_Q" 2>/dev/null | grep '^RK ' | tail -1); echo "$n: $l"
		rk_judge "$n" "$l" "$t" || nf=$((nf + 1))
	done
	s5_sum release-key-254 "$nf" 0 "$c"; }
