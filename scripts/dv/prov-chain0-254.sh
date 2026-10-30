#!/bin/bash
# scripts/dv/prov-chain0-254.sh — #254 tier-B unit chain 0 (L15; docs/design/254-p1-impl.md §5.4 chain 0,
# 254-h23-harness.md §6.2): a console-free bypass boot (`batman_bypass=1` on the kernel cmdline) runs on image defaults
# and must not create or persist any provisioning state.
#   snap -> hold = V written -> the V payload extracted, `batman-slot apply` into B (arms a one-shot tryboot) -> B's
#   boot FAT (/dev/mmcblk0p3) cmdline.txt gets ` batman_bypass=1` (sha before / after recorded) -> plain reboot (as
#   prov-ac-noarm) -> 04 found by its eth MAC (image defaults: the address may differ; `none` login, the node is open)
#   -> asserted: /proc/cmdline has batman_bypass=1 + batman_slot=B; the helper logged "verdict=unknown(bypass)" (boot rc
#   3); no identity/node.key made; `batman-config-save --save` refused ("bypass boot … refusing", rc != 0); 96 logged
#   "bypassed (batman_bypass=1)" and is still armed (/etc/uci-defaults/96-batman-config-migrate present) -> rollback +
#   reboot committed (plain reboot as the fallback: the tryboot is one-shot) -> A -> restore (p5 compare proves nothing
#   was persisted; the B rewrite restores B's cmdline).
#   Control: the same apply WITHOUT the cmdline edit is every hold unit's B trial ("boot rc=0 verdict=legacy"); here
#   A's own helper line after the return is asserted not to be a bypass verdict.
#   Fail-safe: a bypass boot that is never found falls back to A by itself (one-shot tryboot, deadline revert armed).
# Type: hold / A / F. Side effects: 04 ~45 min, B rewritten twice (V + cmdline, then V), 3 reboots.
set -u
PR_UNIT=prov-chain0-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
PDIR=/opt/batdata/dv-prov/payload-$RUN
BFAT=/dev/mmcblk0p3
NONEO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=none,publickey -o IdentitiesOnly=yes -i $LABKEY -o LogLevel=ERROR"
MACW=$(echo "$MAC" | tr ':' '-')
FIP=""
fq(){ timeout 60 ssh $NONEO root@"$FIP" "$@" 2>/dev/null | tr -d '\r'; }
# is04 <ip>: 04 (by eth MAC) answers there in the bypass B trial -> prints its state
is04(){ local s; s=$(timeout 20 ssh $NONEO root@"$1" "$ST" 2>/dev/null | tr -d '\r'); case "$s" in "mac=$MAC "*"slot=B "*) echo "$s"; return 0 ;; esac; return 1; }
# find_bypass <secs> <boot to leave>: the node at $NODE, then any lab address whose ARP entry is 04's MAC (after a sweep)
find_bypass(){
	local t0 ip s n i
	t0=$(mono)
	while [ $(( $(mono) - t0 )) -lt "$1" ]; do
		for ip in $NODE $(arp -a | tr -d '\r' | awk -v m="$MACW" 'tolower($2)==m {print $1}'); do
			s=$(is04 "$ip") || continue; case "$s" in *"boot=$2"*) continue ;; esac
			FIP=$ip; FS=$s; return 0
		done
		for n in 10.41.254 10.41.1 192.168.1; do
			for i in $(seq 1 254); do ping -n 1 -w 200 "$n.$i" >/dev/null 2>&1 & [ $((i % 40)) = 0 ] && wait; done; wait
		done
		sleep 10
	done
	return 1
}
chain0(){
	local s b0 hv o r
	pr_payload "$PR_V" >/dev/null || { no "payload $PR_V"; return 1; }
	hv=$(sed -n 's/^BATMAN_VERSION=//p' <<< "$PSTAMP")
	scp -q $SSHO "$PAYF" root@$NODE:$PR_PAY.part && q "mv $PR_PAY.part $PR_PAY" || { no "payload upload"; return 1; }
	[ "$(qr "sha256sum < $PR_PAY | cut -c1-64")" = "$PSHA" ] || { no "payload sha on the node"; return 1; }
	o=$(q "rm -rf $PDIR; mkdir -p -m 0700 $PDIR && tar -xzf $PR_PAY -C $PDIR && echo EXTRACTED")
	grep -q EXTRACTED <<< "$o" || { no "extract: $o"; return 1; }
	q "printf '%s\n' '$hv' > $HOLDF; sync"; [ "$(qr "cat $HOLDF")" = "$hv" ] || { no "hold read-back"; return 1; }
	o=$(timeout 900 ssh $SSHO root@$NODE "batman-slot apply $PDIR 2>&1 | tail -3" 2>/dev/null | tr -d '\r'); say "apply: $(echo $o)"
	grep -q "armed as one-shot tryboot" <<< "$o" || { q "$DISARM; rm -f $HOLDF" >/dev/null; no "apply did not arm: $o"; return 1; }
	PR_WROTE_B=1
	o=$(q "m=\$(mktemp -d /tmp/run/batman-dv/c0.XXXXXX) && mount -t vfat $BFAT \$m && { c0=\$(sha256sum < \$m/cmdline.txt | cut -c1-16); grep -q batman_bypass \$m/cmdline.txt || sed -i '1s/\$/ batman_bypass=1/' \$m/cmdline.txt; sync; echo \"C0=\$c0 C1=\$(sha256sum < \$m/cmdline.txt | cut -c1-16) LINE=\$(cat \$m/cmdline.txt)\"; umount \$m; }; rmdir \$m")
	say "B cmdline.txt: $o"
	case "$o" in *"batman_bypass=1"*"batman_slot=B"*|*"batman_slot=B"*"batman_bypass=1"*) ok "B's cmdline.txt carries batman_bypass=1 (${o%% LINE=*})" ;; *) no "B cmdline edit: $o"; q "$DISARM; rm -f $HOLDF" >/dev/null; return 1 ;; esac
	[ "$(qr "grep -c '^$BFAT ' /proc/mounts")" = 0 ] || { no "B's boot FAT still mounted"; return 1; }
	s=$(qr "$ST"); b0=$(field "$s" boot)
	q '(sync; reboot) </dev/null >/dev/null 2>&1 &'
	say "rebooting into the bypass B trial; looking for MAC $MAC"
	find_bypass 900 "$b0" || { say "bypass boot not found in 900 s — waiting for 04's own return to A (one-shot tryboot / deadline revert)"; pr_find 2400 "$b0" || { pr_needs_person "04 neither found in the bypass trial nor back on A"; return 1; }; no "bypass boot not found by eth MAC (04 came back on A by itself)"; return 1; }
	say "found at $FIP: $FS"
	r=$(fq 'cat /proc/cmdline'); case "$r" in *batman_bypass=1*batman_slot=B*|*batman_slot=B*batman_bypass=1*) ok "bypass boot: /proc/cmdline has batman_bypass=1 and batman_slot=B" ;; *) no "bypass boot cmdline: $r" ;; esac
	[ "$(fq 'echo $(id -u)')" = 0 ] && ok "bypass boot: root login by 'none' at $FIP (open, image defaults)" || no "no root login on the bypass boot"
	r=$(fq "logread | grep 'batman-provhelper' | grep -m1 'boot rc='"); say "helper: ${r##*]: }"
	case "$r" in *"boot rc=3 verdict=unknown(bypass)"*) ok "helper: boot rc=3 verdict=unknown(bypass)" ;; *) no "helper boot line: [$r]" ;; esac
	[ "$(fq '[ -e /etc/batman-prov/identity/node.key ] && echo KEY || echo NOKEY')" = NOKEY ] && ok "no identity made (no identity/node.key)" || no "an identity exists on the bypass boot"
	r=$(fq 'batman-config-save --save 2>&1 | tail -1; echo rc=$?')
	case "$r" in *"bypass boot (batman_bypass=1): refusing to persist"*) ok "persist refused: ${r%%rc=*}" ;; *) no "batman-config-save --save on the bypass boot: [$(echo $r)]" ;; esac
	r=$(fq "logread | grep -m1 'bypassed (batman_bypass=1)'; [ -e /etc/uci-defaults/96-batman-config-migrate ] && echo ARMED")
	grep -q 'bypassed (batman_bypass=1)' <<< "$r" && grep -q ARMED <<< "$r" && ok "96: bypassed, still armed (exit 1)" || no "96 on the bypass boot: [$(echo $r)]"
	b0=$(field "$FS" boot)
	r=$(fq 'batman-slot rollback >/dev/null 2>&1 && { (batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &); echo SENT; }')
	grep -q SENT <<< "$r" || { say "rollback refused on the bypass boot — plain reboot (the tryboot is one-shot)"; fq '(sync; reboot) </dev/null >/dev/null 2>&1 &'; }
	pr_find 900 "$b0" || { pr_needs_person "04 not back on A after the bypass trial"; return 1; }
	[ "$(field "$PR_STATE" slot)" = A ] && [ "$(field "$PR_STATE" trial_rc)" = 1 ] && ok "back on A committed" || { no "after the bypass trial: $PR_STATE"; return 1; }
	r=$(qr "logread | grep 'batman-provhelper' | grep -m1 'boot rc='"); case "$r" in *bypass*) no "A's helper line is a bypass verdict: $r" ;; *) ok "control: A's helper ${r##*]: }" ;; esac
	q "rm -rf $PDIR $PR_PAY $HOLDF; sync"
}
pr_begin 3600 || { pr_result; exit 1; }
chain0 || { pr_abort "chain 0"; pr_result; exit 1; }
pr_end
pr_result
