#!/bin/bash
# scripts/dv/prov-status-diag-254.sh — #254 H4 appendix A.5, the helper-level parts (p3-how "h"):
#   SD1  status.get (scope 0) agrees with the node: state = the helper's record, neighbours = meshjoin's batman count
#        on wlh0, p5_saved = `batman-config-save --check` rc 0; the member role's view (SD2) is provd's: by hand
#   SD4  diag.bundle -> a handle; diag.read follows it to the end: > 64 KiB in total, the bytes are a tar (`tar t` on
#        the host lists /etc/config entries), and the AP passphrase / mesh key are NOT in it (grep of the real values,
#        on the node, against the bytes the node handed out - the values never leave the node); chunked retrieval
#        through provd (> 64 KiB over one provd reply) is provd's part: by hand
# SD3 (ro connection rate through provd) and SD5 (handles across sessions) are provd's: p3-manual-rows.md.
#   SD6  whole-team status (254-app-team-status v2.1 §10.3, the regular-suite row), on a meshed member: an image whose
#        BATMAN_FEATURES lack whole-team-status(#254), whose version is on pre-team-status-versions.txt and whose answer
#        has neither key 8 nor key 9 FAILs with ONE line (the only known-failure line); otherwise
#        status.get (full) must give key 8 = this node's own wlh0 MAC, key 9 well formed (§4.1, provclient "bad"
#        otherwise) holding PEERMAC (the other node's wlh0 = morse phy MAC, design §9.2 C2) seen <= 30 s ago, within
#        4 reads 15 s apart (sampling every 15 s), and the answer <= 8112 B (provd's Noise plaintext limit 8176,
#        provd/session.go maxPlain, minus 64 B for the reply envelope). "Both nodes see each other": one run
#        reads status on 04 (sees PEERMAC) and on 02 (sees 04, provclient placed there for that read). The judgment is sd6_judge (offline
#        cases: tests/judges/sd6-judge.sh).
# W (pre-P3 image): status.get / diag.summary / diag.read are unknown (20) -> the rows FAIL with the code they got.
# Type: R. Side effects: none beyond the unit's snapshot and restore (one reboot).
set -u
PR_UNIT=prov-status-diag-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 1200 || { pr_result; exit 1; }
pr_h0 && pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
f(){ sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<< "$1" | head -1; }
# ---- SD1 status.get vs the node
# the node's own view: --check's rc taken right after it (a $? inside the echo was the last $(sed)'s, always 0), and a
# leading space so f() (" key=") finds state= (2026-11-13: SD1 read the record as [] since it first ran)
n=$(qr '. /usr/lib/batman/meshjoin.sh; meshjoin_sample; batman-config-save --check >/dev/null 2>&1; c=$?; echo " state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) bat=$MJ_BAT plink=$MJ_PLINK check_rc=$c"')
say "SD1 node: $n"
r=$(pr_pc h0.pem -- status-get "$H0" full | grep '^RESULT status.get'); say "SD1: $(cut -c1-200 <<< "$r")"
# key 4 (p5_saved) is left out of the first answer while p5 is refreshed in the background (node/status.go:181-202,
# by design): read again once
if [ "$(code "$r")" = 0 ] && [ "$(f "$r" p5_saved)" = "<nil>" ]; then sleep 3; r=$(pr_pc h0.pem -- status-get "$H0" full | grep '^RESULT status.get'); say "SD1 (again, key 4): $(cut -c1-200 <<< "$r")"; fi
if [ "$(code "$r")" = 0 ]; then
	[ "$(f "$r" state)" = "$(f "$n" state)" ] && ok "SD1: state $(f "$r" state) = the record" || no "SD1: state [$(f "$r" state)] vs the record [$(f "$n" state)]"
	[ "$(f "$r" neighbours)" = "$(f "$n" bat)" ] && ok "SD1: neighbours $(f "$r" neighbours) = batman neighbours on wlh0" || no "SD1: neighbours [$(f "$r" neighbours)] vs meshjoin bat [$(f "$n" bat)]"
	want=false; [ "$(f "$n" check_rc)" = 0 ] && want=true
	[ "$(f "$r" p5_saved)" = "$want" ] && ok "SD1: p5_saved $want = --check rc $(f "$n" check_rc)" || no "SD1: p5_saved [$(f "$r" p5_saved)] vs --check rc $(f "$n" check_rc)"
else no "SD1: status.get code $(code "$r") (want 0): [$r]"; fi
# ---- SD6 whole-team status
# sd6_judge <RESULT line> <BATMAN_FEATURES> <BATMAN_VERSION> <this node's wlh0 MAC> <the peer's wlh0 MAC>: PASS / FAIL
# lines only, no node calls. The version list is SD6_PRE (default scripts/dv/pre-team-status-versions.txt).
sd6_judge(){
	local r=$1 feat=$2 ver=$3 self=${4,,} peer=${5,,} p s b ago="" e list=${SD6_PRE:-$REPO/scripts/dv/pre-team-status-versions.txt}
	case ",$feat," in *",whole-team-status(#254),"*) ;; *)
		# "without whole-team status" is said only of a listed version, a readable stamp, a code-0 answer with
		# neither key 8 nor key 9 (review r2 A-M2 / B-M1, the pre-p3-versions rule); anything else is judged below
		s=$(f "$r" self); p=$(f "$r" peers)
		if [ -n "$feat" ] && grep -qxF -- "$ver" "$list" 2>/dev/null && [ "$(code "$r")" = 0 ] && [ "$s" = - ] && [ "$p" = - ]; then
			no "SD6: image without whole-team status ($ver)"; return
		fi
		[ "$(code "$r")" = 0 ] && { [ "$s" != - ] || [ "$p" != - ]; } \
			&& no "SD6: keys 8 / 9 present but BATMAN_FEATURES lack whole-team-status(#254) — the feature list (firmware batman-release.env) is wrong" ;;
	esac
	[ "$(code "$r")" = 0 ] || { no "SD6: status.get code $(code "$r") (want 0): [$(cut -c1-120 <<< "$r")]"; return; }
	s=$(f "$r" self); p=$(f "$r" peers); b=$(f "$r" bytes)
	[ "${s,,}" = "$self" ] && ok "SD6: key 8 = this node's wlh0 MAC $self" || no "SD6: key 8 [$s] is not this node's wlh0 MAC $self"
	case "$p" in
		""|-) no "SD6: key 9 absent (no fresh peer sample, withheld, or an image without whole-team status that is not listed)" ;;
		bad) no "SD6: key 9 breaks §4.1 (provclient: bad) — the app would drop it" ;;
		none) no "SD6: key 9 empty: $peer not seen" ;;
		*)	for e in ${p//,/ }; do [ "${e%/*}" = "$peer" ] && ago=${e#*/}; done
			if [ -z "$ago" ]; then no "SD6: key 9 [$p] lacks $peer"
			elif [ "$ago" -le 30 ]; then ok "SD6: key 9 lists $peer, seen ${ago} s ago"
			else no "SD6: key 9 lists $peer but seen ${ago} s ago (want <= 30: a stale entry, not a live neighbour)"; fi ;;
	esac
	[ -n "$b" ] && [ "$b" -le 8112 ] && ok "SD6: status answer $b B <= 8112" || no "SD6: status answer [$b] B (want <= 8112)"
}
# sd6_read <the peer's wlh0 MAC>: on $NODE, status.get up to 4 times 15 s apart until the peer is in key 9 (a feature
# image only; no sleep after the last); prints the RESULT line
sd6_read(){ local r="" i feat=$SD6_FEAT
	for i in 1 2 3 4; do
		r=$(pr_pc h0.pem -- status-get "$H0" full | grep '^RESULT status.get')
		case ",$feat,|$(f "$r" peers)," in *",whole-team-status(#254),|"*"${1,,}/"*) break ;; *",whole-team-status(#254),|"*) ;; *) break ;; esac
		[ $i = 4 ] || sleep 15
	done; printf '%s\n' "$r"; }
# both directions of §10.3's "the two see each other" (review r2 A-M1): $NODE sees PEERMAC, then $PEER sees $NODE —
# provclient placed on $PEER for this read only (its own $PCD, removed right after; tmpfs, gone at a reboot anyway)
if nb02; then
	me=$(qr 'cat /sys/class/net/wlh0/address')
	SD6_FEAT=$(qr "sed -n 's/^BATMAN_FEATURES=//p' /etc/batman-build"); v=$(qr "sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build")
	r=$(sd6_read "$PEERMAC"); say "SD6 ($NODE sees $PEERMAC): $(cut -c1-240 <<< "$r")"
	sd6_judge "$r" "$SD6_FEAT" "$v" "$me" "$PEERMAC"
	if [ -n "$me" ]; then
		SD6_FEAT=$(qp "sed -n 's/^BATMAN_FEATURES=//p' /etc/batman-build"); v=$(qp "sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build")
		r=$( NODE=$PEER; pr_pc_place >&2 && sd6_read "$me"; q "rm -rf $PCD" >/dev/null )
		say "SD6 ($PEER sees $me): $(cut -c1-240 <<< "$r")"
		sd6_judge "$r" "$SD6_FEAT" "$v" "$PEERMAC" "$me"
		[ -z "$(qp "ls -d $PCD 2>/dev/null")" ] && ok "SD6: provclient removed from $PEER" || no "SD6: $PCD left on $PEER"
	else no "SD6: this node's wlh0 MAC unreadable: the reverse direction cannot be judged"; fi
else no "SD6: the other node ($PEERMAC) is not a mesh neighbour of $NODE: the team row cannot be judged"; fi
# ---- SD4 the bundle
r=$(pr_pc h0.pem -- diag-bundle "$H0" | grep '^RESULT diag.bundle'); say "SD4: $r"
H=$(f "$r" handle)
if [ "$(code "$r")" = 0 ] && [ -n "$H" ]; then
	ok "SD4: diag.bundle code 0, handle $H"
	# the bytes stay on the node: provclient (uid 471 after its drop) writes them into $PCD/out (471:471 0700, tmpfs)
	q "mkdir -m 0700 $PCD/out && chown 471:471 $PCD/out" >/dev/null
	r2=$(pr_pc h0.pem PROVCLIENT_TIMEOUT_S=300 -- diag-read "$H0" "$H" "$PCD/out/diag.bin" | grep '^RESULT diag.read'); say "SD4: $r2"
	tot=$(f "$r2" total); got=$(f "$r2" bytes)
	[ "$(code "$r2")" = 0 ] && [ "${got:-0}" -gt 65536 ] && [ "$got" = "$tot" ] && ok "SD4: read to the end, $got bytes (> 64 KiB)" || no "SD4: diag.read code $(code "$r2") total [$tot] bytes [$got] (want code 0, bytes = total > 65536)"
	x=$(qr "f=$PCD/out/diag.bin; [ -s \"\$f\" ] || { echo nofile; exit 0; }; echo \"tar=\$(tar -tf \"\$f\" 2>/dev/null | grep -c '^etc/config/')\"; k=\$(uci -q get wireless.default_radio0.key); m=\$(uci -q get wireless.default_radio1.key); echo \"ap_in=\$([ -n \"\$k\" ] && grep -cF -- \"\$k\" \"\$f\") mesh_in=\$([ -n \"\$m\" ] && grep -cF -- \"\$m\" \"\$f\")\"; rm -f \"\$f\"")
	say "SD4: $(echo $x)"
	case "$(echo $x)" in nofile) inv "SD4: no bundle file to inspect ($PCD/out/diag.bin empty or missing)";;
		*) [ "$(f "$x" tar)" -ge 1 ] 2>/dev/null && ok "SD4: the bytes are a tar with /etc/config entries ($(f "$x" tar))" || no "SD4: not a tar with /etc/config entries: $(echo $x)"
		   [ "$(f "$x" ap_in)" = 0 ] && [ "$(f "$x" mesh_in)" = 0 ] && ok "SD4: neither the AP passphrase nor the mesh key is in the bundle" || no "SD4: a secret is in the bundle: $(echo $x)";; esac
else no "SD4: diag.bundle code $(code "$r") handle [$H] (want 0 + a handle): [$r]"; fi
pr_end
pr_result
