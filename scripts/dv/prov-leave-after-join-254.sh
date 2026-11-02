#!/bin/bash
# scripts/dv/prov-leave-after-join-254.sh — #254 tier-B unit prov-leave-after-join-254 (docs/design/254-wireless-txn.md
# §19.1 / §19.6, black-box, real hardware): the reproduction of record of the §19.1 orphan — the OLD image
# (DV_P1_OLD_VERSION) into B (hold), back_to_a (rollback + reboot), claim, join a random test mesh, network/leave at
# once, with a 1 Hz sampler + logread on the node (scripts/node/prov-sampler-254.sh). PASS = the leave is code 0 and
# the radio verifiably down (placeholder key, radio1 disabled + in the mark, no mesh netdev, netifd up=false
# disabled=true, --check rc 0), and the join's own setkey saw netifd pending (the window), see below.
# The window is timing (netifd's teardown + setup after that reboot, 3 s on 04 vs <= 1-2 s idle): on the fixed code
# the join's setkey waits through its own reload, so the unit requires that the window OPENED — >= 3 consecutive
# pending=true samples during the join AND the join's `read-back: netifd up after <n> s` line with n >= 3 — else it
# reports INVALID "window did not open", never PASS, and retries the pair after another B-trial rollback reboot
# (up to 3 tries; a FAIL is final). Negative control: wsl.15 = 4/5 FAIL in the scratch repros (code 21 then 22, an orphan
# wlh0 on the air); the unit itself on wsl.15 (2026-10-30 20:55) = INVALID x3 (netifd's setup took <= 2 s those times;
# wsl.15's setkey has no read-back line, so it can never PASS there — it is FAIL or INVALID). The INVALID rate is high.
# Type: hold / A / F. Side effects: 04 ~30-45 min, off the fleet mesh after the join; B rewritten with the old image
# (per try) then with V; up to ~10 reboots; S0 restore at the end.
set -u
PR_UNIT=prov-leave-after-join-254
OLD=${DV_P1_OLD_VERSION:-1.5.14-wsl.9+825a239.fw4d19709}
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
SAMP=$REPO/scripts/node/prov-sampler-254.sh
ND=/tmp/run/batman-dv
OUT=${DV_DIR:-.}/leave-after-join-$RUN; mkdir -p "$OUT"
# window <join uptime> <leave uptime>: the longest run of pend=true samples in [join, leave) and setkey's read-back n
window(){
	local n r
	r=$(q "awk -v a=$1 -v b=$2 '\$1 >= a && \$1 < b { if (\$4 == \"pend=true\") { c++; if (c > m) m = c } else c = 0 } END { print m + 0 }' $ND/sampler/wl.log")
	n=$(q "grep -o 'read-back: netifd up after [0-9]* s' $ND/sampler/logread.log | tail -1 | grep -o '[0-9]*' | head -1")
	echo "pending=${r:-0} readback=${n:-?}"
}
pr_begin 4800 || { pr_result; exit 1; }
pr_keys && pr_pc_place && pr_claim || { pr_abort "claim"; pr_result; exit 1; }
scp -q $SSHO "$SAMP" root@$NODE:$ND/sampler.sh || { pr_abort "stage"; pr_result; exit 1; }
try=0; verdict=""
while [ $try -lt 3 ] && [ -z "$verdict" ]; do
	try=$((try + 1)); say "try $try: the OLD image into B, then back to A (the reboot that opened the window 4/5)"
	pr_ota_b "$OLD" B || { pr_abort "ota (try $try)"; pr_result; exit 1; }
	back_to_a || { pr_abort "back_to_a (try $try)"; pr_result; exit 1; }
	pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
	scp -q $SSHO "$SAMP" root@$NODE:$ND/sampler.sh; q "chmod 700 $ND/sampler.sh; sh $ND/sampler.sh start" | sed 's/^/    /'
	sleep 2
	MESH="dvl-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	FD3="umask 077; s=\$(head -c 16 /dev/urandom | hexdump -v -e '1/1 \"%02x\"'); printf 'mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\n' '$MESH' \"\$(uci -q get wireless.radio1.channel)\" \"\$s\""
	uj=$(q 'cut -d. -f1 /proc/uptime'); say "try $try: join at node uptime $uj"
	r=$(pr_pc owner.pem FD3="$FD3" -- net-apply --first "$OWNER"); say "join: $(grep -v '^NETCFG' <<< "$r")"
	grep -q "RESULT net.apply code=0 " <<< "$r" || { no "try $try: join: $r"; verdict=FAIL; break; }
	ul=$(q 'cut -d. -f1 /proc/uptime'); say "try $try: leave at node uptime $ul ($((ul - uj)) s after the join started)"
	t0=$(mono); r=$(pr_pc owner.pem -- leave); dt=$(( $(mono) - t0 )); say "leave ($dt s): $r"
	w=$(window "$uj" "$ul"); say "try $try: the window: $w (want pending >= 3 and readback >= 3)"
	q "sh $ND/sampler.sh stop" | sed 's/^/    /'
	scp -q $SSHO "root@$NODE:$ND/sampler/wl.log" "$OUT/wl-try$try.log"; scp -q $SSHO "root@$NODE:$ND/sampler/logread.log" "$OUT/logread-try$try.log"
	pw_=${w#pending=}; pw_=${pw_%% *}; rb=${w##*readback=}
	if ! grep -q "RESULT network.leave code=0" <<< "$r"; then
		no "try $try: network.leave: $r (want code 0; wsl.15: code 21, the forget unverified — an orphan on the air)"; verdict=FAIL; break
	fi
	if [ "${pw_:-0}" -ge 3 ] && [ "${rb:-0}" -ge 3 ] 2>/dev/null; then
		ok "try $try: the window opened ($w) and the leave is code 0"
		s=$(q 'halow-setkey --status 2>/dev/null | head -1; iw dev 2>/dev/null | grep -c "type mesh point"; ubus call network.wireless status | jsonfilter -e @.radio1.up -e @.radio1.disabled | tr "\n" " "; batman-config-save --check >/dev/null 2>&1; echo "check_rc=$?"' | tr '\n' ' ')
		case "$s" in *"key=PLACEHOLDER"*"disabled=1"*" 0 false true "*"check_rc=0"*) ok "after the leave: placeholder, radio1 disabled, no mesh netdev, netifd down+disabled, --check rc 0 [$s]" ;; *) no "after the leave: [$s]" ;; esac
		verdict=PASS
	else
		inv "try $try: window did not open ($w) — the leave's code 0 proves nothing here"
		[ $try -lt 3 ] && say "try $try: retrying after another B-trial rollback reboot (the node is Left: claimed, no network)"
	fi
done
[ "$verdict" = PASS ] && invalid=0   # an earlier INVALID try is superseded by a try whose window opened
pr_end
pr_result
