#!/bin/bash
# scripts/dv/prov-netupdate-254.sh — #254 tier-B unit prov-netupdate-254 (L25, L26; docs/design/254-h23-harness.md §6.2,
# 254-stage1-impl L25): a periodic `batman-config-save --on-join` tick that lands inside a network/update transaction
# yields, and a power loss mid-transaction still ends as member.
#   arm yield: member -> a hook bound over halow-setkey (the transaction's step 2) runs the real setkey, then
#     `batman-config-save --on-join` (inside the transaction), then exits 1 -> net-apply --update fails; the tick said
#     "provisioning transaction in progress" rc 1; p5 overrides.uci and prov.meta did not move
#   negative control [bind]: the same with a config-save whose --on-join does not yield bound over it -> the p5
#     overrides DO move (the tick wrote the half-applied wireless into p5)
#   arm txn-3: member -> killpoint txn-3 (p5 has the new generation, the overlay not) on net-apply --update -> sysrq ->
#     first thing after the reboot: an --on-join tick (recorded with whether .txn was still there) -> >= 150 s ->
#     member, "overlay completed from p5", wireless == the update, --check rc 0 or 5 (F39 lag, recorded)
#   arm stale-secrets (docs/design/254-net-update-members.md §6): member -> net-apply --update-stale-secrets (the new
#     net_config with net_secrets of the CURRENT version — the pairing a forwarder could send to keep an old SAE a
#     removed member knows) -> E_BAD_OBJECT (code 4) with the helper's reason "(net_secrets)" (the binding, not an
#     earlier check), the mesh id unchanged, no .txn, the state still member. provclient cannot read the node's stored
#     secrets, so it builds FRESH ones with the current version (a new SAE): the same check refuses both. No
#     on-hardware control before the fix (wsl.24 refuses the new shape for another reason); the fix's negative control
#     is the Go mutant (node: M11 / M12) and the review probes.
#   L26's BLE half (provd acks before it applies) is H3.
# Type: — / A / F. Side effects: 04 ~50 min off the mesh (yield, noyield, stale-secrets, txn-3: 4 pr_member joins,
# each with its reboot), 1 sysrq reboot + restores after each arm, claimed in between.
set -u
PR_UNIT=prov-netupdate-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
MESHID='uci -q get wireless.default_radio1.mesh_id'
W=/tmp/run/batman-dv/wbox/$RUN
p5f(){	# <tag>: the p5 manifest lines of overrides.uci and prov.meta (prov-base reads p5 ro,noload under its rules)
	local o; o=$(nb manifest "$RUN" "$1"); grep -q "^MANIFEST $RUN $1" <<< "$o" || { echo "ERR $o"; return 1; }
	qr "grep -E ' (overrides\.uci|prov\.meta)\$' /opt/batdata/dv-prov/$RUN/now-$1/p5.manifest"
}
newfd3(){	# the update's net_config keeps the country pr_member's join stored (= radio1.country, prov-254.sh pr_member):
	# a P3 helper refuses an update that changes it (E_REJECTED reason 14, 254-net-update-members §2.2-2)
	NEW="dvu-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$NEW' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\"; c=\$(uci -q get wireless.radio1.country); [ -n \"\$c\" ] && printf 'country=%s\n' \"\$c\""
}
bindf(){	# <name in W> <target>
	local h o; h=$(qr "sha256sum < $W/$1 | cut -c1-64"); o=$(pw bind "$1" "$h" "$2"); say "$o"; grep -q "^BOUND $2" <<< "$o"
}
arm(){	# <yield|noyield>
	local w=$1 a b r o
	pr_member || return 1
	a=$(p5f "m0-$w") || { no "p5 manifest before: $a"; return 1; }
	pw prep >/dev/null
	# the real setkey as it is now (the hook calls it; /rom may differ from the slot's overlay)
	# the hook also records p5's overrides.uci sha right after the tick: that is the moment the control must judge —
	# after net-apply returns, the helper's Finish has already put the previous network back into p5 (wireless-txn
	# §19 made that save reliable, so the before/after manifests look unchanged even when the tick DID write)
	q "cp -p /usr/bin/halow-setkey $W/setkey.real && chmod 700 $W/setkey.real && printf '#!/bin/sh\np5(){ m=\$(mktemp -d /tmp/run/batman-dv/p5h.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 \$m && { sha256sum < \$m/overrides.uci | cut -c1-64; umount \$m; }; rmdir \$m 2>/dev/null; }\n$W/setkey.real \"\$@\"; r=\$?\npre=\$(p5)\nbatman-config-save --on-join > $W/onjoin.out 2>&1; echo \"onjoin_rc=\$?\" >> $W/onjoin.out; echo \"setkey_rc=\$r\" >> $W/onjoin.out\necho \"p5pre=\$pre p5ovr=\$(p5)\" >> $W/onjoin.out\nexit 1\n' > $W/setkey.hook && chmod 755 $W/setkey.hook"
	if [ "$w" = noyield ]; then
		# the mutant removes EVERY yield of --on-join (wireless-txn §7): the txn_live check at the mode switch, the
		# SEQ0 "none none" gate before staging, and the txn_seq re-check right before the p5 write (2026-10-30: the
		# mutant that only emptied the mode line left SEQ0 unset -> the SEQ0 gate still yielded -> "the control had
		# no effect" on wsl.16)
		q "sed -e 's/^\([[:space:]]*\)--on-join) txn_live && .*;;\$/\1--on-join) SEQ0=\"none none\" ;;   # DV noyield mutant/' -e 's/^if \[ -n \"\$SEQ0\" \] && \[ \"\$(txn_seq)\" != \"\$SEQ0\" \]; then\$/if false; then   # DV noyield mutant/' /usr/bin/batman-config-save > $W/cfgsave.noyield && chmod 755 $W/cfgsave.noyield"
		[ "$(qr "grep -c 'DV noyield mutant' $W/cfgsave.noyield")" = 2 ] || { no "noyield: the config-save mutant did not take ($(qr "grep -c 'DV noyield mutant' $W/cfgsave.noyield") of 2 edits)"; return 1; }
		bindf cfgsave.noyield /usr/bin/batman-config-save || { no "bind of the noyield config-save"; return 1; }
	fi
	bindf setkey.hook /usr/bin/halow-setkey || { no "bind of the setkey hook"; return 1; }
	newfd3
	r=$(pr_pc owner.pem FD3="$PR_FD3" -- net-apply --update "$OWNER" "$PR_NETCFG"); echo "$r" | grep -v '^NETCFG' | sed 's/^/    /'
	o=$(qr "cat $W/onjoin.out 2>/dev/null"); say "tick inside the transaction: $(echo $o)"
	say "unbind: $(pw unbind-all | tr '\n' ' ')"
	b=$(p5f "m1-$w") || { no "p5 manifest after: $b"; return 1; }
	grep -q 'setkey_rc=0' <<< "$o" || { inv "$w: the real setkey inside the hook failed ($o) — the transaction never reached its wireless change"; return 1; }
	grep -qE 'RESULT net.apply\(update\) code=[1-9]' <<< "$r" && ok "$w: net-apply --update failed at step 2 (hook exit 1)" || no "$w: net-apply result: $(grep RESULT <<< "$r")"
	# p5's overrides.uci immediately before and after the tick, both read inside the hook (the manifests a / b are
	# taken outside the transaction and can lag behind the periodic save, F39)
	a0=$(sed -n 's/.*p5pre=\([0-9a-f]*\).*/\1/p' <<< "$(echo $o)"); h=$(sed -n 's/.*p5ovr=\([0-9a-f]*\).*/\1/p' <<< "$(echo $o)")
	[ -n "$h" ] && [ -n "$a0" ] || { inv "$w: the hook recorded no p5 overrides sha around the tick ($o)"; return 1; }
	if [ "$w" = yield ]; then
		grep -q 'provisioning transaction in progress' <<< "$o" && grep -q 'onjoin_rc=1' <<< "$o" && ok "yield: the --on-join tick yielded (rc 1, transaction in progress)" || no "yield: tick [$o]"
		[ "$h" = "$a0" ] && ok "yield: p5 overrides.uci unchanged at the tick" || no "yield: p5 overrides.uci moved at the tick"
		[ "$(grep overrides.uci <<< "$a")" = "$(grep overrides.uci <<< "$b")" ] && ok "yield: p5 overrides.uci unchanged after the arm" || no "yield: p5 overrides.uci moved"
		[ "$(grep prov.meta <<< "$a")" = "$(grep prov.meta <<< "$b")" ] && ok "yield: p5 prov.meta unchanged" || no "yield: p5 prov.meta moved"
	else
		[ "$h" != "$a0" ] && ok "negative control: a non-yielding --on-join wrote the half-applied wireless into p5 at the tick (rc $(sed -n 's/.*onjoin_rc=\([0-9]*\).*/\1/p' <<< "$(echo $o)"); the Finish then put the previous network back: after the arm $([ "$(grep overrides.uci <<< "$a")" = "$(grep overrides.uci <<< "$b")" ] && echo unchanged || echo changed))" \
			|| no "negative control: p5 overrides unchanged at the tick even without the yield — the control had no effect ($o)"
	fi
}
txn3(){
	local o m l c i
	pr_member || return 1
	newfd3
	pr_killpoint txn-3 net-apply --update "$OWNER" "$PR_NETCFG" || return 1
	o=$(qr 'echo "txn=$([ -e /etc/batman-prov/.txn ] && echo present || echo gone) up=$(cut -d. -f1 /proc/uptime)"; batman-config-save --on-join 2>&1 | tail -1; echo "onjoin_rc=$?"')
	say "first --on-join tick after the reboot: $(echo $o)"
	w=$(( 150 - $(qr 'cut -d. -f1 /proc/uptime') )); [ $w -gt 0 ] && { say "waiting ${w}s"; sleep $w; }
	# the boot line since wireless-txn v8 (as prov-powerloss-254 txn-3 asserts): p5 newer -> the overlay record rebuilt
	l=$(qr "logread | grep 'batman-provhelper' | grep -E 'boot rc=|finished' | tail -4"); echo "$l" | sed 's/^/    /'
	grep -q 'action=p5 newer: rebuilt the overlay record' <<< "$l" && ok "txn-3: --boot rebuilt the overlay from p5" || no "txn-3: no 'p5 newer: rebuilt the overlay record'"
	# (pr_killpoint already re-placed provclient after the reboot — a second placement refuses: run 2, 2026-10-28)
	i=$(pr_info); case " $i " in *" state=member "*) ok "txn-3 + tick: state member (L25 final state, p1-impl §10.4)";; *) no "txn-3 + tick: $i";; esac
	m=$(qr "$MESHID"); [ "$m" = "$NEW" ] && ok "txn-3: wireless == the update ($m)" || no "txn-3: mesh_id $m (want $NEW)"
	c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); say "--check after: $c (5 = the F39 overrides lag, product checklist #254)"
	pk_proof && ok "the lab key still logs in" || no "the lab key does not log in after txn-3"
}
stale(){
	local r m0 m1 t i l cc
	pr_member || return 1
	m0=$(qr "$MESHID"); cc=$(qr 'uci -q get wireless.radio1.country')
	newfd3
	# a marker in the log first: the reason below is read only from lines after it (this request's, review r2 B-m4)
	q "logger -t batman-dv 'dv-stale-marker $RUN'"
	r=$(pr_pc owner.pem FD3="$PR_FD3" -- net-apply --update-stale-secrets "$OWNER" "$PR_NETCFG"); echo "$r" | grep -v '^NETCFG' | sed 's/^/    /'
	grep -q 'RESULT net.apply(update-stale-secrets) code=4 ' <<< "$r" && ok "stale-secrets: refused with E_BAD_OBJECT" || no "stale-secrets: $(grep RESULT <<< "$r")"
	[ -n "$cc" ] && grep -q " country=$cc\$" <<< "$(grep '^RESULT' <<< "$r")" && ok "stale-secrets: sent with the stored country ($cc)" || no "stale-secrets: country [$cc] vs $(grep RESULT <<< "$r")"
	# refused by the secrets binding, not by an earlier check with the same code (the helper logs the reason)
	l=$(qr "logread | sed -n '/dv-stale-marker $RUN/,\$p' | grep 'verb net.apply refused: code 4' | tail -1"); say "helper: $l"
	grep -q '(net_secrets)' <<< "$l" && ok "stale-secrets: the refusal is the net_secrets binding" || no "stale-secrets: refusal reason [$l]"
	m1=$(qr "$MESHID"); t=$(qr '[ -e /etc/batman-prov/.txn ] && echo present || echo gone')
	[ -n "$m0" ] && [ "$m1" = "$m0" ] && ok "stale-secrets: mesh id unchanged ($m1)" || no "stale-secrets: mesh id $m0 -> $m1"
	[ "$t" = gone ] && ok "stale-secrets: no .txn" || no "stale-secrets: .txn $t"
	i=$(pr_info); case " $i " in *" state=member "*) ok "stale-secrets: still member";; *) no "stale-secrets: $i";; esac
}
pr_begin 3600 || { pr_result; exit 1; }
arm yield || { pr_abort "arm yield"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm yield"; pr_result; exit 1; }
arm noyield || { pr_abort "arm noyield"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm noyield"; pr_result; exit 1; }
stale || { pr_abort "arm stale-secrets"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm stale-secrets"; pr_result; exit 1; }
txn3 || { pr_abort "arm txn-3"; pr_result; exit 1; }
pr_end
pr_result
