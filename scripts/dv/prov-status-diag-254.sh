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
#        BATMAN_FEATURES lack whole-team-status(#254) FAILs with ONE line (the only known-failure line); otherwise
#        status.get (full) must give key 8 = this node's own wlh0 MAC, key 9 well formed (§4.1, provclient "bad"
#        otherwise) holding PEERMAC (the other node's wlh0 = morse phy MAC, design §9.2 C2) seen <= 30 s ago, within
#        4 reads 15 s apart (sampling every 15 s), and the answer <= 8112 B (provd's Noise plaintext limit 8176,
#        provd/session.go maxPlain, minus 64 B for the reply envelope). "Both nodes see each other": the unit runs as 04
#        (PEERMAC = 02) and as 02 (PEERMAC = 04); one run judges one direction. The judgment is sd6_judge (offline
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
n=$(qr '. /usr/lib/batman/meshjoin.sh; meshjoin_sample; batman-config-save --check >/dev/null 2>&1; echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) bat=$MJ_BAT plink=$MJ_PLINK check_rc=$?"')
say "SD1 node: $n"
r=$(pr_pc h0.pem -- status-get "$H0" full | grep '^RESULT status.get'); say "SD1: $(cut -c1-200 <<< "$r")"
if [ "$(code "$r")" = 0 ]; then
	[ "$(f "$r" state)" = "$(f "$n" state)" ] && ok "SD1: state $(f "$r" state) = the record" || no "SD1: state [$(f "$r" state)] vs the record [$(f "$n" state)]"
	[ "$(f "$r" neighbours)" = "$(f "$n" bat)" ] && ok "SD1: neighbours $(f "$r" neighbours) = batman neighbours on wlh0" || no "SD1: neighbours [$(f "$r" neighbours)] vs meshjoin bat [$(f "$n" bat)]"
	want=false; [ "$(f "$n" check_rc)" = 0 ] && want=true
	[ "$(f "$r" p5_saved)" = "$want" ] && ok "SD1: p5_saved $want = --check rc $(f "$n" check_rc)" || no "SD1: p5_saved [$(f "$r" p5_saved)] vs --check rc $(f "$n" check_rc)"
else no "SD1: status.get code $(code "$r") (want 0): [$r]"; fi
# ---- SD6 whole-team status
# sd6_judge <RESULT line> <BATMAN_FEATURES> <this node's wlh0 MAC> <PEERMAC>: PASS / FAIL lines only, no node calls
sd6_judge(){
	local r=$1 feat=$2 self=${3,,} peer=${4,,} p s b ago="" e
	case ",$feat," in *",whole-team-status(#254),"*) ;; *) no "SD6: image without whole-team status (BATMAN_FEATURES has no whole-team-status(#254))"; return ;; esac
	[ "$(code "$r")" = 0 ] || { no "SD6: status.get code $(code "$r") (want 0): [$(cut -c1-120 <<< "$r")]"; return; }
	s=$(f "$r" self); p=$(f "$r" peers); b=$(f "$r" bytes)
	[ "${s,,}" = "$self" ] && ok "SD6: key 8 = this node's wlh0 MAC $self" || no "SD6: key 8 [$s] is not this node's wlh0 MAC $self"
	case "$p" in
		""|-) no "SD6: key 9 absent on a whole-team-status image (no fresh peer sample, or withheld)" ;;
		bad) no "SD6: key 9 breaks §4.1 (provclient: bad) — the app would drop it" ;;
		none) no "SD6: key 9 empty: $peer not seen" ;;
		*)	for e in ${p//,/ }; do [ "${e%/*}" = "$peer" ] && ago=${e#*/}; done
			if [ -z "$ago" ]; then no "SD6: key 9 [$p] lacks $peer"
			elif [ "$ago" -le 30 ]; then ok "SD6: key 9 lists $peer, seen ${ago} s ago"
			else no "SD6: key 9 lists $peer but seen ${ago} s ago (want <= 30: a stale entry, not a live neighbour)"; fi ;;
	esac
	[ -n "$b" ] && [ "$b" -le 8112 ] && ok "SD6: status answer $b B <= 8112" || no "SD6: status answer [$b] B (want <= 8112)"
}
if nb02; then
	feat=$(qr "sed -n 's/^BATMAN_FEATURES=//p' /etc/batman-build"); me=$(qr 'cat /sys/class/net/wlh0/address')
	r=""; for i in 1 2 3 4; do
		r=$(pr_pc h0.pem -- status-get "$H0" full | grep '^RESULT status.get')
		case ",$feat,|$(f "$r" peers)," in *",whole-team-status(#254),|"*"${PEERMAC,,}/"*) break ;; *",whole-team-status(#254),|"*) ;; *) break ;; esac
		[ $i = 4 ] || sleep 15
	done
	say "SD6: $(cut -c1-240 <<< "$r")"
	sd6_judge "$r" "$feat" "$me" "$PEERMAC"
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
