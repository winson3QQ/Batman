#!/bin/bash
# scripts/dv/prov-status-diag-254.sh — #254 H4 appendix A.5, the helper-level parts (p3-how "h"):
#   SD1  status.get (scope 0) agrees with the node: state = the helper's record, neighbours = meshjoin's batman count
#        on wlh0, p5_saved = `batman-config-save --check` rc 0; the member role's view (SD2) is provd's: by hand
#   SD4  diag.bundle -> a handle; diag.read follows it to the end: > 64 KiB in total, the bytes are a tar (`tar t` on
#        the host lists /etc/config entries), and the AP passphrase / mesh key are NOT in it (grep of the real values,
#        on the node, against the bytes the node handed out - the values never leave the node); chunked retrieval
#        through provd (> 64 KiB over one provd reply) is provd's part: by hand
# SD3 (ro connection rate through provd) and SD5 (handles across sessions) are provd's: p3-manual-rows.md.
# W (pre-P3 image): status.get / diag.summary / diag.read are unknown (20) -> the rows FAIL with the code they got.
# Type: R. Side effects: none beyond the unit's snapshot and restore (one reboot).
set -u
PR_UNIT=prov-status-diag-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 1200 || { pr_result; exit 1; }
pr_keys && pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
f(){ sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<< "$1" | head -1; }
# ---- SD1 status.get vs the node
n=$(qr '. /usr/lib/batman/meshjoin.sh; meshjoin_sample; batman-config-save --check >/dev/null 2>&1; echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) bat=$MJ_BAT plink=$MJ_PLINK check_rc=$?"')
say "SD1 node: $n"
r=$(pr_pc owner.pem -- status-get "$OWNER" 0 | grep '^RESULT status.get'); say "SD1: $(cut -c1-200 <<< "$r")"
if [ "$(code "$r")" = 0 ]; then
	[ "$(f "$r" state)" = "$(f "$n" state)" ] && ok "SD1: state $(f "$r" state) = the record" || no "SD1: state [$(f "$r" state)] vs the record [$(f "$n" state)]"
	[ "$(f "$r" neighbours)" = "$(f "$n" bat)" ] && ok "SD1: neighbours $(f "$r" neighbours) = batman neighbours on wlh0" || no "SD1: neighbours [$(f "$r" neighbours)] vs meshjoin bat [$(f "$n" bat)]"
	want=false; [ "$(f "$n" check_rc)" = 0 ] && want=true
	[ "$(f "$r" p5_saved)" = "$want" ] && ok "SD1: p5_saved $want = --check rc $(f "$n" check_rc)" || no "SD1: p5_saved [$(f "$r" p5_saved)] vs --check rc $(f "$n" check_rc)"
else no "SD1: status.get code $(code "$r") (want 0): [$r]"; fi
# ---- SD4 the bundle
r=$(pr_pc owner.pem -- diag-bundle "$OWNER" | grep '^RESULT diag.bundle'); say "SD4: $r"
H=$(f "$r" handle)
if [ "$(code "$r")" = 0 ] && [ -n "$H" ]; then
	ok "SD4: diag.bundle code 0, handle $H"
	# the bytes stay on the node: provclient (uid 471 after its drop) writes them into $PCD/out (471:471 0700, tmpfs)
	q "mkdir -m 0700 $PCD/out && chown 471:471 $PCD/out" >/dev/null
	r2=$(pr_pc owner.pem PROVCLIENT_TIMEOUT_S=300 -- diag-read "$OWNER" "$H" "$PCD/out/diag.bin" | grep '^RESULT diag.read'); say "SD4: $r2"
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
