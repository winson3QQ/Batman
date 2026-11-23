#!/bin/bash
# scripts/dv/test-prov-update-254.sh [UNIT] — offline test of prov-update-254.sh's judges and host flows
# (docs/design/254-v16-ud.md §9), no node: the unit is sourced with UD_LIB_ONLY=1 (judges) or in full with stub ssh /
# scp / wsl.exe on PATH (pr_pc, the cut-arm poll, the abort order). Every judge gets its PASS case and the cases that
# must FAIL or be INVALID. Prints "test-prov-update: N passed, M failed"; zero cases = FAIL.
#   UD20c: Y must have another SHA256SUMS — real generators + signrel on a small V (malicious 1 keeps V's sums -> INVALID)
#   UD4 judge, kill / cut judges, the observe gate, the UD13 --check text, the S0 status, the mode check under a commit
#   stub (umask 077 -> FAIL), pr_pc's run-time refusal of an unguarded prepare / apply (no ssh call), the guarded command
#   shape, the cut poll (MISS -> INVALID, no pr_find; a lost connection after PRE-B -> pr_find), pl undo before
#   pr_restore in pr_end / pr_abort, back_to_a first on B committed.
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); U=${1:-$H/scripts/dv/prov-update-254.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=0; F=0; ok(){ echo "ok   $*"; P=$((P + 1)); }; bad(){ echo "FAIL $*"; F=$((F + 1)); }
chk(){ local l=$1; shift; if "$@"; then ok "$l"; else bad "$l"; fi; }
nchk(){ local l=$1; shift; if "$@"; then bad "$l"; else ok "$l"; fi; }
# stub world: ssh logs its command and answers from $T/ans (a script), scp / wsl.exe succeed
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
c=""; while [ $# -gt 0 ]; do case "$1" in -o|-p|-i) shift 2 ;; root@*) shift; c="$*"; break ;; *) shift ;; esac; done
[ -z "$c" ] && c=$(cat)
printf '%s\n' "SSH $c" >> "$UDT/ssh.log"
[ -x "$UDT/ans" ] && exec "$UDT/ans" "$c"
exit 0
X
printf '#!/bin/sh\necho "SCP $*" >> "$UDT/ssh.log"\n' > "$T/bin/scp"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wsl.exe"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod 755 "$T/bin"/*
export UDT=$T PATH="$T/bin:$PATH" TEMP=$T NODE=10.9.9.9 PEER=10.9.9.8
lib(){ ( UD_LIB_ONLY=1; . "$U"; "$@" ); }

# ---- judges
S="RESULT update.status code=0 phase=0 percent=0"
chk "ud_phase: idle = phase 0, no reason, no sha" lib ud_phase "$S" 0 - -
nchk "ud_phase: phase 0 + 23 is not 'no reason'" lib ud_phase "RESULT update.status code=0 phase=0 percent=0 fail_reason=23 sha=0011223344556677" 0 -
chk "ud_phase: 0 + 22 matches" lib ud_phase "RESULT update.status code=0 phase=0 percent=0 fail_reason=22 sha=0011223344556677" 0 22
nchk "ud_phase: code 20 never matches" lib ud_phase "RESULT update.status code=20" 0 -
[ "$(lib ud_s0_status "$S")" = ok ] && ok "S0 status: phase 0 / no reason / no sha -> ok" || bad "S0 status ok"
case "$(lib ud_s0_status "RESULT update.status code=0 phase=0 percent=0 sha=0011223344556677 version=1.5.14-wsl.36")" in "inv not S0"*) ok "S0 status: a live update-last (row 11, a sha) -> INVALID" ;; *) bad "S0 status row 11" ;; esac
case "$(lib ud_s0_status "RESULT update.status code=0 phase=3 percent=100")" in "inv not S0"*) ok "S0 status: phase 3 -> INVALID" ;; *) bad "S0 status phase 3" ;; esac
LOG='Nov 23 10:00:00 daemon.err batman-provhelper[4204]: update.check: refused, reason 11 (S: version unparsable)
Nov 23 10:00:01 user.notice batman-dv-ud: mark x'
chk "ud_why: the helper's line" lib ud_why "$LOG" "S: version unparsable"
nchk "ud_why: a line of another tag does not count" lib ud_why "$LOG" "mark x"
chk "ud_caps: the caps line" lib ud_caps "$(printf 'PROVCLIENT caps=uc2,bo2,rk1,pg2,nopsk\nRESULT x code=0')" new
nchk "ud_caps: no caps line -> refused (INVALID tool)" lib ud_caps "RESULT x code=0" new
chk "ud_caps: the pre-UD binary is exempt" lib ud_caps "RESULT x code=20" old
chk "UD13 P: --check rc 5 naming the ssid, no (unpersistable" lib ud_check_text "p5 stale: wireless.default_radio0.ssid" 5
nchk "UD13 P: '(unpersistable' -> FAIL" lib ud_check_text "p5 stale: wireless.default_radio0.ssid (unpersistable value)" 5
nchk "UD13 P: rc 0 -> FAIL" lib ud_check_text "fresh" 0
# observe gate
OBS=$'run=r\nversion=1.5.14-wsl.36\nmac=88:a2:9e:b5:6c:89\ndate=x\nUD9-OBS fd1=/dev/mmcblk0p4 pos=1,2,3 sq=9 result=ok\nlog_sha256=ab'
[ "$(lib ud_obs_gate "$OBS" 1.5.14-wsl.36 88:a2:9e:b5:6c:89)" = ok ] && ok "kill-arm gate: matching observe file -> ok" || bad "gate ok"
for c in "|no observe file" "1.5.14-wsl.37|another version" "MAC|another node" "BAD|failed"; do
	v=1.5.14-wsl.36; m=88:a2:9e:b5:6c:89; o=$OBS
	case "${c%%|*}" in "") o="" ;; MAC) m=11:22:33:44:55:66 ;; BAD) o=${OBS/result=ok/result=bad} ;; *) v=${c%%|*} ;; esac
	case "$(lib ud_obs_gate "$o" "$v" "$m")" in "inv premise not shown"*"${c#*|}"*) ok "kill-arm gate: ${c#*|} -> INVALID premise not shown" ;; *) bad "gate ${c#*|}: $(lib ud_obs_gate "$o" "$v" "$m")" ;; esac
done
# kill judge
SQ=117471808; ST_A='mac=x slot=A ver=v trial_rc=1 dt_try=00000000 hold=[] held=0 badslot=[] up=100 boot=abcd1234'
FIRE="UD9-FIRE mode=kill pos=60000000 pos_final=70000000 sq=$SQ orphan=5000 dd=5001"
ST22="RESULT update.status code=0 phase=0 percent=0 fail_reason=22 sha=0011223344556677"
BI1=$'-- slot B\nbad=1 verified='; BI0=$'-- slot B\nbad=0 verified=x y'
TRV='SLOT VERIFY slot=B result=rootfs mismatch'
kj(){ lib ud_kill_judge "$@"; }
o=$(kj "$FIRE" $SQ 1 PASS "$ST22" "$BI1" "$ST_A" "$TRV"); grep -q '^PASS UD9 kill' <<< "$o" && ! grep -q '^FAIL\|^INVALID' <<< "$o" && grep -q 'supporting: SLOT VERIFY' <<< "$o" && ok "kill judge: VERIFY != ok, no SLOT DIE -> PASS" || bad "kill judge pass: $o"
o=$(kj "$FIRE" $SQ 0 PASS "$ST22" "$BI1" "$ST_A" "$TRV"); grep -q '^FAIL UD9 kill: the orphan' <<< "$o" && ! grep -q '^PASS' <<< "$o" && ok "kill judge: no orphan exit -> FAIL" || bad "kill no exit: $o"
o=$(kj "$FIRE" $SQ 1 PASS "$ST22" "$BI0" "$ST_A" "$TRV"); grep -q '^FAIL UD9 kill: bootinfo B bad=\[0\]' <<< "$o" && ok "kill judge: bad=0 -> FAIL" || bad "kill bad=0: $o"
o=$(kj "${FIRE/pos_final=70000000/pos_final=110000000}" $SQ 1 PASS "$ST22" "$BI1" "$ST_A" "$TRV"); grep -q '^INVALID UD9 kill: too late' <<< "$o" && ok "kill judge: pos_final >= SQ - 8 MiB -> INVALID" || bad "kill late: $o"
o=$(kj "UD9-MISS timeout" $SQ 1 PASS "$ST22" "$BI1" "$ST_A" ""); grep -q '^INVALID UD9 kill: UD9-MISS timeout' <<< "$o" && ok "kill judge: UD9-MISS -> INVALID" || bad "kill miss: $o"
# cut judge + cut flow
PRE="UD9-FIRE mode=cut pos=60000000 sq=$SQ t0=10000
UD9-PRE-B pos=61000000 fsync_s=0.04"
BR='Sun Nov 23 boot_id=x UNCLEAN — no shutdown ran (hang→hardware watchdog, reboot -f, sysrq or reflash); last console log saved under /opt/batdata/crash; hints: sysrq'
o=$(lib ud_cut_judge "$PRE" $SQ "$ST22" "$BI1" "$ST_A" "$BR"); grep -q '^PASS UD9 cut' <<< "$o" && ok "cut judge: PRE-B below SQ - 8 MiB, bad=1, A, 0 + 22, sysrq hint -> PASS" || bad "cut pass: $o"
o=$(lib ud_cut_judge "UD9-FIRE mode=cut pos=1 sq=$SQ t0=1
UD9-PRE-B pos=2 fsync_s=0.01
UD9-MISS late p3=115000000" $SQ "$ST22" "$BI1" "$ST_A" "$BR"); grep -q '^INVALID UD9 cut: UD9-MISS late p3=115000000 (no cut was made)' <<< "$o" && ok "cut judge: MISS late -> INVALID" || bad "cut miss: $o"
o=$(lib ud_cut_judge "UD9-FIRE mode=cut pos=1 sq=$SQ t0=1" $SQ "$ST22" "$BI1" "$ST_A" "$BR"); grep -q '^INVALID UD9 cut: no UD9-PRE-B' <<< "$o" && ok "cut judge: no PRE-B line -> INVALID" || bad "cut no pre-b: $o"
o=$(lib ud_cut_judge "$PRE" $SQ "$ST22" "$BI1" "$ST_A" "${BR/hints: sysrq/}"); grep -q '^FAIL UD9 cut: boot-reasons without the sysrq hint' <<< "$o" && ok "cut judge: no sysrq hint -> FAIL" || bad "cut hint: $o"
[ "$(lib ud_cut_flow "UD9-FIRE mode=cut pos=1
UD9-MISS late p3=none")" = "invalid UD9-MISS late p3=none" ] && ok "cut flow: a MISS line -> invalid" || bad "cut flow miss"
[ "$(lib ud_cut_flow "LOST $PRE")" = cut ] && ok "cut flow: connection lost after PRE-B -> cut" || bad "cut flow lost"
case "$(lib ud_cut_flow "LOST UD9-FIRE mode=cut pos=1 sq=9 t0=1")" in invalid*) ok "cut flow: connection lost before PRE-B -> invalid" ;; *) bad "cut flow lost early" ;; esac
# UD4 judge
PAN='x boot_id=y PANIC (1 pstore record(s) saved under /opt/batdata/crash)'
[ "$(lib ud4_judge "$PAN" "20261123_abcd_dmesg-ramoops-0" 1 | cut -d' ' -f1)" = PASS ] && ok "UD4 judge: PANIC + a record with the root-mount text -> PASS" || bad "UD4 pass"
[ "$(lib ud4_judge "$PAN" "20261123_abcd_dmesg-ramoops-0" 0 | cut -d' ' -f1)" = FAIL ] && ok "UD4 judge: a decompressed PANIC record without it -> FAIL" || bad "UD4 fail"
lib ud4_judge "$PAN" "20261123_abcd_dmesg-ramoops-0.enc.z" 0 | grep -q '^INVALID UD4: record not readable' && ok "UD4 judge: .enc.z only -> INVALID" || bad "UD4 enc.z"
lib ud4_judge "x CLEAN: reboot by update.apply" "" 0 | grep -q '^INVALID UD4: B boot not proven' && ok "UD4 judge: CLEAN -> INVALID (B boot not proven)" || bad "UD4 clean"
lib ud4_judge "x UNCLEAN (power loss: no shutdown marker)" "" 0 | grep -q '^INVALID UD4: UNCLEAN' && ok "UD4 judge: UNCLEAN -> INVALID with the line" || bad "UD4 unclean"
# mode check against a commit stub: the file rewritten under umask 077 no longer has the S0 mode
mkdir "$T/w"; ( umask 022; : > "$T/w/wireless" ); m0=$(ls -ln "$T/w/wireless" | awk '{print $1}')
commit(){ ( umask "$1"; rm -f "$T/w/wireless"; : > "$T/w/wireless" ); ls -ln "$T/w/wireless" | awk '{print $1}'; }
chk "mode check: a commit under umask 022 keeps the S0 mode" lib ud_mode "$m0" "$(commit 022)"
nchk "mode check: a commit stub under umask 077 -> FAIL" lib ud_mode "$m0" "$(commit 077)"
nchk "mode check: an unreadable S0 mode never passes" lib ud_mode "" ""

# ---- UD20c's Y: a real V, the real generators and signrel (malicious 1 keeps V's SHA256SUMS -> INVALID)
PY=${H4_PY:-}; [ -n "$PY" ] || { OH=$(getent passwd "$(stat -c %U "$H")" | cut -d: -f6); PY=$OH/.batman-dv/peer-venv/bin/python; [ -x "$PY" ] || PY=$HOME/.batman-dv/peer-venv/bin/python; }
if [ -x "$PY" ] && command -v mksquashfs >/dev/null; then
	mkdir -p "$T/r/etc" "$T/v/boot/overlays"; head -c 200000 /dev/urandom > "$T/r/etc/blob"; mksquashfs "$T/r" "$T/v/root.squashfs" -quiet -noappend >/dev/null
	printf 'x\n' > "$T/v/boot/config.txt"; head -c 600 /dev/urandom > "$T/v/boot/overlays/a.dtbo"
	( cd "$T/v" && sha256sum root.squashfs && find boot -type f | sort | while read -r x; do sha256sum "$x"; done ) > "$T/v/SHA256SUMS"
	printf 'board=ekh-bcm2711\nsize=%s\nrelease=1.5.14-wsl.36\n' "$(wc -c < "$T/v/root.squashfs")" > "$T/v/metadata"
	tar -C "$T/v" -czf "$T/V.tgz" SHA256SUMS metadata boot root.squashfs; VS=$(sha256sum "$T/V.tgz" | cut -d' ' -f1)
	G=$H/scripts/dv/data/p3-payloads.sh
	bash "$G" malicious 1 "$T/V.tgz" "$VS" "$T/m1.tgz" >/dev/null 2>&1; bash "$G" badpayload "$T/V.tgz" "$VS" "$T/bad.tgz" >/dev/null 2>&1
	sums(){ "$PY" "$H/tests/tools/peer/signrel.py" "$1" --board ekh-bcm2711 --allow-no-key 2>&1 | tail -1 | sed -n 's/.* sums=\([0-9a-f]*\).*/\1/p'; }
	X=$(sums "$T/V.tgz"); Y1=$(sums "$T/m1.tgz"); YB=$(sums "$T/bad.tgz")
	nchk "UD20c: Y = malicious 1's manifest (V's SHA256SUMS) -> refused (INVALID)" lib ud_y_differs "$Y1" "$X"
	chk "UD20c: Y = the badpayload manifest -> sums_sha(Y) != X" lib ud_y_differs "$YB" "$X"
	nchk "UD20c: an unreadable sums never passes" lib ud_y_differs "" "$X"
else bad "UD20c fixture needs the peer venv python ($PY) and mksquashfs"; fi

# ---- full source: pr_pc refusal / guard shape, the cut poll, the abort order (stubbed node)
src='PR_UNIT=prov-update-254; . "'"$H"'/scripts/dv/prov-254.sh"; UD_LIB_ONLY=1; . "'"$U"'"'
: > "$T/ssh.log"
o=$(bash -c "$src; PCD=/x; WSLK=/w; op=update-apply; pr_pc h0.pem -- \$op 04aa 00; echo rc=\$?" 2>&1)
grep -q '^FAIL prov-update-254: unguarded update-apply: refused, nothing sent' <<< "$o" && ! grep -q 'update-apply' "$T/ssh.log" && ok "pr_pc: an unguarded update-apply (op built at run time) is refused, no ssh call" || bad "pr_pc refusal: $o $(cat "$T/ssh.log")"
o=$(bash -c "$src; PCD=/x; pr_pc h0.pem -- update-prepare 04aa 00" 2>&1); grep -q 'unguarded update-prepare' <<< "$o" && ! grep -q 'update-prepare' "$T/ssh.log" && ok "pr_pc: an unguarded update-prepare is refused, no ssh call" || bad "prepare refusal: $o"
o=$(bash -c "$src; PCD=/x; pr_pc h0.pem GUARD=prepare:abcd1234 -- update-apply 04aa 00" 2>&1); grep -q 'GUARD=prepare:abcd1234 does not match update-apply' <<< "$o" && ok "pr_pc: GUARD of the other form is refused" || bad "guard mismatch: $o"
o=$(bash -c "$src; PCD=/x; pr_pc h0.pem GUARD=apply:ABC -- update-apply 04aa 00" 2>&1); grep -q 'is not a boot8' <<< "$o" && ok "pr_pc: a GUARD boot that is not a boot8 is refused" || bad "guard boot: $o"
o=$(bash -c "$src; PCD=/x; pr_pc h0.pem GUARD=apply:abcd1234 -- update-status 04aa" 2>&1); grep -q 'GUARD= on update-status' <<< "$o" && ok "pr_pc: GUARD on another op is refused" || bad "guard other op: $o"
: > "$T/ssh.log"; bash -c "$src; PCD=/x; pr_pc h0.pem GUARD=apply:abcd1234 -- update-apply 04aa 00" >/dev/null 2>&1
c=$(grep '^SSH ' "$T/ssh.log" | tail -1)
case "$c" in *"[ \"\$b\" = 'abcd1234' ] && [ \"\$a\" = 'A' ]"*"tryboot_flag=0"*"then  PROVCLIENT_TIMEOUT_S=240 /x/provclient node update-apply 04aa 00; else echo \"WRONG-STATE"*) ok "pr_pc GUARD=apply: one ssh command = boot / A / committed / DISARMED check, then the provclient line" ;; *) bad "guarded apply command: [$c]" ;; esac
: > "$T/ssh.log"; bash -c "$src; PCD=/x; pr_pc h0.pem GUARD=prepare:abcd1234 PCBIN=old -- update-prepare 04aa 00" >/dev/null 2>&1
c=$(grep '^SSH ' "$T/ssh.log" | tail -1); case "$c" in *"tryboot_flag"*) bad "guarded prepare disarms (it must not reboot-check)" ;; *"/x/provclient.old node update-prepare"*) ok "pr_pc GUARD=prepare PCBIN=old: guarded, the old binary" ;; *) bad "guarded prepare: [$c]" ;; esac
# the cut poll: a MISS line -> INVALID, pr_find never called; a lost connection after PRE-B -> pr_find
cat > "$T/ans" <<'X'
#!/bin/bash
n=$(cat "$UDT/n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$UDT/n"
case "$UDT_MODE" in
miss) printf 'UD9-FIRE mode=cut pos=1 sq=9 t0=1\nUD9-PRE-B pos=2 fsync_s=0.01\nUD9-MISS late p3=none\n' ;;
cut) [ $n -ge 2 ] && exit 255; printf 'UD9-FIRE mode=cut pos=1 sq=9 t0=1\nUD9-PRE-B pos=2 fsync_s=0.01\n' ;;
esac
X
chmod 755 "$T/ans"
for m in miss cut; do rm -f "$T/n"
	o=$(UDT_MODE=$m bash -c "$src; pr_find(){ echo PR_FIND \$*; return 0; }; ud_cut_wait abcd1234; echo V=\$UDCUTV F=\$UDCUTF" 2>&1)
	case "$m" in
		miss) grep -q '^V=invalid UD9-MISS late p3=none F=-$' <<< "$o" && ! grep -q PR_FIND <<< "$o" && ok "cut poll: UD9-MISS late -> INVALID, no pr_find" || bad "cut poll miss: $o" ;;
		cut) grep -q '^PR_FIND 900 abcd1234$' <<< "$o" && grep -q '^V=cut F=0$' <<< "$o" && ok "cut poll: lost connection after PRE-B -> pr_find 900 <old boot>" || bad "cut poll cut: $o" ;;
	esac
done
rm -f "$T/ans"
# pr_end / pr_abort: the journal (pl undo) before pr_restore; back_to_a first on B committed
stubs='pl(){ echo "CALL pl $*" >&2; case "$1" in renew) echo ARMED ;; undo) echo "UNDO undo_run host end rc=0" ;; esac; }
pr_restore(){ echo "CALL pr_restore" >&2; return 0; }; pr_brewrite(){ echo "CALL pr_brewrite" >&2; return 0; }
pr_finish_snap(){ echo "CALL pr_finish_snap" >&2; }; pr_release(){ echo "CALL pr_release" >&2; }; pr_peer_after(){ :; }
pr_ust_end(){ echo "CALL pr_ust_end" >&2; }; qr(){ echo "protB=[V]"; }; PR_V=V'
o=$(bash -c "$src; $stubs; PR_SNAPPED=1; PR_WROTE_B=1; pr_end wrote-b" 2>&1 | grep '^CALL' | tr '\n' ' ')
case "$o" in "CALL pl renew 1200 CALL pl undo CALL pr_restore CALL pr_brewrite CALL pr_ust_end CALL pr_finish_snap CALL pr_release ") ok "pr_end: pl undo before pr_restore, the status compare after the B rewrite" ;; *) bad "pr_end order: [$o]" ;; esac
o=$(bash -c "$src; $stubs; PR_SNAPPED=1; PR_WROTE_B=1; pr_abort x" 2>&1 | grep '^CALL' | tr '\n' ' ')
case "$o" in "CALL pl renew 1200 CALL pl undo CALL pr_restore CALL pr_brewrite CALL pr_ust_end CALL pr_finish_snap CALL pr_release ") ok "pr_abort after a prepare: pl undo, pr_restore, pr_brewrite, status compare, finish" ;; *) bad "pr_abort order: [$o]" ;; esac
o=$(bash -c "$src; qr(){ echo 'mac=x slot=B ver=V trial_rc=1 dt_try=00000000 hold=[] held=0 badslot=[] up=1 boot=abcd1234'; }; back_to_a(){ echo CALL back_to_a; return 1; }; nb(){ echo CALL nb \$*; }; pl(){ echo CALL pl \$*; }; pr_restore_cycle" 2>&1)
grep -q '^CALL back_to_a' <<< "$o" && ! grep -q 'CALL nb' <<< "$o" && grep -q 'NEEDS-PERSON' <<< "$o" && ok "pr_restore on B committed: back_to_a first (nothing restored when it fails)" || bad "B committed: $o"
# ---- the real arm functions against a stubbed node (device run 2026-11-23 on 0a6cb73: every arm aborted on a script bug
# the judges-only cases above never reached — a global set inside $(ud_check …) and an empty `ls -ln` after an upload).
# arm_refuse and arm_write run to their end here; each must finish (no "unbound variable", pr_end reached) and say what
# it saw: step 0 judged from the helper line it read (UDLOG), an absent upload INVALID with its evidence.
mkdir -p "$T/smoke/out/1.5.14-wsl.36/ekh-bcm2711"; head -c 4096 /dev/urandom > "$T/smoke/out/1.5.14-wsl.36/ekh-bcm2711/batman-1.5.14-wsl.36-ekh-bcm2711-ab-payload.tar.gz"
head -c 4096 /dev/urandom > "$T/smoke/gen.tgz"
smoke_stubs='
H0=04$(printf "%0128d" 0); OUTS=$UDT/smoke/out; TOOLS=$UDT/smoke; NODE=10.9.9.9
pr_begin(){ return 0; }; pr_h0(){ return 0; }; pr_pc_place(){ return 0; }; pr_end(){ echo "STUB pr_end $*"; }
pr_lease_renew(){ return 0; }; pr_slot_ticks(){ echo 1; }; pr_slot_free(){ ok "slot flock free (stub)"; }; sleep(){ :; }
hostp(){ echo "$UDT/smoke/gen.tgz"; }; boot8(){ echo abcd1234; }
wsl_(){ case "$*" in
	*signrel.py*) echo "MANIFEST sha=ab version=v board=b size=1 serial=2 sums=$(printf "%064d" 7)" ;;
	*manifest.hex*) echo a1 ;;
	*"tar -tzvf"*) echo "-rw-r--r-- 0/0 117471856 2026-11-22 20:28 root.squashfs" ;;
	*p3-payloads.sh\ malicious\ *) a="$*"; k=${a#*malicious }; echo "ACCEPT mal${k%% *} ok"; echo "PAYLOAD-SHA ab" ;;
	*p3-payloads.sh*) for k in mutate badpayload; do case "$*" in *" $k "*) echo "ACCEPT $k ok"; echo "PAYLOAD-SHA ab" ;; esac; done ;;
	esac; return 0; }
pr_pc(){ local pb=new a op; for a in "$@"; do [ "$a" = PCBIN=old ] && pb=old; done
	while [ "$1" != -- ]; do shift; done; op=$2
	[ $pb = new ] && echo "PROVCLIENT caps=uc2,bo2,rk1,pg2,nopsk"
	case "$op" in
		update-check) if [ $pb = old ]; then echo "RESULT update.check code=20"; else echo "RESULT update.check code=0 ok=true ram=1"; fi ;;
		update-status) echo "RESULT update.status code=0 phase=0 percent=0" ;;
		bulk-open) echo "RESULT bulk.open code=0 ssid=\"s\" ip=\"10.41.0.1\" port=8095 expires=900" ;;
		bulk-close) echo "RESULT bulk.close code=0" ;;
		update-prepare|update-apply) echo "RESULT update.${op#update-} code=24 reason=15" ;;
	esac; }
q(){ case "$*" in *"joinwatch stop"*) rm -f "$UDT/smoke/jw" ;; *"joinwatch start"*) touch "$UDT/smoke/jw" ;; esac; return 0; }
qr(){ case "$*" in
	*"echo \"mac="*) echo "mac=88:a2:9e:b5:6c:89 slot=A ver=1.5.14-wsl.36 trial_rc=1 dt_try=00000000 hold=[] held=0 badslot=[] up=100 boot=abcd1234" ;;
	*BATMAN_BOARD*) echo ekh-bcm2711 ;;
	*"halow-setkey --status"*) echo "ap default_radio0 ssid=x key=set disabled=0" ;;
	*"/etc/config/wireless"*) echo "-rw------- 1 0 0 1100 Aug 17 04:40 /etc/config/wireless" ;;
	*logread*) printf "%s\n" "x batman-provhelper[1]: verb update.check refused: code 20 (arg 1: want 0 bytes)" "x batman-provhelper[1]: p5 stale only in keys P3 added: --save rc 0" ;;
	*"pidof joinwatch"*) [ -e "$UDT/smoke/jw" ] && echo 4730 ;;
	*"--check 2>&1"*) printf "p5 stale: wireless.default_radio0.ssid\nrc=5\n" ;;
	*"--check >/dev/null"*) echo 0 ;;
	*"bootinfo B"*) echo "bad=0 verified=x y"; echo rc=0 ;;
	*"ls -ln /tmp/run/batman-provd-bulk/payload"*) [ "${SMOKE_UPLOAD:-present}" = present ] && echo "-rw------- 1 471 471 4096 Nov 23 12:00 /tmp/run/batman-provd-bulk/payload" ;;
	esac; return 0; }
pl(){ case "$1" in undo-add) echo "UNDO-ADDED 1 p6 - $2" ;; ssid-hex) echo "HEX=6162 RT=ok" ;; ssid-set) echo "SSID-SET ok" ;; undo-done) echo "UNDO-DONE $2" ;; esac; }
:'
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
c=""; while [ $# -gt 0 ]; do case "$1" in -o|-p|-i) shift 2 ;; root@*) shift; c="$*"; break ;; *) shift ;; esac; done
case "$c" in
	*"cat > /tmp/run/batman-provd-bulk/payload"*) cat >/dev/null; echo 471; case "$c" in *cat-rc*) echo cat-rc=0 ;; esac ;;
	*"wc -c <"*) echo 99; wc -c < "$UDT/smoke/gen.tgz"; sha256sum < "$UDT/smoke/gen.tgz" ;;
esac
exit 0
X
chmod 755 "$T/bin/ssh"
o=$(bash -c "$src; $smoke_stubs; arm_refuse" 2>&1); rc=$?
if ! grep -q 'unbound variable' <<< "$o" && grep -q '^STUB pr_end' <<< "$o" && grep -q "^PASS prov-update-254: step 0: the pre-UD provclient's update.check -> code 20" <<< "$o"; then
	ok "arm_refuse against a stub node runs to its end; step 0 judged from the helper line ud_check read (UDLOG reaches the arm)"
else bad "arm_refuse smoke: rc=$rc $(grep -E 'unbound|step 0|STUB pr_end' <<< "$o" | head -3 | tr '\n' '|')"; fi
grep -q '^PASS prov-update-254: UD13: update.check ok=true' <<< "$o" && ok "arm_refuse smoke: UD13 judged from UDLOG after a direct ud_ul" || bad "arm_refuse smoke: UD13 [$(grep 'UD13' <<< "$o" | head -2 | tr '\n' '|')]"
o=$(SMOKE_UPLOAD=absent bash -c "$src; $smoke_stubs; arm_write" 2>&1); rc=$?
if ! grep -q 'unbound variable' <<< "$o" && grep -q '^STUB pr_end wrote-b' <<< "$o" \
	&& [ "$(grep -c '^INVALID prov-update-254: upload: /tmp/run/batman-provd-bulk/payload is absent right after a 471 write' <<< "$o")" -ge 4 ]; then
	ok "arm_write with the upload absent after the write: INVALID per upload (with ls / status evidence), the arm goes on to pr_end"
else bad "arm_write smoke (upload absent): rc=$rc $(grep -E 'unbound|absent|STUB pr_end' <<< "$o" | tail -4 | tr '\n' '|')"; fi
o=$(bash -c "$src; $smoke_stubs; pr_pc(){ while [ \"\$1\" != -- ]; do shift; done; echo \"RESULT \$2 code=0\"; }; ud_status >/dev/null; ud_sync; echo \"INV=\$invalid\"" 2>&1)
grep -q '^INVALID prov-update-254: provclient printed no caps line' <<< "$o" && grep -q '^INV=1$' <<< "$o" && ok "a verdict made inside \$(…) (no caps line in ud_status) is printed and counted" || bad "subshell verdict: $(tr '\n' '|' <<< "$o" | cut -c1-200)"
echo "test-prov-update: $P passed, $F failed"; [ $F = 0 ] && [ $P -gt 0 ]
