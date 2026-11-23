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
pr_begin(){ return 0; }; pr_h0(){ return 0; }; pr_pc_place(){ return 0; }; pr_end(){ echo "STUB pr_end $*"; echo member > "$UDT/smoke/state"; }
UD_S0_DIR=$UDT/smoke/s0; [ -s "$UDT/smoke/state" ] || echo member > "$UDT/smoke/state"
pr_keys(){ ENC=04$(printf "%0128d" 1); return 0; }; pk_proof(){ return 0; }; pr_needs_person(){ echo "NEEDS-PERSON $*"; echo NP >> "$UDT/smoke/calls"; PR_PERSON=1; echo F >> "$UDV"; return 1; }
pr_info(){ echo "state=$(cat "$UDT/smoke/state") gen=2 owners=1 rm=1"; }
nbmac(){ [ "${SMOKE_NB:-yes}" = yes ]; }; qp(){ case "$*" in *"logread"*) echo "x batman-dv-ud: mark y" ;; *"echo \"META"*) printf "META v=1 state=member gen=4 sha=ab rm=1\nTXN=no\nPS helper member member - radio\n" ;; esac; }
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
		update-status) ph=0; grep -qs '^update-prepare' "$UDT/smoke/calls" && ph=${SMOKE_PHASE:-0}; echo "RESULT update.status code=0 phase=$ph percent=0" ;;
		bulk-open) echo "RESULT bulk.open code=0 ssid=\"s\" ip=\"10.41.0.1\" port=8095 expires=900" ;;
		bulk-close) echo "RESULT bulk.close code=0" ;;
		update-prepare|update-apply) echo "${op}" >> "$UDT/smoke/calls"; echo "RESULT update.${op#update-} code=24 reason=15" ;;
		claim) echo claim >> "$UDT/smoke/calls"; echo "${SMOKE_CLAIM:-claimed}" > "$UDT/smoke/state"; echo "RESULT claim.verify code=0 tag=x adv=y pw=z" ;;
		update-check) echo update-check >> "$UDT/smoke/calls"; if [ $pb = old ]; then echo "RESULT update.check code=20"; else echo "RESULT update.check code=0 ok=true ram=1"; fi ;;
		net-apply) echo net-apply >> "$UDT/smoke/calls"; case " $* " in *" PROVCLIENT_NET_QUIET=1 "*) ;; esac
			if [ "${SMOKE_JOIN:-ok}" = ok ]; then echo member > "$UDT/smoke/state"; echo "RESULT net.apply code=0 version=1 net_id=ab mesh_id=withheld"; else echo "RESULT net.apply code=24"; fi ;;
	esac; }
q(){ case "$*" in *"joinwatch stop"*) rm -f "$UDT/smoke/jw" ;; *"joinwatch start"*) touch "$UDT/smoke/jw" ;; esac; return 0; }
qr(){ case "$*" in
	*"prov.cbor"*hexdump*|*hexdump*"prov.cbor"*) printf "META v=1 state=%s gen=2 sha=ab rm=1\nSHA ab\nKEYS f1,\nH0IN=yes\n" "$(cat "$UDT/smoke/state")" ;;
	*"grep -cFf"*) printf "KEY=0 rc=1\nMESH=0 rc=1\nMESHSYS=0 rc=1\n" ;;
	*".txn"*) [ "${SMOKE_TXN:-no}" = yes ] && echo TXN || echo NOTXN ;;
	*"batman-config-save --check >/dev/null"*) n=$(cat "$UDT/smoke/csn" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$UDT/smoke/csn"; echo "${SMOKE_CS:-0}" | cut -d" " -f$n | grep . || echo "${SMOKE_CS##* }" ;;
	*"prov-state"*) echo "${SMOKE_F6:-radio}" ;;
	*"echo \"mac="*) echo "mac=88:a2:9e:b5:6c:89 slot=A ver=1.5.14-wsl.36 trial_rc=1 dt_try=00000000 hold=[] held=0 badslot=[] up=100 boot=abcd1234" ;;
	*BATMAN_BOARD*) echo ekh-bcm2711 ;;
	*"halow-setkey --status"*) echo "ap default_radio0 ssid=x key=set disabled=0" ;;
	*"/etc/config/wireless"*) echo "-rw------- 1 0 0 1100 Aug 17 04:40 /etc/config/wireless" ;;
	*logread*) printf "%s\n" "x batman-provhelper[1]: verb update.check refused: code 20 (arg 1: want 0 bytes)" "x batman-provhelper[1]: p5 stale only in keys P3 added: --save rc 0" ;;
	*"pidof joinwatch"*) [ -e "$UDT/smoke/jw" ] && echo 4730 ;;
	*"--check 2>&1"*) printf "p5 stale: wireless.default_radio0.ssid\nrc=5\n" ;;
	*"--check >/dev/null"*) echo 0 ;;
	*"bootinfo B"*) echo "bad=0 verified=x y"; echo rc=0 ;;
	*"cat /opt/batdata/state/autocommit-hold-commit"*) echo 1.5.14-wsl.36 ;;
	*"ls -ln "*"provd-bulk/payload"*) [ "${SMOKE_UPLOAD:-present}" = present ] && echo "-rw------- 1 471 471 4096 Nov 23 12:00 payload" ;;
	esac; return 0; }
pl(){ case "$1" in undo-add) echo "UNDO-ADDED 1 p6 - $2" ;; ssid-hex) echo "HEX=6162 RT=ok" ;; ssid-set) echo "SSID-SET ok" ;; undo-done) echo "UNDO-DONE $2" ;; esac; }
:'
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
c=""; while [ $# -gt 0 ]; do case "$1" in -o|-p|-i) shift 2 ;; root@*) shift; c="$*"; break ;; *) shift ;; esac; done
case "$c" in
	*"cat > "*"provd-bulk/payload"*) cat >/dev/null; echo 471; case "$c" in *cat-rc*) echo cat-rc=0 ;; esac ;;
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
	&& [ "$(grep -c '^INVALID prov-update-254: upload: [^ ]*provd-bulk/payload is absent right after a 471 write' <<< "$o")" -ge 4 ]; then
	ok "arm_write with the upload absent after the write: INVALID per upload (with ls / status evidence), the arm goes on to pr_end"
else bad "arm_write smoke (upload absent): rc=$rc $(grep -E 'unbound|absent|STUB pr_end' <<< "$o" | tail -4 | tr '\n' '|')"; fi
o=$(bash -c "$src; $smoke_stubs; pr_pc(){ while [ \"\$1\" != -- ]; do shift; done; echo \"RESULT \$2 code=0\"; }; ud_status >/dev/null; ud_sync; echo \"INV=\$invalid\"" 2>&1)
grep -q '^INVALID prov-update-254: provclient printed no caps line' <<< "$o" && grep -q '^INV=1$' <<< "$o" && ok "a verdict made inside \$(…) (no caps line in ud_status) is printed and counted" || bad "subshell verdict: $(tr '\n' '|' <<< "$o" | cut -c1-200)"
# ---- design v11 (254-v16-ud §4.4): temporary ownership by H0, the member join, pre-row checks, leak greps, 02's record.
# Each block drives the real functions against a stubbed node; on 5bce2c9 (before v8-v11) these functions do not exist
# and every case below fails (negative control, PR body).
H0HEX=$(printf "%0128d" 0); ENCHEX=$(printf "%0128d" 1)
smoke_run(){ rm -f "$T/smoke/calls" "$T/smoke/csn" "$T/smoke/state"; rm -rf "$T/smoke/s0"; bash -c "$src; $smoke_stubs; $1" 2>&1; }
# (1) the v11 start and end on arm_refuse: S0 scan saved, H0 claim, guard, the record at the end = S0, the unit log grepped
o=$(smoke_run 'RUN=pupdate2540000000001; arm_refuse'); s0f=$T/smoke/s0/pupdate2540000000001.txt
grep -q '^PASS prov-update-254: 04 claimed by H0 for this arm' <<< "$o" && grep -q '^claim$' "$T/smoke/calls" && grep -q '^UDSCAN v=1 state=member gen=2 rm=1 sha=ab keys=f1 H0-IN-RECORD=yes$' "$s0f" \
	&& grep -q "^PASS prov-update-254: 04's record at the end = S0" <<< "$o" && grep -q '^PASS prov-update-254: leak check (the unit log incl. pr_end / pr_abort)' <<< "$o" \
	&& ok "v11 start/end: S0 owner scan written, H0 claim, the end record compared with S0, the unit log leak-grepped" || bad "v11 start/end: $(grep -E 'claim|S0|leak|INVALID' <<< "$o" | head -6 | tr '\n' '|')"
grep -qE "$H0HEX|$ENCHEX" <<< "$o" && bad "the arm's output carries a full public point" || ok "the arm's output carries no full key point (fingerprints only)"
# (2) an unclaimed start: INVALID, nothing claimed, no snapshot
o=$(bash -c "$src; $smoke_stubs; echo unclaimed > \"\$UDT/smoke/state\"; rm -f \"\$UDT/smoke/calls\"; pr_begin(){ echo PR_BEGIN; }; arm_refuse" 2>&1); rc=$?
grep -q '^INVALID prov-update-254: start state \[unclaimed\]' <<< "$o" && [ $rc = 2 ] && ! grep -q '^PR_BEGIN' <<< "$o" && ! grep -qs '^claim$' "$T/smoke/calls" \
	&& ok "an unclaimed 04 at the start: INVALID rc 2, no pr_begin, no claim" || bad "unclaimed start: rc=$rc $(grep -E 'start state|PR_BEGIN|claim' <<< "$o" | head -3 | tr '\n' '|')"
# (3) the guard: a claim that does not leave H0 the owner ends the arm INVALID (never FAIL), restore still runs, no owner-op sent
o=$(SMOKE_CLAIM=legacy smoke_run 'arm_refuse'); rc=$?
grep -q '^INVALID prov-update-254: H0 not an owner' <<< "$o" && ! grep -q '^FAIL' <<< "$o" && grep -q '^STUB pr_end' <<< "$o" && ! grep -qs '^update-' "$T/smoke/calls" \
	&& ok "guard: H0 not an owner after the claim -> INVALID, the restore runs, no owner-op sent" || bad "guard: $(grep -E 'H0 not|FAIL|STUB' <<< "$o" | head -3 | tr '\n' '|') calls=[$(tr '\n' ' ' < "$T/smoke/calls" 2>/dev/null)]"
o=$(bash -c "$src
	for c in 'state=claimed H0-IN-RECORD=yes|state=claimed owners=1|claimed|ok' 'state=claimed H0-IN-RECORD=no|state=claimed owners=1|claimed|inv' \
		'state=claimed H0-IN-RECORD=yes|state=claimed owners=2|claimed|inv' 'state=member H0-IN-RECORD=yes|state=member owners=1|claimed|inv' \
		'state=member H0-IN-RECORD=yes|state=claimed owners=1|member|inv' 'UDSCAN v=1 state=member gen=3 rm=1 sha=ab keys=f1 H0-IN-RECORD=yes|state=member gen=3 owners=1 rm=1|member|ok'; do
		IFS='|' read -r a b w e <<< \"\$c\"; v=\$(ud_guard_judge \"\$a\" \"\$b\" \"\$w\"); [ \"\${v%% *}\" = \"\$e\" ] || echo \"BAD [\$c] -> [\$v]\"; done" 2>&1)
[ -z "$o" ] && ok "ud_guard_judge: 6 cases (H0 in record, owners=1, state = the arm's want)" || bad "ud_guard_judge: $o"
o=$(bash -c "$src; fails=0; ud_c3 'RESULT update.prepare code=3' prep; ud_c3 'RESULT update.prepare code=3 signed-for=x' p2; ud_c3 'RESULT update.apply code=24' p3" 2>&1)
[ "$(grep -c '^FAIL' <<< "$o")" = 1 ] && grep -q '^FAIL prov-update-254: prep: code 3' <<< "$o" && ok "ud_c3: a code 3 under the guard is a FAIL; other codes are not" || bad "ud_c3: $o"
# (4) the member join: PROVCLIENT_NET_QUIET passed, a NETCFG line is a FAIL, a failed join keeps its reason
o=$(bash -c "$src; $smoke_stubs; ud_mark(){ UDM=m; }; pr_pc(){ echo \"ARGS \$*\" >> \"\$UDT/smoke/pcargs\"; echo 'RESULT net.apply code=0 version=1 net_id=ab mesh_id=withheld'; }; ud_join && echo JOINED" 2>&1)
grep -q '^JOINED' <<< "$o" && grep -q 'PROVCLIENT_NET_QUIET=1 -- net-apply --first' "$T/smoke/pcargs" && ok "ud_join: net-apply with PROVCLIENT_NET_QUIET=1, code 0 + mesh_id=withheld -> joined" || bad "ud_join: $o"
o=$(bash -c "$src; $smoke_stubs; ud_mark(){ UDM=m; }; pr_pc(){ echo 'NETCFG mesh_id=x'; echo 'RESULT net.apply code=0 version=1 net_id=ab mesh_id_sha=12'; }; ud_join || echo \"NOTJOINED \$UDJOINWHY\"" 2>&1)
grep -q '^FAIL prov-update-254: member join: provclient printed NETCFG' <<< "$o" && grep -q '^NOTJOINED net.apply' <<< "$o" && ok "ud_join: a provclient without the quiet mode (NETCFG, mesh_id_sha) -> FAIL + not joined" || bad "ud_join quiet: $o"
# (5) the pre-row checks on arm_trial: each failure -> item 7 (INVALID member rows, no prepare / apply, 02 judged, the end);
# the good case and an rc 8 that clears on a retry reach the rows
for c in 'ok||||ok' 'cs8|SMOKE_CS="8 8 8 0"|||ok' 'txn|SMOKE_TXN=yes|||inv' 'cs8x4|SMOKE_CS="8 8 8 8"|||inv' 'cs5|SMOKE_CS=5|||inv' \
	'f6|SMOKE_F6=-|||inv' 'nb|SMOKE_NB=no|||person' 'join|SMOKE_JOIN=no|||inv'; do
	IFS='|' read -r n e _ _ want <<< "$c"
	o=$(eval "$e" smoke_run "'mono(){ local x; x=\$(cat \"\$UDT/smoke/mono\" 2>/dev/null || echo 0); echo \$((x + 60)) > \"\$UDT/smoke/mono\"; echo \$x; }; ud_leak_ring(){ case \"\$1\" in \"right after the member join\") echo ROWS-REACHED; exit 0 ;; *) echo \"RING \$1\" ;; esac; }; arm_trial'"); rm -f "$T/smoke/mono"
	case $want in
		ok) grep -q '^ROWS-REACHED' <<< "$o" && grep -q '^PASS prov-update-254: 04 is a member of the bench mesh' <<< "$o" && ! grep -q '^INVALID' <<< "$o" \
			&& ok "pre-row $n: the rows run" || bad "pre-row $n: $(grep -E 'INVALID|pre-row|member' <<< "$o" | head -3 | tr '\n' '|')" ;;
		*) grep -q '^INVALID prov-update-254: member rows (UD1, UD2, UD4, UD5, UD10)' <<< "$o" && ! grep -q '^ROWS-REACHED' <<< "$o" && ! grep -qsE '^update-(prepare|apply)' "$T/smoke/calls" \
			&& grep -q "^PASS prov-update-254: 02's record unchanged over the arm" <<< "$o" && grep -q '^STUB pr_end wrote-b' <<< "$o" \
			&& { [ $want != person ] || grep -q '^NEEDS-PERSON member join: 02' <<< "$o"; } \
			&& ok "pre-row $n: item 7 (INVALID member rows, no prepare / apply, 02 judged, pr_end)" || bad "pre-row $n: $(grep -E 'INVALID|NEEDS|member join|ROWS' <<< "$o" | head -4 | tr '\n' '|')" ;;
	esac
done
# (6) the leak greps: the node-side command run here (uci / logread stubbed), patterns from a pipe, never empty
mkdir -p "$T/lk/bin" "$T/lk/d"; BID=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
printf '#!/bin/sh\ncase "$3" in *.key) printf "%%s" "$FX_KEY" ;; *.mesh_id) printf "%%s" "$FX_MESH" ;; esac\n' > "$T/lk/bin/uci"
printf '#!/bin/sh\ncat "$FX_RING"\n' > "$T/lk/bin/logread"; chmod 755 "$T/lk/bin/uci" "$T/lk/bin/logread"
lk_stubs='UDLS=$UDT/lk/d; qr(){ PATH="$UDT/lk/bin:$PATH" sh -c "$1"; }; boot8(){ cut -c1-8 /proc/sys/kernel/random/boot_id; }'
export FX_KEY=fixture-key-0001 FX_MESH=fixture-mesh-0001 FX_RING=$T/lk/ring
lk(){ bash -c "$src; $lk_stubs; fails=0; invalid=0; $1" 2>&1; }
ring0(){ printf '%s\n' "Nov 23 10:00:00 kernel: [    0.000000] Booting" "Nov 23 10:00:01 batman-dv-ud: mark M1" "Nov 23 10:00:02 batman-provhelper[9]: verb update.check" "$@" > "$FX_RING"; }
lkcase(){ local name=$1 want=$2 mode=$3 arg=$4 o; shift 4; ring0 "$@"; o=$(lk "ud_leak_ring '$name' $mode '$arg'")
	if grep -qE "$want( prov-update-254:)? leak check \($name\)" <<< "$o" && ! grep -qF -e "$FX_KEY" -e "$FX_MESH" <<< "$o" && ! ls "$T/lk/d" | grep -q leak; then ok "leak $name -> $want"; else bad "leak $name want $want: $o"; fi; }
lkcase clean PASS boot "$BID"
lkcase key-in-ring FAIL boot "$BID" "Nov 23 10:00:03 batman-provhelper[9]: k=$FX_KEY"
lkcase key-in-system-line FAIL boot "$BID" "Nov 23 10:00:03 hostapd: $FX_KEY"
lkcase id-in-our-line FAIL mark M1 "Nov 23 10:00:03 batman-config-save: $FX_MESH"
lkcase id-in-system-line INFO boot "$BID" "Nov 23 10:00:03 wpa_supplicant[3]: mesh $FX_MESH joined"
lkcase mark-lost INVALID mark M9
lkcase boot-changed INVALID boot 00000000
printf '%s\n' "Nov 23 10:00:05 batman-dv: x" > "$FX_RING"; o=$(lk "ud_leak_ring 'ring-start' boot '$BID'")
grep -q '^INVALID prov-update-254: leak check (ring-start): logread window lost (LEAK-NOWINDOW ring start)' <<< "$o" && ok "leak ring-start: a ring not starting at the boot -> INVALID window lost" || bad "leak ring-start: $o"
ring0 "x"; o=$(FX_KEY= lk "ud_leak_ring 'empty-key' boot '$BID'")
grep -q '^INVALID prov-update-254: leak check (empty-key): pattern unreadable (empty mesh key)' <<< "$o" && ! grep -q '^PASS' <<< "$o" && ok "leak empty key: INVALID pattern unreadable, no grep run" || bad "leak empty key: $o"
o=$(FX_MESH= lk "ud_leak_ring 'empty-id' boot '$BID'")
grep -q '^INVALID prov-update-254: leak check (empty-id): pattern unreadable (empty mesh id)' <<< "$o" && ok "leak empty id: INVALID pattern unreadable" || bad "leak empty id: $o"
o=$(bash -c "$src; for c in 'KEY=x rc=1|MESH=0 rc=1' 'KEY=0 rc=2|MESH=0 rc=1' 'KEY=0 rc=1|MESH=0 rc=2' 'KEY=0 rc=1|MESH=0 rc=1|MESHSYS=0 rc=2' 'KEY=0 rc=1' ''; do ud_leak_judge j \"\$(tr '|' '\n' <<< \"\$c\")\" | head -1; done" 2>&1)
[ "$(grep -c '^INVALID leak check (j): did not run' <<< "$o")" = 6 ] && ok "leak judge: a non-integer count, grep rc 2 or a missing count -> INVALID did not run (6 cases)" || bad "leak judge did-not-run: $o"
printf 'x %s\n' "$FX_KEY" > "$T/lk/unitlog"; o=$(lk "q(){ :; }; scp(){ while [ \$# -gt 2 ]; do shift; done; cp \"\$1\" \"\${2#*:}\"; }; ud_leak_file 'unit log' \"\$UDT/lk/unitlog\"")
grep -q '^FAIL prov-update-254: leak check (unit log): the mesh key appears 1 time' <<< "$o" && ! ls "$T/lk/d" | grep -q . && ok "leak file: the unit log copied to the scratch, grepped there, removed" || bad "leak file: $o [$(ls "$T/lk/d")]"
# (7) review v11 A m2 / B m2: the trial boot's ring again at its last controllable point; a key line written after the
# landing grep is caught; a boot that already changed is INVALID window lost
ring0; o=$(lk "PR_LAND_BOOT=$BID; ud_leak_ring landing boot $BID; printf '%s\n' 'Nov 23 10:30:00 batman-provhelper[9]: k=$FX_KEY' >> \"\$FX_RING\"; ud_late_ring 'UD1: before the release' $BID")
grep -q '^PASS prov-update-254: leak check (landing)' <<< "$o" && grep -q '^FAIL prov-update-254: leak check (UD1: before the release): the mesh key' <<< "$o" && ok "late ring (UD1): a key line written after the landing grep -> FAIL" || bad "late ring UD1: $o"
ring0; o=$(lk "PR_LAND_BOOT=$BID; ud_leak_ring landing boot $BID; printf '%s\n' 'Nov 23 10:30:00 batman-provhelper[9]: k=$FX_KEY' >> \"\$FX_RING\"; qr(){ case \"\$1\" in *autocommit.deadline*) echo 1000 ;; *uptime*) u=\$(cat \"\$UDT/lk/up\" 2>/dev/null || echo 800); echo \$((u + 50)) > \"\$UDT/lk/up\"; echo \$u ;; *) PATH=\"\$UDT/lk/bin:\$PATH\" sh -c \"\$1\" ;; esac; }; sleep(){ :; }; ud2_late; echo UP=\$(cat \"\$UDT/lk/up\")"); rm -f "$T/lk/up"
grep -q '^FAIL prov-update-254: leak check (UD2: the B trial boot, last HELD sample before the deadline): the mesh key' <<< "$o" && grep -q '^UP=1000$' <<< "$o" && ok "late ring (UD2): waits to deadline - 60 s, a key line written after landing -> FAIL" || bad "late ring UD2: $o"
o=$(lk "PR_LAND_BOOT=$BID; boot8(){ echo 0000beef; }; qr(){ case \"\$1\" in *autocommit.deadline*) echo 1000 ;; *uptime*) echo 10 ;; esac; }; ud2_late")
grep -q '^INVALID prov-update-254: leak check (UD2: the B trial boot before its revert): logread window lost (boot 0000beef)' <<< "$o" && ok "late ring (UD2): the boot changed before the grep -> INVALID window lost" || bad "late ring UD2 lost: $o"
o=$(lk "qr(){ echo; }; ud2_late"); grep -q '^INVALID prov-update-254: UD2: no autocommit deadline' <<< "$o" && ok "late ring (UD2): no deadline -> INVALID window lost" || bad "late ring UD2 no deadline: $o"
ring0; o=$(lk "ud_late_ring 'UD1: before back_to_a' 00000000"); grep -q '^INVALID prov-update-254: leak check (UD1: before back_to_a): logread window lost' <<< "$o" && ok "late ring (UD1): the B boot already gone -> INVALID window lost" || bad "late ring UD1 lost: $o"
# (8) 02 (review v11 A m1): each listed format matches once, benign lines do not; the record equal at start and end
o=$(bash -c "$src"'; IFS="|" read -ra a <<< "$UD_02FMT"; n=0; for x in "${a[@]}"; do l=$(sed "s/\\\\//g" <<< "$x"); c=$(ud_02_match "Nov 23 batman-provhelper[7]: ${l}tail" | grep -c .); [ "$c" = 1 ] || echo "BAD [$l] $c"; n=$((n + 1)); done; echo "N=$n"
	for b in "verb update.check refused: code 20 (arg 1: want 0 bytes)" "p5 stale only in keys P3 added: --save rc 0" "bulk.open: window 900 s" "net.apply ok"; do [ -z "$(ud_02_match "x batman-provhelper[7]: $b")" ] || echo "BENIGN-MATCH [$b]"; done
	[ -z "$(ud_02_match "x other[1]: commit: x")" ] || echo "OTHER-TAG-MATCH"' 2>&1)
[ "$o" = "N=20" ] && ok "02 log formats: 20 formats match once each, benign helper lines and other tags do not (secondary signal)" || bad "02 formats: $o"
S='META v=1 state=member gen=4 sha=ab rm=1
TXN=no
PS helper member member - radio'
o=$(bash -c "$src; ud_02_judge \"\$1\" \"\$1\" ''; ud_02_judge \"\$1\" \"\${1/gen=4/gen=5}\" ''; ud_02_judge \"\$1\" \"\${1/- radio/- off}\" ''; ud_02_judge \"\${1/TXN=no/TXN=yes}\" \"\${1/TXN=no/TXN=yes}\" ''; ud_02_judge '' '' ''; ud_02_judge \"\$1\" \"\$1\" LOST; ud_02_judge \"\$1\" \"\$1\" 'x batman-provhelper[3]: commit: gen 5'" _ "$S" 2>&1)
[ "$(sed -n 1p <<< "$o" | cut -c1-4)$(sed -n 3p <<< "$o" | cut -c1-4)$(sed -n 5p <<< "$o" | cut -c1-4)$(sed -n 7p <<< "$o" | cut -c1-4)$(sed -n 9p <<< "$o" | cut -c1-4)$(sed -n 12p <<< "$o" | cut -c1-7)$(sed -n 14p <<< "$o" | cut -c1-4)" = PASSFAILFAILFAILFAILINVALIDFAIL ] \
	&& ok "02 judge: equal -> PASS; gen / prov-state field / .txn / empty -> FAIL; lost log -> INVALID; a state-changing line -> FAIL" || bad "02 judge: $(tr '\n' '|' <<< "$o")"
# host dirs on //wsl.localhost: Git Bash `mkdir -p` there fails even for an existing dir (device run 2026-11-23: every
# arm INVALID at the S0 save). hostdir makes one level; no `mkdir -p` may target a //wsl.localhost-default variable.
v=$(grep -oE '^[A-Z0-9_]+=\$\{[A-Z0-9_]+:-//wsl\.localhost' "$U" | cut -d= -f1 | paste -sd'|')
[ -n "$v" ] && ! grep -nE "mkdir -p \"?\\\$\\{?($v)\\b" "$U" >/dev/null && grep -q '^hostdir(){ \[ -d "\$1" \] || mkdir "\$1"; }' "$U" \
	&& ok "host dirs: no mkdir -p on a //wsl.localhost path ($v); hostdir is one level" || bad "host dirs: mkdir -p on a //wsl.localhost path, or hostdir missing [$v]"
# ---- device run 2026-11-23 (ud36c): pr_slot_ticks / pr_slot_free sent the 12 KB slot-lock lib in ssh's argv; the
# nodes' dropbear resets a command over ~8 KB, so every lock check was INVALID "no start time []". Stub ssh with that limit.
mkdir -p "$T/db" "$T/dbrun"; : > "$T/dbrun/batman-slot.flock"
printf '%s\n' '#!/bin/bash' 'c=""; while [ $# -gt 0 ]; do case "$1" in -o|-p|-i) shift 2 ;; root@*) shift; c="$*"; break ;; *) shift ;; esac; done' \
	'[ "${#c}" -gt 8000 ] && { echo "client_loop: send disconnect: Connection reset by peer" >&2; exit 255; }' 'RUNDIR=$UDT/dbrun exec sh -c "$c"' > "$T/db/ssh"; chmod 755 "$T/db/ssh"
o=$(PATH="$T/db:$PATH" bash -c "$src; sleep(){ :; }; fails=0; invalid=0; t=\$(pr_slot_ticks); echo \"TICKS=[\$t]\"; pr_slot_free 'the step' \"\$t\"" 2>&1)
grep -qE '^TICKS=\[[0-9]+\]$' <<< "$o" && grep -q '^PASS prov-update-254: the slot flock is free <= 1 s after the step' <<< "$o" \
	&& ok "pr_slot_ticks / pr_slot_free work through an ssh that resets commands over 8000 B (the lib goes on stdin)" || bad "slot lock over a limited ssh: $(tr '\n' '|' <<< "$o" | cut -c1-300)"
# ---- device run 2026-11-23 (ud36c) trial arm: the re-acquire after UD2's apply counted this run's own rm-hold line as
# "left by an earlier run" (the node's undo-replay skips RUN_ID, prov-lease-254.sh:107) -> NEEDS-PERSON on a node that
# was back; then UD4 / UD5 (ii) / UD1 ran with no provclient on the node ("no caps line … stale tool" for empty output)
pa_stub='pr_stage(){ :; }; pl(){ case "$1" in acquire) echo "LEASE $RUN until uptime 9" ;; undo-pending) cat "$UDT/pa/pending" ;; undo-replay) echo "REPLAY other"; [ -f "$UDT/pa/after" ] && cp "$UDT/pa/after" "$UDT/pa/pending" ;; esac; }'
mkdir -p "$T/pa"
printf '%s\n' "UNDO-PENDING prun1 1 todo - rm-hold" > "$T/pa/pending"; rm -f "$T/pa/after"
o=$(bash -c "$src; RUN=prun1; $pa_stub; pr_acquire 600; echo rc=\$?" 2>&1)
grep -q '^rc=0$' <<< "$o" && ! grep -q 'undo still left\|left by an earlier run' <<< "$o" && grep -q "this run's own undo lines" <<< "$o" \
	&& ok "pr_acquire after this run's own reboot: its own pending rm-hold is not an earlier run's (no replay FAIL)" || bad "pr_acquire own line: $(tr '\n' '|' <<< "$o")"
printf '%s\n' "UNDO-PENDING prun1 1 todo - rm-hold" "UNDO-PENDING pold9 3 todo slot:A ssid-restore 6162" > "$T/pa/pending"; printf '%s\n' "UNDO-PENDING prun1 1 todo - rm-hold" > "$T/pa/after"
o=$(bash -c "$src; RUN=prun1; $pa_stub; pr_acquire 600; echo rc=\$?" 2>&1)
grep -q '^rc=0$' <<< "$o" && grep -q 'undo left by an earlier run: UNDO-PENDING pold9' <<< "$o" && ok "pr_acquire: an earlier run's line is still replayed (and cleared)" || bad "pr_acquire other cleared: $(tr '\n' '|' <<< "$o")"
printf '%s\n' "UNDO-PENDING prun1 1 todo - rm-hold" "UNDO-PENDING pold9 3 todo slot:A ssid-restore 6162" > "$T/pa/pending"; printf '%s\n' "UNDO-PENDING pold9 3 todo slot:A ssid-restore 6162" > "$T/pa/after"
o=$(bash -c "$src; RUN=prun1; $pa_stub; pr_acquire 600; echo rc=\$?" 2>&1)
grep -q '^rc=1$' <<< "$o" && grep -q '^FAIL undo still left after the replay: UNDO-PENDING pold9' <<< "$o" && ok "pr_acquire: an earlier run's line left after the replay is still a FAIL (fail-closed)" || bad "pr_acquire other left: $(tr '\n' '|' <<< "$o")"
o=$(bash -c "$src; pr_pc(){ :; }; ud_pc h0.pem -- update-status x; echo rc=\$?" 2>&1)
grep -q '^INVALID prov-update-254: provclient printed no output at all' <<< "$o" && ! grep -q 'stale tool' <<< "$o" && ok "ud_pc: empty provclient output is 'no output', not a stale tool" || bad "ud_pc empty: $o"
o=$(bash -c "$src; pr_needs_person 'x' >/dev/null; ok y >/dev/null; ud_sync; echo fails=\$fails" 2>&1)
grep -q '^fails=1$' <<< "$o" && ok "a NEEDS-PERSON is counted as a FAIL in the tally (not lost to ud_sync)" || bad "needs-person tally: $o"
cp "$T/smoke/gen.tgz" "$T/smoke/out/1.5.14-wsl.36/ekh-bcm2711/batman-1.5.14-wsl.36-ekh-bcm2711-ab-payload.tar.gz"   # the upload stub answers with gen.tgz
o=$(SMOKE_PHASE=3 smoke_run 'pr_find(){ return 1; }; ud_leak_ring(){ :; }; arm_trial')
n1=$(grep -n '^NEEDS-PERSON .*UD2: no node after the apply' <<< "$o" | head -1 | cut -d: -f1)
if [ -n "$n1" ] && grep -q '^NOT-JUDGED prov-update-254: UD4 / UD5 (i), UD5 (ii), UD1, UD10: NOT-RUN' <<< "$o" && ! tail -n +"$n1" <<< "$o" | grep -v '^NOT-JUDGED' | grep -qE 'UD4|UD1|UD5 \(ii\)|provclient printed' \
	&& grep -q '^STUB pr_end wrote-b' <<< "$o" && [ "$(grep -c '^update-apply' "$T/smoke/calls")" = 1 ]; then
	ok "after UD2's NEEDS-PERSON the trial arm sends no further row: the rest NOT-RUN, straight to the restore"
else bad "trial after NEEDS-PERSON: $(tail -n +"${n1:-1}" <<< "$o" | grep -E 'UD|NOT-|STUB|INVALID' | head -6 | tr '\n' '|') applies=$(grep -c '^update-apply' "$T/smoke/calls")"; fi
o=$(bash -c "$src; $smoke_stubs; ud_end(){ echo \"UD_END \$*\"; }; PR_PERSON=1; PR_WROTE_B=1; ud_g; echo NOT-REACHED" 2>&1); rc=$?
[ $rc = 2 ] && grep -q "^NOT-JUDGED prov-update-254: the arm's remaining rows: NOT-RUN" <<< "$o" && grep -q '^UD_END wrote-b' <<< "$o" && ! grep -q NOT-REACHED <<< "$o" \
	&& ok "ud_g after a NEEDS-PERSON: no owner-op, the arm ends (restore)" || bad "ud_g person: rc=$rc $o"
# ---- device run 2026-11-23 (ud36c) write arm: "UD9 premise (output side) not shown: []" with no reason; the removed log
# hashed as 4096 spaces (no line written). The start is checked (a live group-leading watcher) and an empty result says why
o=$(bash -c "$src; q(){ echo 'WATCH 4242'; echo 'UNDO-ADDED 4 tmp boot:x kill-pg 4242 ud9-watch'; }; qr(){ echo \"\$QRA\"; }; RUN=r1; SQ=1; PRD=x
	QRA='PG 4242 1' ud_watch observe && echo STARTED; QRA='PG 1 1' ud_watch observe || echo REFUSED1; QRA=GONE ud_watch observe || echo REFUSED2" 2>&1)
grep -q '^STARTED' <<< "$o" && grep -q '^REFUSED1' <<< "$o" && grep -q '^REFUSED2' <<< "$o" && grep -q 'pid 4242 is not a live group-leading watcher right after the start \[GONE\]' <<< "$o" \
	&& ok "ud_watch: the started pid must be a live group-leading watcher (dead pid / other group -> INVALID)" || bad "ud_watch start check: $o"
o=$(bash -c "$src; for a in 'gone|LOGSIZE 4096 NONSPACE 0' 'alive|LOGSIZE 4096 NONSPACE 0|SYSLOG x ud9-watch: UD9-MISS stop' 'gone|NOLOG'; do IFS='|' read -r g l1 l2 <<< \"\$a\"; ud9_diag_text \"\$g\" \"\$(printf '%s\n%s' \"\$l1\" \"\$l2\")\"; done" 2>&1)
[ "$(sed -n 1p <<< "$o")" = "the watcher had exited; its log holds no line (pre-sized spaces only); no ud9-watch line in syslog" ] \
	&& grep -q '^the watcher was still running at the read (no stream dd seen within the step); its log holds no line (pre-sized spaces only); syslog: x ud9-watch: UD9-MISS stop|$' <<< "$o" \
	&& grep -q '^the watcher had exited; its log does not exist (it never started); no ud9-watch line in syslog$' <<< "$o" && ok "ud9_diag_text: alive / exited, empty log, no log, syslog lines" || bad "ud9_diag_text: $o"
o=$(bash -c "$src; ud_watch_gone(){ return 0; }; ud_watch_log(){ :; }; ud_watch_done(){ :; }; qr(){ case \"\$1\" in *dv-ud9-*wc*) echo 'LOGSIZE 4096 NONSPACE 0' ;; esac; }; RUN=r1; ud_watch_obs_end" 2>&1)
grep -q '^INVALID prov-update-254: UD9 premise (output side) not shown: \[\] — the watcher had exited; its log holds no line' <<< "$o" && ok "UD9 observe with no result line: INVALID with the diagnosis" || bad "obs_end diag: $o"
# ---- device run 2026-11-23 (ud36c) write arm: UD8 (1)-(4) FAILed on a correct refusal: the judge wanted "update worker:
# prepare refused", the helper logs "update worker: <version> refused, reason 11 (<why>)" (node/updwork.go:291). Real lines:
ud8l='Sun Aug 17 13:18:32 2025 daemon.info batman-provhelper[23990]: update worker: 1.5.14-wsl.36+b885a2c.fw302c80b.bench refused, reason 11 (member boot/overlays/spi5-1cs.dtbo is not a regular file)'
ud8s='RESULT update.status code=0 phase=0 percent=0 fail_reason=11 sha=e03ad2a57f336ece version=1.5.14-wsl.36+b885a2c.fw302c80b.bench'
ud8v=1.5.14-wsl.36+b885a2c.fw302c80b.bench
o=$(bash -c "$src; ud8_ok \"\$1\" \"\$2\" \"\$3\" 'is not a regular file' && echo A; ud8_ok \"\$1\" \"\$2\" 1.5.14-wsl.35 'is not a regular file' || echo B; ud8_ok \"\$1\" \"\$2\" \"\$3\" 'too many members' || echo C; ud8_ok \"\$1\" \"\$2\" '' 'is not a regular file' || echo D; ud8_ok \"\${1/fail_reason=11/fail_reason=12}\" \"\$2\" \"\$3\" 'is not a regular file' || echo E" _ "$ud8s" "$ud8l" "$ud8v" 2>&1)
[ "$(tr -d '\n' <<< "$o")" = ABCDE ] && ok "UD8 judge on the device's real refusal line: PASS; another version / why / no version / reason -> not a PASS" || bad "UD8 judge: $o"
echo "test-prov-update: $P passed, $F failed"; [ $F = 0 ] && [ $P -gt 0 ]
