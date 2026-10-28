#!/bin/bash
# scripts/dv/prov-misc-254.sh — #254 tier-B unit prov-misc-254 (docs/design/254-h23-harness.md §17; supersedes §6.2's row):
#   dry-run arms (§17.3/17.4) on the committed slot — white-box prov-state / ota-armed.mesh, an autocommit dry run killed
#   at its "mesh join required" line, each arm's state put back:
#     L38 a (99zz -> helper member/radio while waiting) required: 1; b (99zz only) prov=unclaimed after >= 60 s;
#         c (another boot's line) prov=none; neg: misc-l38 bound -> b answers < 60 s, a stays unclaimed
#     L42 member/radio, no arm file -> "no usable ota-armed.mesh" + required: 1; a correct radio arm file -> armed in
#         radio-only mode + required: 0 (so (6a)'s "no file after apply" assertion discriminates); neg: misc-l42 -> 0
#     L43 an arm file of another boot -> the whole line required: 1, no "no usable", the file unchanged; neg misc-l43 -> 0
#     L51 the arm boot's file saying joined -> required: 1; neg misc-l51 -> 0
#   (the write halves: autocommit (6a) / (7) on the node, tests/prov-p1/autocommit-mesh-arm.sh in CI)
#   L11 helper restart -> new pid, helper.sock root:471 0660, health refreshed; neg: a planted file in the socket dir ->
#       "sock: unexpected … refusing to start", health NOT refreshed -> removed, restarted
#   L9 / L10 bluetoothd / dbus restart -> health ok within 40 s; neg: bluetoothd stopped -> health bluetoothd=0
#   L27 dropbear restart -> the lab key logs in; neg: a throwaway key is refused
#   L3 clean reboot -> boot-reasons prev=CLEAN (trigger prov-dv-254) + the helper's "boot rc=" line
# Type: — / A / F. Side effects: ~12 dry runs (ota-trace AC lines), one reboot, short helper / bluetoothd / dbus /
# dropbear restarts; a misc-l* autocommit is bound over /usr/bin/batman-autocommit only during its arm.
set -u
PR_UNIT=prov-misc-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
W=/tmp/run/batman-dv/wbox/$RUN
mn(){ q "sh $W/prov-misc-254.sh $*"; }
HEALTH='. /usr/lib/batman/rundir.sh; cat $RUNDIR/batman-prov.health 2>/dev/null'
hts(){ local h; h=$(qr "$HEALTH"); h=${h#*ts=}; echo "${h%% *}"; }
bindac(){	# <misc-lNN>: its autocommit (dv-prov-tools) into W and bound over /usr/bin/batman-autocommit
	local d=$PR_TOOLS/$PR_V/$1 h o
	[ -f "$d/batman-autocommit" ] && (cd "$d" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 || { no "no verified $1 autocommit in $d (scripts/dv-prov-tools.sh)"; return 1; }
	[ -z "$(qr 'pgrep -f "batman-autocommit run"')" ] || { no "a batman-autocommit run is alive before the bind"; return 1; }
	scp -q $SSHO "$d/batman-autocommit" root@$NODE:$W/$1.ac && q "chmod 755 $W/$1.ac" || { no "scp of $1"; return 1; }
	h=$(sha256sum < "$d/batman-autocommit" | cut -c1-64); o=$(pw bind "$1.ac" "$h" /usr/bin/batman-autocommit); say "$o"
	[ "$(qr "grep -c 'WBOX-$1-' /usr/bin/batman-autocommit")" -ge 1 ] || { no "$1 not in effect after the bind"; pw unbind-all >/dev/null; return 1; }
}
# dr <tag> <misc variant|-> <setps args> <setarm args> [<mid setps args>|<mid setarm args>]: one dry-run arm;
# sets DOUT (its stdout), DEL (seconds to the judgement) and ARMAFTER (the arm file when it was judged)
dr(){
	local tag=$1 b=$2 ps=$3 arm=$4 mid=${5:-} o
	o=$(mn save); grep -q '^SAVED' <<< "$o" || { no "$tag save: $o"; return 1; }
	[ "$b" = - ] || bindac "$b" || { mn restore >/dev/null; return 1; }
	say "$tag: $(mn setps "$ps") / $(mn setarm "$arm")"
	o=$(mn start "$tag"); grep -q PGID <<< "$o" || { no "$tag: $o"; mn restore >/dev/null; [ "$b" = - ] || pw unbind-all >/dev/null; return 1; }
	if [ -n "$mid" ]; then
		o=$(mn insleep "$tag"); [ "$o" = INSLEEP ] || inv "$tag: the dry run never reached its wait loop ($o)"
		say "$tag mid: $(mn setps "${mid%%|*}") / $(mn setarm "${mid#*|}")"
	fi
	o=$(QT=200 mn wait "$tag" 150); DEL=$(sed -n 's/^ELAPSED //p' <<< "$o" | head -1); DOUT=$(grep -v '^ELAPSED' <<< "$o")
	say "$tag (${DEL}s): $(grep -E 'mesh join required|no usable|armed in radio-only|WBOX-misc' <<< "$DOUT" | sed 's/^batman-autocommit: //' | tr '\n' '|')"
	ARMAFTER=$(qr 'cat /opt/batdata/state/ota-armed.mesh 2>/dev/null')
	o=$(mn stop "$tag"); [ "$o" = STOPPED ] || no "$tag: $o"
	o=$(mn restore); say "$tag restore: $(echo $o)"
	grep -q HELPER-SAME <<< "$o" || inv "$tag: the helper restarted during the arm ($o) — prov-state may have been rewritten"
	if [ "$b" != - ]; then
		o=$(pw unbind-all); grep -q 'UNBIND-ALL ok' <<< "$o" || no "$tag unbind: $o"
		grep -q "WBOX-$b-" <<< "$DOUT" || inv "$tag: no witness WBOX-$b- in the dry run's stdout (the mutant was not executed)"
	fi
	return 0
}
has(){ grep -qF -- "$1" <<< "$DOUT"; }
mjr(){ grep 'mesh join required' <<< "$DOUT" | sed 's/^batman-autocommit: //'; }
dryarms(){
	local s o
	# §23.9 / §21.3: no sysupgrade running, no fw-override this boot (a dry run would end at :315), no p6 hold flag.
	# "[/]sbin": the plain pattern matched this very ssh shell's command line (rerun 2026-10-28: INVALID sysupgrade-running)
	o=$(qr 'pgrep -f "[/]sbin/sysupgrade" >/dev/null && echo sysupgrade-running; . /usr/lib/batman/rundir.sh; [ -e "$RUNDIR/batman-fw-override" ] && echo fw-override; [ -e /opt/batdata/state/autocommit-hold-commit ] && echo hold-flag')
	[ -z "$o" ] || { inv "dry-run preconditions: $(echo $o)"; return 1; }
	pw prep >/dev/null
	scp -q $SSHO "$REPO/scripts/node/prov-misc-254.sh" root@$NODE:$W/ && q "chmod 700 $W/prov-misc-254.sh" || { no "push prov-misc-254.sh"; return 1; }
	# L38
	dr l38a - "this 99zz unclaimed 0" "none" "this helper member radio|none" || return 1
	if has "mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)"; then ok "L38 a: switched to the helper's line -> required: 1 (prov=member)"; else no "L38 a: [$(mjr)]"; fi
	dr l38b - "this 99zz unclaimed 0" "none" || return 1
	if has "mesh join required: 0 (prov=unclaimed" && [ "${DEL:-0}" -ge 60 ]; then ok "L38 b: waited ${DEL}s for the helper, then 99zz's prov=unclaimed"; else no "L38 b: ${DEL}s [$(mjr)]"; fi
	dr l38c - "other helper member radio" "none" || return 1
	if has "(prov=none"; then ok "L38 c: another boot's prov-state -> prov=none"; else no "L38 c: [$(mjr)]"; fi
	dr l38neg misc-l38 "this 99zz unclaimed 0" "none" || return 1
	if has "mesh join required: 0 (prov=unclaimed" && [ "${DEL:-99}" -lt 60 ]; then ok "L38 negative control: misc-l38 does not wait (${DEL}s)"; else no "L38 negative control: ${DEL}s [$(mjr)] — the mutant had no effect"; fi
	dr l38nega misc-l38 "this 99zz unclaimed 0" "none" "this helper member radio|none" || return 1
	if has "(prov=unclaimed"; then ok "L38 negative control a: misc-l38 keeps 99zz's unclaimed"; else no "L38 negative a: [$(mjr)]"; fi
	# L42
	dr l42 - "this helper member radio" "none" || return 1
	if has "member: no usable ota-armed.mesh — neighbours required (fail-closed)" && has "mesh join required: 1 "; then ok "L42: no arm file -> neighbours required (fail-closed), required: 1"; else no "L42: [$(mjr)]"; fi
	dr l42w - "this helper member radio" "ab radio" || return 1
	if has "member: armed in radio-only mode" && has "mesh join required: 0 "; then ok "L42 write half: a correct radio arm file -> radio-only, required: 0 (so (6a)'s no-file assertion discriminates)"; else no "L42 write half: [$(mjr)]"; fi
	dr l42neg misc-l42 "this helper member radio" "none" || return 1
	if has "mesh join required: 0 "; then ok "L42 negative control: misc-l42 -> required: 0"; else no "L42 negative control: [$(mjr)] — the mutant had no effect"; fi
	# L43
	dr l43 - "this helper member radio" "other radio" || return 1; s=$ARMAFTER
	if has "mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)" && ! has "no usable"; then ok "L43: another boot's arm file ignored -> required: 1, no 'no usable'"; else no "L43: [$(mjr)]"; fi
	if [ -n "$s" ]; then ok "L43: the arm file is unchanged at the judgement ($s)"; else no "L43: the arm file vanished during the arm"; fi
	dr l43neg misc-l43 "this helper member radio" "other radio" || return 1
	if has "mesh join required: 0 "; then ok "L43 negative control: misc-l43 -> required: 0"; else no "L43 negative control: [$(mjr)] — the mutant had no effect"; fi
	# L51
	dr l51 - "this helper member radio" "ab joined" || return 1
	if has "mesh join required: 1 "; then ok "L51: arm boot joined -> required: 1"; else no "L51: [$(mjr)]"; fi
	dr l51neg misc-l51 "this helper member radio" "ab joined" || return 1
	if has "mesh join required: 0 "; then ok "L51 negative control: misc-l51 -> required: 0"; else no "L51 negative control: [$(mjr)] — the mutant had no effect"; fi
}
health_wait(){	# <ts before> -> HW (the health line), rc 0 when refreshed and bluetoothd=1 hci0_powered=1 within 40 s
	local t0=$1 i=0 t1
	while [ $i -lt 8 ]; do
		sleep 5; HW=$(qr "$HEALTH"); t1=${HW#*ts=}; t1=${t1%% *}
		if [ "${t1:-0}" -gt "${t0:-0}" ] 2>/dev/null; then case "$HW" in *"bluetoothd=1 hci0_powered=1"*) return 0 ;; esac; fi
		i=$((i + 1))
	done
	return 1
}
svcarms(){
	local p0 p1 t0 t1 o k b0
	# L11
	p0=$(qr 'pidof batman-provhelper'); t0=$(hts)
	q '/etc/init.d/batman-provhelper restart >/dev/null 2>&1'; sleep 20
	p1=$(qr 'pidof batman-provhelper'); t1=$(hts); o=$(qr 'ls -ln /tmp/run/batman-prov/helper.sock')
	if [ -n "$p1" ] && [ "$p1" != "$p0" ]; then ok "L11: helper restarted ($p0 -> $p1)"; else no "L11: helper pid $p0 -> $p1"; fi
	case "$o" in srw-rw----*" 0 "*" 471 "*) ok "L11: helper.sock root:471 0660" ;; *) no "L11: helper.sock [$o]" ;; esac
	if [ "${t1:-0}" -gt "${t0:-0}" ] 2>/dev/null; then ok "L11: health refreshed (ts $t0 -> $t1)"; else no "L11: health ts $t0 -> $t1"; fi
	q '/etc/init.d/batman-provhelper stop >/dev/null 2>&1; : > /tmp/run/batman-prov/dv-plant; /etc/init.d/batman-provhelper start >/dev/null 2>&1'
	t0=$(hts); sleep 20; t1=$(hts); o=$(qr "logread | grep 'sock: unexpected' | tail -1")
	if grep -q 'refusing to start' <<< "$o"; then ok "L11 negative control: a planted file -> 'sock: unexpected … refusing to start'"; else no "L11 negative control: no refusal line"; fi
	if [ "$t1" = "$t0" ]; then ok "L11 negative control: health not refreshed while refused (ts $t1)"; else no "L11 negative control: health moved ($t0 -> $t1) — the health assertion does not discriminate"; fi
	q 'rm -f /tmp/run/batman-prov/dv-plant; /etc/init.d/batman-provhelper restart >/dev/null 2>&1'; sleep 20
	if [ -n "$(qr 'pidof batman-provhelper')" ] && [ "$(qr 'ls -A /tmp/run/batman-prov')" = helper.sock ]; then ok "L11: plant removed, helper back"; else no "L11: helper not back after the negative control"; fi
	# L9 / L10 (dbus: bluetoothd is restarted after it, it holds a dbus connection)
	for k in bluetoothd dbus; do
		t0=$(hts); q "/etc/init.d/$k restart >/dev/null 2>&1"; [ $k = dbus ] && q '/etc/init.d/bluetoothd restart >/dev/null 2>&1'
		if health_wait "$t0"; then ok "L$([ $k = dbus ] && echo 10 || echo 9): $k restart -> health ok ($HW)"; else no "L $k restart: health [$HW]"; fi
	done
	q '/etc/init.d/bluetoothd stop >/dev/null 2>&1'; sleep 25; o=$(qr "$HEALTH")
	case "$o" in *"bluetoothd=0"*) ok "L9 negative control: bluetoothd stopped -> health bluetoothd=0" ;; *) no "L9 negative control: health [$o] — the health assertion does not discriminate" ;; esac
	t0=$(hts); q '/etc/init.d/bluetoothd start >/dev/null 2>&1'
	if health_wait "$t0"; then ok "bluetoothd back, health ok"; else no "bluetoothd not back: [$HW]"; fi
	# L27
	q '/etc/init.d/dropbear restart >/dev/null 2>&1'; sleep 5
	if [ "$(qr 'echo UP')" = UP ] && pk_proof; then ok "L27: dropbear restarted, the lab key logs in"; else no "L27: the lab key does not log in after the dropbear restart"; fi
	k=$(mktemp -d); ssh-keygen -q -t ed25519 -N '' -f "$k/k" >/dev/null 2>&1
	# on the publickey-only listener: the lab key is accepted (pk_proof above) and a throwaway key is refused — against the
	# main dropbear an OPEN node lets anything in by `none` (run 1 FAIL, 2026-10-28)
	if [ ! -s "$k/k" ]; then inv "L27 negative control: ssh-keygen made no key"
	elif pk_refused "$k/k"; then ok "L27 negative control: a throwaway key is refused (publickey-only listener)"
	else no "L27 negative control: a throwaway key was not refused"; fi
	rm -rf "$k"
	# L3
	o=$(qr "$ST"); b0=$(field "$o" boot)
	q '(batman-slot reboot committed prov-dv-254 </dev/null >/dev/null 2>&1 &)'
	pr_find 900 "$b0" || return 1
	o=$(qr 'tail -1 /opt/batdata/log/boot-reasons.log'); say "boot-reasons: $o"
	case "$o" in *"prev=CLEAN"*"trigger=prov-dv-254"*) ok "L3: clean reboot -> prev=CLEAN (trigger prov-dv-254)" ;; *) no "L3: boot-reasons [$o]" ;; esac
	if o=$(pr_trial_line 'batman-provhelper.*boot rc=' 6); then ok "L3: helper ${o##*]: }"; else no "L3: no helper 'boot rc=' line after the reboot"; fi
}
pr_begin 2400 || { pr_result; exit 1; }
dryarms || { mn stop all >/dev/null 2>&1; mn restore >/dev/null 2>&1; pr_abort "dry-run arms"; pr_result; exit 1; }
svcarms || { pr_abort "service arms"; pr_result; exit 1; }
pr_end
pr_result
