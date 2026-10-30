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
#   L26's BLE half (provd acks before it applies) is H3.
# Type: — / A / F. Side effects: 04 ~40 min off the mesh, 1 sysrq reboot + restores, claimed in between.
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
newfd3(){
	NEW="dvu-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	PR_FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$NEW' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
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
	q "cp -p /usr/bin/halow-setkey $W/setkey.real && chmod 700 $W/setkey.real && printf '#!/bin/sh\n$W/setkey.real \"\$@\"; r=\$?\nbatman-config-save --on-join > $W/onjoin.out 2>&1; echo \"onjoin_rc=\$?\" >> $W/onjoin.out; echo \"setkey_rc=\$r\" >> $W/onjoin.out\nexit 1\n' > $W/setkey.hook && chmod 755 $W/setkey.hook"
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
	if [ "$w" = yield ]; then
		grep -q 'provisioning transaction in progress' <<< "$o" && grep -q 'onjoin_rc=1' <<< "$o" && ok "yield: the --on-join tick yielded (rc 1, transaction in progress)" || no "yield: tick [$o]"
		[ "$(grep overrides.uci <<< "$a")" = "$(grep overrides.uci <<< "$b")" ] && ok "yield: p5 overrides.uci unchanged" || no "yield: p5 overrides.uci moved"
		[ "$(grep prov.meta <<< "$a")" = "$(grep prov.meta <<< "$b")" ] && ok "yield: p5 prov.meta unchanged" || no "yield: p5 prov.meta moved"
	else
		[ "$(grep overrides.uci <<< "$a")" != "$(grep overrides.uci <<< "$b")" ] && ok "negative control: a non-yielding --on-join wrote the half-applied wireless into p5 (rc $(sed -n 's/.*onjoin_rc=\([0-9]*\).*/\1/p' <<< "$(echo $o)"))" \
			|| no "negative control: p5 overrides unchanged even without the yield — the control had no effect ($o)"
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
	l=$(qr "logread | grep 'batman-provhelper' | grep -E 'action=txn' | tail -2"); echo "$l" | sed 's/^/    /'
	grep -q 'action=txn .*committed (gen [0-9]*): overlay completed from p5' <<< "$l" && ok "txn-3: overlay completed from p5" || no "txn-3: no 'overlay completed from p5'"
	# (pr_killpoint already re-placed provclient after the reboot — a second placement refuses: run 2, 2026-10-28)
	i=$(pr_info); case " $i " in *" state=member "*) ok "txn-3 + tick: state member (L25 final state, p1-impl §10.4)";; *) no "txn-3 + tick: $i";; esac
	m=$(qr "$MESHID"); [ "$m" = "$NEW" ] && ok "txn-3: wireless == the update ($m)" || no "txn-3: mesh_id $m (want $NEW)"
	c=$(qr 'batman-config-save --check >/dev/null 2>&1; echo rc=$?'); say "--check after: $c (5 = the F39 overrides lag, product checklist #254)"
	pk_proof && ok "the lab key still logs in" || no "the lab key does not log in after txn-3"
}
pr_begin 3600 || { pr_result; exit 1; }
arm yield || { pr_abort "arm yield"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm yield"; pr_result; exit 1; }
arm noyield || { pr_abort "arm noyield"; pr_result; exit 1; }
pr_restore || { pr_abort "restore after arm noyield"; pr_result; exit 1; }
txn3 || { pr_abort "arm txn-3"; pr_result; exit 1; }
pr_end
pr_result
