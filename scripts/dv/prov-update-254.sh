#!/bin/bash
# scripts/dv/prov-update-254.sh [t1|refuse|write|kill|trial] — #254 H4 appendix A.9: the update rows.
#   t1 (default)  UD-T1 / UD-L / (P) on any image (the rows below the line "UD-T1" in this header).
#   refuse / write / kill / trial  the 17 UD rows of #254 v1.6 group 4 PR B on the bench image wsl.36 (RB = the bench
#                 image + provclient as 471 + a root shell), docs/design/254-v16-ud.md §1.2-§1.5. One arm per run.
# ---- t1 -------------------------------------------------------------------------------------------------------------
#   UD-T1  a manifest signed with the TEST keys (T -> K_test, signrel.py) is refused by an image that does not trust T.
#          First the image's root, from status key 15 "trust" (none / bad / the fingerprint's first 8 bytes, 16 hex):
#            = T's fingerprint (tests/keys/T.pub) -> INVALID "bench image: UD-T1 needs an R image" (a bench build
#              trusts T: the check would pass, which says nothing about a release image);
#            none (wsl / ci build, no key file)   -> update.check ok = false, reason 24 (no root key: no app update);
#            any other fingerprint (R)            -> ok = false, reason 11 (the release trusts only R; 254-p3 §3.7.1);
#            bad                                  -> FAIL (the image's key files are malformed);
#            no trust in key 15                   -> INVALID (a pre-S5 node, or a provclient that does not print it).
#          The manifest itself is valid (signrel --verify ok on the host: P) - what is refused is the root, not the object.
#          Then the image's /rom key files against that trust (release-key-254's rk_judge with status key 15).
#   UD-L   after a step whose helper ran a lock-holding batman-slot verb reports done, the slot flock is free within 1 s
#          (pr_slot_free); a check that stopped before precheck-node is a NOT-JUDGED line.
#   (P)    update.status on an idle node: phase 0, no failure reason.
# ---- the UD arms (254-v16-ud.md) --------------------------------------------------------------------------------------
#   refuse  step 0 (provclient flip: the pre-UD binary's update.check is ESchema 20), AP on, UD7 (eight refusals),
#           UD13 (a quote in the AP ssid), UD20c, UD20b, UD8b, UD-L.                   no slot write, one reboot (restore)
#   write   UD8 (four malicious tars), UD8c, UD6 (b), UD20 neg / pos (+ the UD9 observe watcher), UD10b.      writes B
#   kill    UD9: the dd position watcher's kill and cut sub-arms (needs a write-arm observe file).       writes B, a reset
#   trial   UD2, UD4 (= UD5 i), UD1 (with UD10 and UD5 ii).                                         applies: real trials
# Every refusal asserts the helper's own log line (lg-style mark); a step whose premise is missing is INVALID, never a
# PASS. A host death / a node reboot mid-arm is NEEDS-PERSON: P9 prints the recovery (254-v16-ud §7.1).
# W (Q4): the archived wsl.22 `update.status code=20` + the 2ecf1cb source (no update.* verb) — evidence, not re-run.
# Env: OUTS (payload dirs, host), H4_PY_WSL (signrel's python), DV_PROV_TOOLS (provclient-arm64 [+ .pre-ud]),
#      UD9_OBS_DIR (the write arm's observe verdicts, read by the kill arm).
set -u
PR_UNIT=prov-update-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "${BASH_SOURCE[0]}")/prov-254.sh"
# shellcheck source=scripts/dv/s5-254.sh
. "$(dirname "${BASH_SOURCE[0]}")/s5-254.sh"   # rk_judge / RK_Q (release-key-254), for the UD-T1 cross-check
OUTS=${OUTS:-//wsl.localhost/Ubuntu-24.04/home/yello/out}
PYW=${H4_PY_WSL:-/home/yello/.batman-dv/peer-venv/bin/python}
UD9_OBS_DIR=${UD9_OBS_DIR:-//wsl.localhost/Ubuntu-24.04/home/yello/.batman-dv/ud9-observe}
BULK=/tmp/run/batman-provd-bulk/payload
CAPS='PROVCLIENT caps=uc2,bo2,rk1,pg2,nopsk'
LATE8=8388608
UD_LASTCHK=0

# ==== judges: pure functions of what was read (tests: scripts/dv/test-prov-update-254.sh) ============================
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
f(){ sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<< "$1" | head -1; }
# ud_phase <status RESULT line> <phase> [fail_reason|-] [sha16|-]: rc 0 when the line says exactly that (- = absent)
ud_phase(){ local l=$1
	[ "$(code "$l")" = 0 ] && [ "$(f "$l" phase)" = "$2" ] || return 1
	case "${3:-any}" in any) ;; -) [ -z "$(f "$l" fail_reason)" ] || return 1 ;; *) [ "$(f "$l" fail_reason)" = "$3" ] || return 1 ;; esac
	case "${4:-any}" in any) ;; -) [ -z "$(f "$l" sha)" ] || return 1 ;; *) [ "$(f "$l" sha)" = "$4" ] || return 1 ;; esac
	return 0; }
# ud_why <helper log> <fixed text>: the helper logged it (batman-provhelper[pid] lines only)
ud_why(){ grep 'batman-provhelper\[' <<< "$1" | grep -qF -- "$2"; }
# ud_caps <provclient output> <PCBIN>: the new binary's capability line is there (the old one is exempt)
ud_caps(){ [ "${2:-new}" = old ] && return 0; grep -qxF "$CAPS" <<< "$1"; }
# ud_bi <bootinfo text> <key>: a `key=value` field of `batman-slot bootinfo` (value up to the line end for verified=)
ud_bi(){ sed -n "s/^.*\b$2=\(.*\)$/\1/p" <<< "$1" | head -1 | sed 's/ [a-z_]*=.*//'; }
# ud_s0_status <status line>: the pr_begin precondition (254-v16-ud §4.1) -> "ok" | "inv <why>"
ud_s0_status(){
	[ "$(code "$1")" = 0 ] || { echo "inv update.status unreadable [$1]"; return; }
	if [ "$(f "$1" phase)" = 0 ] && [ -z "$(f "$1" fail_reason)" ] && [ -z "$(f "$1" sha)" ]; then echo ok
	else echo "inv not S0: an update-last that is live for this version ($1)"; fi; }
# ud_mode <S0 mode> <now mode>: the wireless file's mode after a harness `uci commit` is the S0 one
ud_mode(){ [ -n "$1" ] && [ "$1" = "$2" ]; }
# ud_y_differs <sums Y> <sums X>: UD20c's Y must have another SHA256SUMS (254-v16-ud §1.2, B v2 M1)
ud_y_differs(){ [[ $1 =~ ^[0-9a-f]{64}$ ]] && [[ $2 =~ ^[0-9a-f]{64}$ ]] && [ "$1" != "$2" ]; }
# ud_check_text <--check output> <rc>: UD13's P: rc 5, the ssid named stale, never "(unpersistable"
ud_check_text(){ [ "$2" = 5 ] && grep -q 'p5 stale: wireless.default_radio0.ssid' <<< "$1" && ! grep -q '(unpersistable' <<< "$1"; }
# ud_obs_gate <observe file text> <BATMAN_VERSION> <eth MAC> -> "ok" | "inv premise not shown: <why>"
ud_obs_gate(){
	[ -n "$1" ] || { echo "inv premise not shown: no observe file (run the write arm's UD20 pos first)"; return; }
	grep -qx "version=$2" <<< "$1" || { echo "inv premise not shown: the observe file is for another version ($(sed -n 's/^version=//p' <<< "$1"))"; return; }
	grep -qx "mac=$3" <<< "$1" || { echo "inv premise not shown: the observe file is for another node ($(sed -n 's/^mac=//p' <<< "$1"))"; return; }
	grep -qE '^UD9-OBS .* result=ok$' <<< "$1" || { echo "inv premise not shown: the observation failed ($(grep '^UD9-' <<< "$1" | head -1))"; return; }
	echo ok; }
# ud_kill_judge <watcher log lines> <SQ> <orphan gone: 1|0> <slot_free: PASS|...> <status line> <bootinfo B> <state line>
#   <ota-trace tail>: the kill sub-arm (254-v16-ud §1.5): PASS / FAIL / INVALID / INFO lines on stdout
ud_kill_judge(){ local log=$1 sq=$2 gone=$3 sf=$4 st=$5 bi=$6 s=$7 tr=$8 fl pf
	grep -q '^UD9-MISS' <<< "$log" && { echo "INVALID UD9 kill: $(grep '^UD9-MISS' <<< "$log" | head -1)"; return; }
	fl=$(grep '^UD9-FIRE mode=kill ' <<< "$log" | head -1); pf=$(sed -n 's/.* pos_final=\([0-9]*\).*/\1/p' <<< "$fl")
	[ -n "$fl" ] && [ -n "$pf" ] || { echo "INVALID UD9 kill: no UD9-FIRE line ($(head -2 <<< "$log" | tr '\n' '|'))"; return; }
	[ "$pf" -lt $((sq - LATE8)) ] || { echo "INVALID UD9 kill: too late (pos_final $pf >= SQ - 8 MiB): the orphan may have had the whole rootfs"; return; }
	local r=0
	[ "$gone" = 1 ] || { echo "FAIL UD9 kill: the orphan batman-slot write did not exit within 300 s"; r=1; }
	[ "$sf" = PASS ] || { echo "FAIL UD9 kill: the slot flock after the orphan: $sf"; r=1; }
	ud_phase "$st" 0 22 || { echo "FAIL UD9 kill: status [$st], want phase=0 fail_reason=22"; r=1; }
	[ "$(ud_bi "$bi" bad)" = 1 ] || { echo "FAIL UD9 kill: bootinfo B bad=[$(ud_bi "$bi" bad)], want 1"; r=1; }
	[ "$(field "$s" slot)" = A ] && [ "$(field "$s" trial_rc)" = 1 ] || { echo "FAIL UD9 kill: not A committed ($s)"; r=1; }
	grep -qE 'SLOT VERIFY slot=B result=' <<< "$tr" && ! grep -q 'SLOT VERIFY slot=B result=ok' <<< "$tr" && echo "INFO UD9 kill: supporting: $(grep 'SLOT VERIFY slot=B' <<< "$tr" | tail -1)"
	grep -q 'SLOT DIE cmd=write' <<< "$tr" && echo "INFO UD9 kill: SLOT DIE present" || echo "INFO UD9 kill: no SLOT DIE (the orphan died of SIGPIPE before it; not judged)"
	[ $r = 0 ] && echo "PASS UD9 kill: pos_final $pf < SQ - 8 MiB, orphan gone, flock free, phase 0 + 22, B bad=1, A committed"; }
# ud_cut_judge <watcher log lines> <SQ> <status line> <bootinfo B> <state line> <boot-reasons line>
ud_cut_judge(){ local log=$1 sq=$2 st=$3 bi=$4 s=$5 br=$6 last p2
	grep -q '^UD9-MISS' <<< "$log" && { echo "INVALID UD9 cut: $(grep '^UD9-MISS' <<< "$log" | head -1) (no cut was made)"; return; }
	last=$(grep '^UD9-' <<< "$log" | tail -1)
	case "$last" in "UD9-PRE-B pos="*) ;; *) echo "INVALID UD9 cut: no UD9-PRE-B line (last [$last])"; return ;; esac
	p2=$(sed -n 's/^UD9-PRE-B pos=\([0-9]*\) .*/\1/p' <<< "$last")
	[ -n "$p2" ] && [ "$p2" -lt $((sq - LATE8)) ] || { echo "INVALID UD9 cut: too late (p2 [$p2] >= SQ - 8 MiB)"; return; }
	local r=0
	[ "$(ud_bi "$bi" bad)" = 1 ] || { echo "FAIL UD9 cut: bootinfo B bad=[$(ud_bi "$bi" bad)], want 1"; r=1; }
	[ "$(field "$s" slot)" = A ] && [ "$(field "$s" trial_rc)" = 1 ] || { echo "FAIL UD9 cut: not A committed ($s)"; r=1; }
	ud_phase "$st" 0 22 || { echo "FAIL UD9 cut: status [$st], want phase=0 fail_reason=22"; r=1; }
	case "$br" in *"hints:"*sysrq*) ;; *) echo "FAIL UD9 cut: boot-reasons without the sysrq hint [$br]"; r=1 ;; esac
	echo "INFO UD9 cut: $(grep -o 'fsync_s=[0-9.]*' <<< "$last")"
	[ $r = 0 ] && echo "PASS UD9 cut (a hard reset, not a power cut): PRE-B pos $p2 < SQ - 8 MiB, B bad=1, A committed, 0 + 22, sysrq hint"; }
# ud_cut_flow <poll line>: the host's cut-arm poll verdict (254-v16-ud §1.5, B v5 m1): "invalid <why>" (no pr_find: the
#   node was never reset), "cut" (the ssh connection was lost after UD9-PRE-B), "wait" (go on polling)
ud_cut_flow(){
	case "$1" in
		*UD9-MISS*) echo "invalid $(grep -o 'UD9-MISS.*' <<< "$1" | head -1)" ;;
		LOST*) if grep -q 'UD9-PRE-B' <<< "$1"; then echo cut; else echo "invalid the connection was lost before UD9-PRE-B"; fi ;;
		DEADLINE*) echo "invalid UD9-MISS timeout (no line, the watcher's deadline passed)" ;;
		*) echo wait ;;
	esac; }
# ud4_judge <boot-reasons line of the A boot> <new crash record names> <grep result of the decompressed record: 1|0>
ud4_judge(){
	case "$1" in
		*PANIC*)
			local recs plain; recs=$(tr ' ' '\n' <<< "$2" | grep 'dmesg-ramoops'); plain=$(grep -v '\.enc\.z$' <<< "$recs")
			if [ -z "$recs" ]; then echo "INVALID UD4: boot-reasons says PANIC but no new dmesg record [$2]"
			elif [ -z "$plain" ]; then echo "INVALID UD4: record not readable (compressed .enc.z only): $2"
			elif [ "$3" = 1 ]; then echo "PASS UD4: B's boot evidenced — PANIC + a pstore dmesg record with the root-mount failure"
			else echo "FAIL UD4: a PANIC record without 'Unable to mount root' / 'VFS:' ($2)"; fi ;;
		*UNCLEAN*) echo "INVALID UD4: UNCLEAN — A's own update.apply reboot left no shutdown marker: $1" ;;
		*CLEAN*) echo "INVALID UD4: B boot not proven (CLEAN: 6 + 18 would also come back if the firmware ignored the tryboot): $1" ;;
		*) echo "INVALID UD4: boot-reasons line unreadable [$1]" ;;
	esac; }

# ==== node steps ======================================================================================================
TBGET='set -- $(vcmailbox 0x00030064 4 4 0 2>/dev/null); if [ "${2:-}" = 0x80000000 ] && [ "${5:-}" = 0x80000004 ] && [ -n "${6:-}" ]; then echo "tryboot_flag=$(( ${6} ))"; else echo tryboot_flag=unknown; fi'
boot8(){ field "$(qr "$ST")" boot; }
ud_mark(){ UDM="ud-$RUN-$(date +%s%N)"; q "logger -t batman-dv-ud mark $UDM"; }
ud_log(){ qr "logread | sed -n '/batman-dv-ud: mark $UDM\$/,\$p' | grep -E 'batman-provhelper\\[|batman-slot|batman-config-save' | cut -c1-400"; }
ud_bootinfo(){ local o i; for i in 1 2 3; do o=$(qr "batman-slot bootinfo B 2>&1; echo rc=\$?"); case "$o" in *rc=14) sleep 10 ;; *) break ;; esac; done; printf '%s\n' "$o"; }
ud_pc(){	# pr_pc + the caps rule; PCBIN=old exempt. INVALID (rc 2) on a missing caps line, with the tool's sha
	local o pb=new a; for a in "$@"; do [ "$a" = PCBIN=old ] && pb=old; [ "$a" = -- ] && break; done
	o=$(pr_pc "$@"); printf '%s\n' "$o"
	ud_caps "$o" "$pb" || { inv "provclient printed no caps line (sha $(sha256sum < "$TOOLS/provclient-arm64" | cut -c1-16)): a stale tool — rebuild (scripts/dv-provclient-tools.sh)"; return 2; }
	return 0; }
ud_status(){ ud_pc h0.pem -- update-status "$H0" | grep '^RESULT update.status'; }
# ud_poll <secs> <phase> [reason] [sha16]: status every 5 s until it says that; prints the last line
ud_poll(){ local t0 l; t0=$(mono); while :; do l=$(ud_status); ud_phase "$l" "$2" "${3:-any}" "${4:-any}" && { echo "$l"; return 0; }; [ $(( $(mono) - t0 )) -ge "$1" ] && { echo "$l"; return 1; }; sleep 5; done; }
# ud_check <manifest hex> [PCBIN=old]: update-check, >= 11 s after the last one; ERate -> one retry; code 7 with a slot /
# config-save busy why -> one retry after 20 s. Sets UDLOG (the helper's lines since the mark). Prints the RESULT line.
ud_check(){ local hx=$1 pb=${2:-} r w i
	for i in 1 2; do
		w=$(( UD_LASTCHK + 11 - $(mono) )); [ $w -gt 0 ] && sleep $w
		ud_mark; r=$(ud_pc h0.pem $pb -- update-check "$H0" "$hx" | grep '^RESULT update.check'); UD_LASTCHK=$(mono); UDLOG=$(ud_log)
		case "$(code "$r")" in
			17) [ $i = 1 ] && { say "update.check ERate — one retry"; continue; } ;;
			7) if [ $i = 1 ] && grep -qE 'batman-slot busy|config-save' <<< "$UDLOG"; then say "update.check busy (slot / config-save lock) — one retry after 20 s"; sleep 20; continue; fi ;;
		esac; break
	done; echo "$r"; }
# ud_manifest <payload, WSL path> <out dir name> [signrel options]: MHEX, MSUMS (sha256(SHA256SUMS), X for V); rc 1 = INVALID printed
ud_manifest(){ local p=$1 d=$MDIR/$2 m; shift 2
	m=$(wsl_ "$PYW" "$REPO_WSL/tests/tools/peer/signrel.py" "$p" --board "$BOARD" --version "$V_NOW" --out "$d" "$@" 2>&1 | tr -d '\r' | tail -1)
	case "$m" in "MANIFEST sha="*) ;; *) inv "signrel ($*): [$m]"; return 1 ;; esac
	MSUMS=$(sed -n 's/.* sums=\([0-9a-f]*\).*/\1/p' <<< "$m"); MHEX=$(wsl_ cat "$d/manifest.hex" | tr -d '\r\n')
	[[ $MSUMS =~ ^[0-9a-f]{64}$ ]] && [ -n "$MHEX" ] || { inv "signrel output unreadable [$m]"; return 1; }
	return 0; }
# ud_gen <kind> <out name>: a generated payload in MDIR (p3-payloads.sh), accepted; GENF = its WSL path
ud_gen(){ local o; GENF=$MDIR/$2
	case "$1" in mal[1-4]) o=$(wsl_ bash "$REPO_WSL/scripts/dv/data/p3-payloads.sh" malicious "${1#mal}" "$PAYW" "$PSHA_V" "$GENF" 2>&1 | tr -d '\r') ;;
		*) o=$(wsl_ bash "$REPO_WSL/scripts/dv/data/p3-payloads.sh" "$1" "$PAYW" "$PSHA_V" "$GENF" 2>&1 | tr -d '\r') ;; esac
	grep -q "^ACCEPT $1 ok$" <<< "$o" && grep -q '^PAYLOAD-SHA ' <<< "$(tail -1 <<< "$o")" || { inv "generator $1: $(tail -3 <<< "$o" | tr '\n' '|')"; return 1; }
	say "generated $1: $(tail -1 <<< "$o")"; return 0; }
hostp(){ echo "//wsl.localhost/Ubuntu-24.04$1"; }   # a WSL path as Git Bash reads it
# ud_window <sha>: bulk-open; prints the line (ssid / ip / port / expires only)
ud_window(){ ud_pc h0.pem -- bulk-open "$H0" "$1" | grep '^RESULT bulk.open'; }
ud_close(){ ud_pc h0.pem -- bulk-close "$H0" | grep '^RESULT bulk.close'; }
# ud_upload <host file>: as 471 (provclient exec); root only lstats it; size + sha read as 471 under a host timeout
ud_upload(){ local fl=$1 o sz sh p
	o=$(timeout 300 ssh $SSHO root@$NODE "$PCD/provclient node exec /bin/sh -c 'id -u; umask 077; exec cat > $BULK'" < "$fl" 2>&1 | tr -d '\r')
	[ "$(head -1 <<< "$o")" = 471 ] || { inv "upload: the writer is not uid 471 ([$(head -1 <<< "$o")])"; return 1; }
	o=$(qr "ls -ln $BULK"); set -- $o
	[ "${1:0:1}" = - ] && [ "${3:-}" = 471 ] || { inv "upload: ls -ln [$o] (want a regular file of 471)"; return 1; }
	o=$(timeout 90 ssh $SSHO root@$NODE "$PCD/provclient node exec /bin/sh -c 'echo \$\$; wc -c < $BULK; sha256sum < $BULK'" 2>/dev/null | tr -d '\r'); r=$?
	if [ $r = 124 ]; then p=$(head -1 <<< "$o"); case "$p" in ''|*[!0-9]*) ;; *) q "kill $p" ;; esac; inv "upload: the 471 reader hit the host timeout"; return 1; fi
	sz=$(sed -n 2p <<< "$o" | tr -d ' '); sh=$(sed -n 3p <<< "$o" | cut -c1-64)
	[ "$sz" = "$(wc -c < "$fl" | tr -d ' ')" ] && [ "$sh" = "$(sha256sum < "$fl" | cut -c1-64)" ] || { inv "upload: size / sha as 471 [$sz $sh] differ from the host file"; return 1; }
	say "uploaded $(basename "$fl") as 471: $sz B"; return 0; }
# ud_prepare <sum> [ENV=...]: the guarded prepare in this boot
ud_prepare(){ local s=$1; shift; ud_pc h0.pem GUARD=prepare:"$(boot8)" "$@" -- update-prepare "$H0" "$s" | grep -E '^(RESULT update.prepare|WRONG-STATE)'; }
ud_apply(){ ud_pc h0.pem GUARD=apply:"$(boot8)" -- update-apply "$H0" "$1" | grep -E '^(RESULT update.apply|WRONG-STATE)'; }
# ud_refused <RESULT line> <code> <reason> <why text> <row>: asserts the code / reason AND the helper's log line
ud_refused(){ local l=$1 log
	log=$(ud_log)
	if [ "$(code "$l")" = "$2" ] && [ "$(f "$l" reason)" = "$3" ] && ud_why "$log" "$4"; then ok "$5: code $2 reason $3, the helper logged \"$4\""
	else no "$5: [$l] want code $2 reason $3 and the log line \"$4\" ($(grep 'batman-provhelper\[' <<< "$log" | tail -2 | cut -c1-200 | tr '\n' '|'))"; fi; }
ud_flag0(){ [ "$(qr "$TBGET")" = tryboot_flag=0 ]; }
# the wireless file's mode (ls -ln field 1): recorded at the start, asserted after every harness uci commit
wmode(){ qr 'ls -ln /etc/config/wireless' | awk '{print $1}'; }
# ud_ssid_window <ssid value, node-side literal> <row>: UD13 / UD6 (b)'s change with its journal (254-v16-ud §4.3):
# svc-start joinwatch, stop; ssid hex round trip (INVALID before the change); p5-save, ssid-restore; commit; mode check
UDIDS=""
ud_ssid_on(){ local o h
	o=$(pl undo-add svc-start joinwatch) || { inv "$2: undo-add svc-start: $o"; return 1; }; UDIDS=$(awk '{print $2}' <<< "$o")
	q "/etc/init.d/joinwatch stop >/dev/null 2>&1"; [ -z "$(qr 'pidof joinwatch')" ] || { no "$2: joinwatch still runs after stop"; return 1; }
	o=$(pl ssid-hex); case "$o" in "HEX="*" RT=ok") h=${o#HEX=}; h=${h% RT=ok} ;; *) inv "$2: the S0 ssid cannot be journalled [$o] — nothing changed"; ud_ssid_off "$2" nohex; return 1 ;; esac
	o=$(pl undo-add p5-save) || { inv "$2: undo-add p5-save: $o"; return 1; }; UDIDS="$UDIDS $(awk '{print $2}' <<< "$o")"
	o=$(pl undo-add ssid-restore "$h") || { inv "$2: undo-add ssid-restore: $o"; return 1; }; UDIDS="$UDIDS $(awk '{print $2}' <<< "$o")"; UDHEX=$h
	q "umask 022; uci set \"wireless.default_radio0.ssid=$1\" && uci commit wireless"
	ud_mode "$WMODE0" "$(wmode)" && ok "$2: the wireless file's mode after the commit is the S0 mode" || no "$2: the wireless file's mode changed after the commit ($(wmode), S0 $WMODE0)"
	return 0; }
# ud_ssid_off <row>: the inline inverse — S0 ssid (the executor's own code: lease ssid-set), mode, --save, --check rc 0
# (<= 30 s), joinwatch started and running; only then undo-done for the three lines
ud_ssid_off(){ local o t0 r=0
	if [ "${2:-}" != nohex ]; then
		o=$(pl ssid-set "$UDHEX"); grep -q '^SSID-SET ok' <<< "$o" || { no "$1: S0 ssid not restored: $o"; r=1; }
		ud_mode "$WMODE0" "$(wmode)" || { no "$1: the wireless file's mode after the restore ($(wmode), S0 $WMODE0)"; r=1; }
		q "batman-config-save --save >/dev/null 2>&1"; t0=$(mono)
		until [ "$(qr 'batman-config-save --check >/dev/null 2>&1; echo $?')" = 0 ]; do [ $(( $(mono) - t0 )) -ge 30 ] && { no "$1: --check not rc 0 within 30 s after the restore"; r=1; break; }; sleep 5; done
	fi
	q "/etc/init.d/joinwatch start >/dev/null 2>&1"; sleep 2; [ -n "$(qr 'pidof joinwatch')" ] || { no "$1: joinwatch not running after the restore"; r=1; }
	[ $r = 0 ] || return 1
	for i in $UDIDS; do o=$(pl undo-done "$i"); grep -q "^UNDO-DONE $i$" <<< "$o" || { no "$1: undo-done $i: $o"; r=1; }; done
	[ $r = 0 ] && ok "$1: restored inline (ssid, mode, p5 fresh, joinwatch), journal lines $UDIDS done"; UDIDS=""; return $r; }

# ==== the arms ========================================================================================================
ud_begin(){	# common start: lease, tools, H0, S0 status, AP on, wireless mode, payload V
	pr_begin "$1" || { pr_result; exit 1; }
	pr_h0 && pr_pc_place || { pr_abort "provclient / bench owner key"; pr_result; exit 1; }
	V_NOW=$(field "$(qr "$ST")" ver); BOARD=$(qr "sed -n 's/^BATMAN_BOARD=//p' /etc/batman-build"); BOARD=${BOARD:-ekh-bcm2711}
	PR_UST0=$(ud_status); say "S0 status: $PR_UST0"
	local d; d=$(ud_s0_status "$PR_UST0"); [ "$d" = ok ] || { inv "${d#inv }"; PR_UST0=""; pr_end; pr_result; exit 2; }
	o=$(qr 'halow-setkey --status 2>/dev/null | grep "^ap "'); say "AP: $o"
	case " $o " in *" disabled=0 "*) ok "phone AP on at the start" ;; *) inv "phone AP off ($o): every upload row is INVALID (v4: no ap-on step)"; pr_end; pr_result; exit 2 ;; esac
	WMODE0=$(wmode); [ -n "$WMODE0" ] || { inv "the wireless file's mode could not be read"; pr_end; pr_result; exit 2; }
	PAYH=$(ls "$OUTS/$V_NOW/ekh-bcm2711/"*-ab-payload.tar.gz 2>/dev/null | head -1)
	[ -n "$PAYH" ] || { inv "no payload tar for $V_NOW under $OUTS"; pr_end; pr_result; exit 2; }
	PAYW=/home/yello/out/$V_NOW/ekh-bcm2711/$(basename "$PAYH"); PSHA_V=$(sha256sum < "$PAYH" | cut -c1-64)
	MDIR=/home/yello/.batman-dv/run-$RUN; wsl_ bash -c "umask 077; mkdir -p $MDIR" >/dev/null
	ud_manifest "$PAYW" v || { pr_end; pr_result; exit 2; }; VHEX=$MHEX; X=$MSUMS; X16=${X:0:16}
	SQ=$(wsl_ bash -c "tar -tzvf $PAYW root.squashfs" | awk '{print $3}'); case "$SQ" in ''|*[!0-9]*) inv "root.squashfs size unreadable"; pr_end; pr_result; exit 2 ;; esac
	ok "V = $V_NOW, X = $X16…, root.squashfs $SQ B"
}
ud_end(){ wsl_ rm -rf "$MDIR" >/dev/null; pr_end "$@"; pr_result; }
ud_ul(){ UDT0=$(pr_slot_ticks); UDR=$(ud_check "$1"); say "check: $UDR"; }
# ud_verdicts: a judge's PASS / FAIL / INVALID lines counted in THIS shell (never through a pipe into a subshell)
ud_verdicts(){ local x; while IFS= read -r x; do case "$x" in PASS*) ok "${x#PASS }" ;; FAIL*) no "${x#FAIL }" ;; INVALID*) inv "${x#INVALID }" ;; *) say "$x" ;; esac; done <<< "$1"; }
ud_lk(){ local why; if why=$(pr_precheck_ran "$UDR"); then pr_slot_free "$1" "$UDT0"; else nj "UD-L ($1): $why"; fi; }

arm_refuse(){
	ud_begin 7200
	# ---- step 0: the provclient flip (pre-UD binary vs this one, same image / manifest / minute)
	if q "[ -x $PCD/provclient.old ]"; then
		r=$(ud_check "$VHEX" PCBIN=old); say "old: $r"
		if [ "$(code "$r")" = 20 ] && ud_why "$UDLOG" 'verb update.check refused: code 20 (arg 1: want 0 bytes)'; then ok "step 0: the pre-UD provclient's update.check -> code 20 (arg 1: want 0 bytes)"
		else no "step 0: old binary [$r] $(grep 'batman-provhelper\[' <<< "$UDLOG" | tail -1)"; fi
		r=$(ud_pc h0.pem PCBIN=old -- update-status "$H0" | grep '^RESULT update.status'); [ "$(code "$r")" = 0 ] && ok "step 0: old binary update-status code 0" || no "step 0: old update-status [$r]"
	else inv "step 0: no pre-UD provclient ($TOOLS/provclient-arm64.pre-ud; PRE_UD=1 scripts/dv-provclient-tools.sh)"; fi
	ud_ul "$VHEX"; if [ "$(code "$UDR")" = 0 ] && [ "$(f "$UDR" ok)" = true ]; then ok "step 0 / UD7 P: this provclient's update.check of V -> ok=true"; else no "update.check of V: [$UDR]"; fi
	ud_lk "update.check of V"
	# ---- UD7: eight refusals, each with the helper's why
	local i k OLD
	OLD=$(ls -d "$OUTS"/1.5.14-wsl.35+*/ekh-bcm2711 2>/dev/null | grep -v -e wbox -e dirty | head -1)
	for k in "bad-sig|--bad-sig|11|S: does not verify against the endorsed key" "key-other|--key other|11|S: does not verify against the endorsed key" \
		"serial-0|--unsafe-serial 0|11|E: payload is not {1: K 65 B, 2: serial >= 1}" "wrong-board|--wrong-board|3|payload for " \
		"older|OLD|6|a downgrade from " "min-from|--min-from 1.5.14-wsl.37|4|needs " \
		"bootcfg|--bootcfg-sha $(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')|5|is not one this release allows" "unparsable|--unparsable-version|11|S: version unparsable"; do
		IFS='|' read -r n o rs w <<< "$k"
		if [ "$o" = OLD ]; then
			[ -n "$OLD" ] || { inv "UD7 $n: no wsl.35 payload under $OUTS"; continue; }
			ud_manifest "/home/yello/out/$(basename "$(dirname "$OLD")")/ekh-bcm2711/$(basename "$(ls "$OLD"/*-ab-payload.tar.gz | head -1)")" "ud7-$n" --version 1.5.14-wsl.35 || continue
		else ud_manifest "$PAYW" "ud7-$n" $o || continue; fi
		r=$(ud_check "$MHEX"); say "UD7 $n: $r"
		if [ "$(code "$r")" = 0 ] && [ "$(f "$r" ok)" = false ] && [ "$(f "$r" reason)" = "$rs" ] && ud_why "$UDLOG" "update.check: refused, reason $rs (" && ud_why "$UDLOG" "$w"; then ok "UD7 $n: ok=false reason $rs, why \"$w\""
		else no "UD7 $n: [$r] want ok=false reason $rs and \"$w\" ($(grep 'batman-provhelper\[' <<< "$UDLOG" | tail -1 | cut -c1-200))"; fi
	done
	r=$(ud_window "$X"); say "UD7 P: $r"; [ "$(code "$r")" = 0 ] && ok "UD7 P: bulk-open X still succeeds (the refusals did not replace the pending)" || no "UD7 P: bulk-open X [$r]"
	r=$(ud_close); [ "$(code "$r")" = 0 ] || no "bulk-close [$r]"
	# ---- UD13: a quote in the AP ssid, joinwatch stopped
	R8=${RUN: -8}
	if ud_ssid_on "dv'q$R8" UD13; then
		o=$(qr 'batman-config-save --check 2>&1; echo "rc=$?"'); rc=$(sed -n 's/^rc=//p' <<< "$o")
		ud_check_text "$o" "$rc" && ok "UD13 P: --check rc 5 'p5 stale: wireless.default_radio0.ssid' without (unpersistable (SKIP_UNSAFE)" || no "UD13 P: --check [$o]"
		ud_ul "$VHEX"; say "UD13: $UDR"
		if [ "$(f "$UDR" ok)" = true ] && ud_why "$UDLOG" 'p5 stale only in keys P3 added: --save rc 0'; then ok "UD13: update.check ok=true, the helper saved p5 ('p5 stale only in keys P3 added: --save rc 0')"
		else no "UD13: [$UDR] $(grep 'batman-provhelper\[' <<< "$UDLOG" | tail -2 | tr '\n' '|')"; fi
		ud_lk "UD13's update.check"
		ud_ssid_off UD13
	fi
	# ---- UD20c: Y = the badpayload manifest; sums_sha(Y) != X asserted before the node is touched
	if ud_gen badpayload bad.tar.gz && ud_manifest "$GENF" y --allow-no-key; then
		Y=$MSUMS; YHEX=$MHEX
		if ud_y_differs "$Y" "$X"; then
			r=$(ud_check "$VHEX"); [ "$(f "$r" ok)" = true ] || no "UD20c: owner check X [$r]"
			r=$(ud_check "$YHEX"); say "UD20c: provclient check Y: $r"
			r=$(ud_window "$Y"); [ "$(code "$r")" = 0 ] && ok "UD20c P: bulk-open Y succeeds (the pending is now Y)" || no "UD20c P: bulk-open Y [$r]"
			ud_close >/dev/null
			ud_mark; r=$(ud_window "$X"); ud_refused "$r" 24 15 "no pending update of this owner for this sha" "UD20c bulk-open X"
			ud_mark; r=$(ud_prepare "$X"); ud_refused "$r" 24 15 "no pending update for this sha" "UD20c prepare X"
			r=$(ud_status); case " $r " in *" phase=2 "*) no "UD20c: a worker started [$r]" ;; *) ok "UD20c: no worker ($r)" ;; esac
			r=$(ud_check "$VHEX"); r=$(ud_window "$X"); [ "$(code "$r")" = 0 ] || no "UD20c arm 2: bulk-open X [$r]"
			r=$(ud_check "$YHEX"); [ "$(code "$r")" = 7 ] && ud_why "$UDLOG" "an update is being uploaded or written" && ok "UD20c arm 2: update-check Y in a window -> code 7" || no "UD20c arm 2: [$r]"
			r=$(ud_status); ud_phase "$r" 1 any "$X16" && ok "UD20c arm 2: status phase=1 sha=$X16" || no "UD20c arm 2 status [$r]"
			ud_close >/dev/null
			# ---- UD20b: pending X, an owner-op valid over Y
			ud_mark; r=$(ud_prepare "$Y"); ud_refused "$r" 24 15 "no pending update for this sha" "UD20b prepare Y"
		else inv "UD20c: sums_sha(Y) = X ($Y): Y would test nothing"; fi
	fi
	# ---- UD8b: a FIFO instead of the upload
	r=$(ud_check "$VHEX"); r=$(ud_window "$X")
	if [ "$(code "$r")" = 0 ]; then
		o=$(q "$PCD/provclient node exec /bin/sh -c 'id -u; mkfifo $BULK'"); p=$(qr "ls -ln $BULK")
		if [ "$(head -1 <<< "$o")" = 471 ] && [ "${p:0:1}" = p ] && [ "$(awk '{print $3}' <<< "$p")" = 471 ]; then ok "UD8b P: the upload is a FIFO of 471 ($p)"
			ud_mark; r=$(ud_prepare "$X"); ud_refused "$r" 24 15 "the upload is missing or incomplete" "UD8b prepare"
			ud_close >/dev/null; sleep 8; [ -z "$(qr "ls -ln $BULK 2>/dev/null")" ] && ok "UD8b: the FIFO is gone after bulk-close" || no "UD8b: still there: $(qr "ls -ln $BULK")"
		else inv "UD8b P: [$o] [$p]"; ud_close >/dev/null; fi
	else no "UD8b: bulk-open X [$r]"; fi
	ud_end
}

arm_write(){
	ud_begin 10800; PR_WROTE_B=1
	local n w bi0 bi
	bi0=$(ud_bootinfo)
	for n in 1 2 3 4; do
		pr_lease_renew +1800 || break
		ud_gen "mal$n" "m$n.tar.gz" || continue
		if [ $n = 3 ]; then ud_manifest "$PAYW" "m3" --size-of "$GENF" || continue; else ud_manifest "$GENF" "m$n" || continue; fi
		case $n in 1) w="is not a regular file" ;; 2) w="members after root.squashfs" ;; 3) w="data after the gzip stream" ;; 4) w="too many members" ;; esac
		r=$(ud_check "$MHEX"); [ "$(f "$r" ok)" = true ] || { no "UD8 ($n): check [$r]"; continue; }
		r=$(ud_window "$MSUMS"); ud_upload "$(hostp "$GENF")" || { ud_close >/dev/null; continue; }
		ud_mark; r=$(ud_prepare "$MSUMS"); say "UD8 ($n) prepare: $r"
		r=$(ud_poll 300 0 11); log=$(ud_log)
		if ud_phase "$r" 0 11 && ud_why "$log" "update worker: prepare refused, reason 11 (" && ud_why "$log" "$w"; then ok "UD8 ($n): phase 0 + 11, worker why \"$w\""
		else no "UD8 ($n): [$r] $(grep 'batman-provhelper\[' <<< "$log" | tail -1 | cut -c1-200)"; fi
		bi=$(ud_bootinfo); [ "$bi" = "$bi0" ] && ud_flag0 && ok "UD8 ($n): bootinfo B unchanged, tryboot flag 0" || no "UD8 ($n): B changed or flag set ($(tr '\n' ' ' <<< "$bi"))"
	done
	# ---- UD8c: V uploaded, then replaced (rm first: two copies do not fit) by the same-length mutant
	if ud_gen mutate mut.tar.gz; then
		r=$(ud_check "$VHEX"); r=$(ud_window "$X")
		if ud_upload "$PAYH"; then
			q "$PCD/provclient node exec /bin/rm -f $BULK" >/dev/null
			if ud_upload "$(hostp "$GENF")"; then
				ud_mark; r=$(ud_prepare "$X"); r=$(ud_poll 300 0 11); log=$(ud_log)
				ud_phase "$r" 0 11 && ud_why "$log" "root.squashfs does not match SHA256SUMS" && ok "UD8c: phase 0 + 11, 'root.squashfs does not match SHA256SUMS'" || no "UD8c: [$r]"
				bi=$(ud_bootinfo); [ "$bi" = "$bi0" ] && ok "UD8c: B unchanged" || no "UD8c: B changed"
			fi
		fi; ud_close >/dev/null 2>&1
	fi
	# ---- UD6 (b): p5 stale at the worker's precheck (joinwatch stopped: nothing re-saves p5)
	pr_lease_renew +1800
	r=$(ud_check "$VHEX"); [ "$(f "$r" ok)" = true ] || no "UD6 (b): check [$r]"
	r=$(ud_window "$X")
	if ud_upload "$PAYH" && ud_ssid_on "dv-s${RUN: -8}" "UD6 (b)"; then
		ud_mark; r=$(ud_prepare "$X"); r=$(ud_poll 300 0 17); log=$(ud_log)
		ud_phase "$r" 0 17 && ud_why "$log" "batman-slot write rc 12: " && ud_why "$log" "p5 (config) is STALE vs the running config (wireless.default_radio0.ssid)" \
			&& ok "UD6 (b): phase 0 + 17, batman-slot write rc 12 'p5 (config) is STALE …'" || no "UD6 (b): [$r] $(grep 'batman-provhelper\[' <<< "$log" | tail -1 | cut -c1-200)"
		bi=$(ud_bootinfo); [ "$bi" = "$bi0" ] && ok "UD6 (b): B unchanged (precheck before begin_write)" || no "UD6 (b): B changed"
		ud_ssid_off "UD6 (b)"
	fi
	ud_close >/dev/null 2>&1
	# ---- UD20 neg / pos (+ the UD9 observe watcher)
	pr_lease_renew +2400
	r=$(ud_check "$VHEX"); r=$(ud_window "$X")
	if ud_upload "$PAYH"; then
		ud_mark; r=$(ud_prepare "$X" PROVCLIENT_SIGN_ARGS_SHA="$(printf 'ud20-neg' | sha256sum | cut -c1-64)"); say "UD20 neg: $r"
		log=$(ud_log); s=$(ud_status)
		if [ "$(code "$r")" = 3 ] && grep -q ' signed-for=' <<< "$r"; then
			ud_why "$log" "owner-op" && ok "UD20 neg: code 3 (signed for another sha), the helper logged the owner-op refusal" || no "UD20 neg: code 3 but no owner-op log line"
		else no "UD20 neg: [$r] want code 3 with signed-for="; fi
		case " $s " in *" phase=2 "*) no "UD20 neg: a worker started" ;; esac
		[ "$(qr "ls -ln $BULK" | cut -c1)" = - ] && ok "UD20 neg: the upload is still there" || no "UD20 neg: the upload is gone"
		ud_watch observe || :
		t0=$(pr_slot_ticks); r=$(ud_prepare "$X"); say "UD20 pos: $r"
		[ "$(code "$r")" = 0 ] || no "UD20 pos: prepare [$r]"
		r=$(ud_poll 900 3); if ud_phase "$r" 3 - "$X16"; then ok "UD20 pos: phase 2 -> 3 ($r)"; else no "UD20 pos: [$r]"; fi
		bi=$(ud_bootinfo); b=$(qr 'cat /proc/sys/kernel/random/boot_id')
		grep -q "verified=$X $b" <<< "$bi" && ok "UD20 pos: bootinfo B verified=<X> <this boot>" || no "UD20 pos: bootinfo B [$(tr '\n' ' ' <<< "$bi")]"
		pr_slot_free "the UD20 worker" "$t0"
		ud_watch_obs_end
		# ---- UD10b: a reboot drops the pending; the re-check stays 0 + 23, apply 24 / 15
		b=$(boot8); o=$(q "$(reboot_guarded "$b" A 1 prov-update-254)")
		if [ "$o" = SENT ] && pr_find 900 "$b" && pr_pc_place; then
			r=$(ud_poll 120 0 23); ud_phase "$r" 0 23 && ok "UD10b: after the reboot 0 + 23" || no "UD10b: after the reboot [$r]"
			r=$(ud_check "$VHEX"); r=$(ud_status); ud_phase "$r" 0 23 && ok "UD10b: after the re-check still 0 + 23 (verified= carries the old boot)" || no "UD10b: after the re-check [$r]"
			ud_mark; r=$(ud_apply "$X"); ud_refused "$r" 24 15 "the target slot is not verified for this sha in this boot" "UD10b apply"
		else no "UD10b: reboot [$o] / node not found"; fi
	fi
	ud_end wrote-b
}
# ---- the UD9 watcher: start + register in ONE ssh call, ud9.go only after the kill-pg line (254-v16-ud §1.5-1)
ud_watch(){ local o
	o=$(q "d=/tmp/run/batman-dv/$RUN; mkdir -m 700 \$d 2>/dev/null; [ -d \$d ] && cd \$d || exit 1; setsid sh $PRD/ud9-watch-254.sh $1 $RUN $SQ /dev/mmcblk0p4 </dev/null >/dev/null 2>&1 & p=\$!; echo \$p > \$d/ud9.pid; RUN_ID=$RUN sh $PRD/prov-lease-254.sh undo-add kill-pg \$p ud9-watch && touch \$d/ud9.go && echo WATCH \$p")
	UDW=$(sed -n 's/^WATCH //p' <<< "$o"); UDWID=$(sed -n 's/^UNDO-ADDED \([0-9]*\) .*/\1/p' <<< "$o")
	[ -n "$UDW" ] && [ -n "$UDWID" ] || { inv "UD9 watcher ($1) not started / not registered: $(echo $o)"; return 1; }
	say "UD9 watcher $1: pid $UDW, journal line $UDWID"; return 0; }
ud_watch_log(){ qr "tr -s ' ' < /opt/batdata/log/dv-ud9-$RUN.log 2>/dev/null | grep '^UD9-' | sed 's/ *\$//'"; }
ud_watch_gone(){ local i; for i in $(seq 1 "${1:-30}"); do [ -z "$(qr "[ -d /proc/$UDW ] && tr '\\0' ' ' < /proc/$UDW/cmdline | grep -c ud9-watch")" ] && return 0; sleep 2; done; return 1; }
ud_watch_done(){ local o; q "touch /tmp/run/batman-dv/$RUN/ud9.stop"
	ud_watch_gone 30 || { no "the UD9 watcher $UDW did not exit"; return 1; }
	o=$(pl undo-done "$UDWID"); grep -q "^UNDO-DONE $UDWID$" <<< "$o" || no "undo-done of the watcher line: $o"; }
ud_watch_obs_end(){ local l mac
	ud_watch_gone 30; l=$(ud_watch_log); say "UD9 observe: $l"; ud_watch_done
	mac=$(field "$(qr "$ST")" mac)
	if grep -qE '^UD9-OBS .* result=ok$' <<< "$l"; then
		mkdir -p "$UD9_OBS_DIR" && { echo "run=$RUN"; echo "version=$V_NOW"; echo "mac=$mac"; echo "date=$(date -u +%FT%TZ)"; echo "$l" | grep '^UD9-OBS'
			echo "log_sha256=$(qr "sha256sum < /opt/batdata/log/dv-ud9-$RUN.log | cut -c1-64")"; } > "$UD9_OBS_DIR/$V_NOW-${mac//:/}.txt" \
			&& ok "UD9 premise (output side): fd 1 = B's root, pos grows — saved for the kill arm" || no "cannot write $UD9_OBS_DIR"
	else inv "UD9 premise (output side) not shown: [$l]"; fi; }

# ud_cut_wait <boot8 before the prepare>: polls the watcher's p6 log every 2 s (254-v16-ud §1.5, B v5 m1). A UD9-MISS
# line -> INVALID at once with NO pr_find (the node was never reset); only a lost ssh connection after UD9-PRE-B is
# "cut sent" -> pr_find 900 <old boot8>; no line by the watcher's deadline (+60 s) -> INVALID. Sets UDCUTV (the
# verdict), UDCUTL (the last lines read) and UDCUTF (pr_find's rc; - when it was not called).
ud_cut_wait(){ local t0 o rc
	t0=$(mono); UDCUTV=wait; UDCUTL=""; UDCUTF=-
	while [ "$UDCUTV" = wait ]; do
		o=$(timeout 20 ssh $SSHO root@$NODE "tr -s ' ' < /opt/batdata/log/dv-ud9-$RUN.log | grep '^UD9-'" 2>/dev/null); rc=$?; o=$(tr -d '\r' <<< "$o")
		[ -n "$o" ] && UDCUTL=$o
		if [ $rc = 255 ] || [ $rc = 124 ]; then UDCUTV=$(ud_cut_flow "LOST $UDCUTL")
		elif [ $(( $(mono) - t0 )) -ge 960 ]; then UDCUTV=$(ud_cut_flow "DEADLINE")
		else UDCUTV=$(ud_cut_flow "$UDCUTL"); fi
		[ "$UDCUTV" = wait ] && sleep 2
	done
	say "UD9 cut: $UDCUTV ($(tr '\n' '|' <<< "$UDCUTL"))"
	[ "$UDCUTV" = cut ] && { pr_find 900 "$1"; UDCUTF=$?; }
	return 0; }
arm_kill(){
	ud_begin 7200; PR_WROTE_B=1
	local mac g l t0 b st bi s tr o
	mac=$(field "$(qr "$ST")" mac); g=$(ud_obs_gate "$(cat "$UD9_OBS_DIR/$V_NOW-${mac//:/}.txt" 2>/dev/null)" "$V_NOW" "$mac")
	if [ "$g" != ok ]; then inv "UD9 kill and cut: ${g#inv }"; ud_end; return; fi
	ok "UD9: the write arm's observation holds for $V_NOW on $mac"
	# ---- kill sub-arm (no reserve)
	r=$(ud_check "$VHEX"); r=$(ud_window "$X")
	if ud_upload "$PAYH" && ud_watch kill; then
		tk=$(pr_slot_ticks); r=$(ud_prepare "$X"); say "UD9 kill prepare: $r"
		t0=$(mono); while [ $(( $(mono) - t0 )) -lt 900 ]; do l=$(ud_watch_log); grep -qE '^UD9-(FIRE|MISS)' <<< "$l" && break; sleep 2; done
		say "watcher: $l"; orph=$(sed -n 's/.* orphan=\([0-9]*\).*/\1/p' <<< "$l")
		g=0; if [ -n "$orph" ]; then for i in $(seq 1 60); do [ -z "$(qr "[ -d /proc/$orph ] && echo up")" ] && { g=1; break; }; sleep 5; done; fi
		o=$(pr_slot_free "the orphan's exit" "$tk"); echo "$o"; sf=$(grep -E '^(PASS|FAIL|INVALID)' <<< "$o" | tail -1)
		case "$sf" in PASS*) sf=PASS ;; INVALID*) inv "UD9 kill: ${sf#INVALID }" ;; esac
		st=$(ud_poll 180 0 22); bi=$(ud_bootinfo); s=$(qr "$ST"); tr=$(qr 'tail -40 /opt/batdata/log/ota-trace.log')
		ud_verdicts "$(ud_kill_judge "$l" "$SQ" "$g" "$sf" "$st" "$bi" "$s" "$tr")"
		ud_flag0 && ok "UD9 kill: tryboot flag 0" || no "UD9 kill: tryboot flag set"
		ud_watch_done
	fi
	ud_close >/dev/null 2>&1
	# ---- cut sub-arm: the host polls the p6 log; MISS -> INVALID, no pr_find; a lost connection after PRE-B = cut
	pr_lease_renew +2400
	r=$(ud_check "$VHEX"); r=$(ud_window "$X")
	if ud_upload "$PAYH" && ud_watch cut; then
		b=$(boot8); r=$(ud_prepare "$X"); say "UD9 cut prepare: $r"
		ud_cut_wait "$b"; v=$UDCUTV
		case "$v" in
			cut) if [ "$UDCUTF" = 0 ] && pr_pc_place; then
					st=$(ud_poll 180 0 22); bi=$(ud_bootinfo); s=$(qr "$ST"); br=$(qr 'tail -1 /opt/batdata/log/boot-reasons.log')
					l=$(ud_watch_log)
					ud_verdicts "$(ud_cut_judge "$l" "$SQ" "$st" "$bi" "$s" "$br")"
				else pr_needs_person "UD9 cut: no node after the reset"; fi ;;
			*) inv "UD9 cut: ${v#invalid } (no pr_find: the node was never reset)"; ud_watch_done ;;
		esac
	fi
	ud_end wrote-b
}

arm_trial(){
	ud_begin 14400; PR_WROTE_B=1
	local b r o ul hv bs off1 off2 c0 c1 rec
	hv=$V_NOW
	ud_to3(){	# <hex> <sums> <host file> <row>: check -> window -> upload -> prepare -> phase 3
		r=$(ud_check "$1"); [ "$(f "$r" ok)" = true ] || { no "$4: check [$r]"; return 1; }
		r=$(ud_window "$2"); ud_upload "$3" || return 1
		r=$(ud_prepare "$2"); r=$(ud_poll 900 3); ud_phase "$r" 3 && { ok "$4: phase 3 ($r)"; return 0; }; no "$4: phase 3 not reached [$r]"; return 1; }
	ud_hold(){	# the hold flag, journalled first (rm-hold)
		o=$(pl undo-add rm-hold); UDHOLD=$(sed -n 's/^UNDO-ADDED \([0-9]*\) .*/\1/p' <<< "$o"); [ -n "$UDHOLD" ] || { inv "undo-add rm-hold: $o"; return 1; }
		q "printf '%s\n' '$hv' > $HOLDF; sync"; [ "$(qr "cat $HOLDF")" = "$hv" ]; }
	ud_land(){	# after a guarded apply: the B trial of V, hold effective
		pr_find 900 "$1" || { pr_needs_person "$2: no node after the apply"; return 1; }
		pr_lease_renew +1800; s=$PR_STATE; PR_LAND_BOOT=$(field "$s" boot)
		[ "$(field "$s" slot)" = B ] && [ "$(field "$s" trial_rc)" = 0 ] && [ "$(field "$s" held)" = 1 ] && [ "$(field "$s" hold)" = "[]" ] \
			|| { no "$2: not a held B trial ($s)"; return 1; }
		pr_trial_guard; o=$(pl undo-done "$UDHOLD"); grep -q "^UNDO-DONE" <<< "$o" || no "$2: undo-done rm-hold: $o"
		pr_pc_place; ok "$2: landed in the held B trial"; }
	# ---- UD2: same version reverted -> 6
	if ud_to3 "$VHEX" "$X" "$PAYH" UD2 && ud_hold; then
		b=$(boot8); r=$(ud_apply "$X"); say "UD2 apply: $r"
		if ud_land "$b" UD2; then
			r=$(ud_status); ud_phase "$r" 4 && pr_wait_held 480 && ok "UD2: phase 4 + HELD in the trial" || no "UD2: in the trial [$r]"
			pr_wait_reverted && pr_pc_place && { r=$(ud_status); ud_phase "$r" 6 - && [ "$(field "$PR_STATE" slot)" = A ] && ok "UD2: reverted, A committed, phase 6" || no "UD2: after the revert [$r]"; }
		fi
	fi
	bs=$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null'); say "bad-slot after UD2: [$bs]"
	off1=$(qr "grep -b 'TRIAL-REVERTED' /opt/batdata/log/autocommit.log | tail -1 | cut -d: -f1")
	# ---- UD4 (= UD5 i): a B that does not boot -> 6 + 18; B's boot evidenced by the PANIC record
	if ud_gen badpayload bad.tar.gz && ud_manifest "$GENF" bad --allow-no-key; then
		c0=$(qr 'ls /opt/batdata/crash 2>/dev/null')
		if ud_to3 "$MHEX" "$MSUMS" "$(hostp "$GENF")" UD4; then
			off2=$(qr 'wc -c < /opt/batdata/log/autocommit.log')
			b=$(boot8); r=$(ud_apply "$MSUMS"); say "UD4 apply: $r"
			if pr_find 900 "$b" && pr_pc_place; then
				r=$(ud_poll 180 6 18); ud_phase "$r" 6 18 && [ "$(field "$PR_STATE" slot)" = A ] && ok "UD4 / UD5 (i): phase 6 + 18 (not 6), A committed" || no "UD4: [$r]"
				[ -n "$off1" ] && [ -n "$off2" ] && [ "$off1" -lt "$off2" ] && ok "UD5 (i) P: UD2's revert line (byte $off1) lies before UD4's apply offset ($off2)" || no "UD5 (i) P: offsets [$off1] [$off2]"
				br=$(qr 'tail -1 /opt/batdata/log/boot-reasons.log'); c1=$(qr 'ls /opt/batdata/crash 2>/dev/null')
				rec=$(comm -13 <(sort <<< "$c0") <(sort <<< "$c1") | grep dmesg-ramoops | tr '\n' ' ')
				g=0; for x in $rec; do case "$x" in *.enc.z) ;; *) qr "grep -qE 'Unable to mount root|VFS:' /opt/batdata/crash/$x" && g=1 ;; esac; done
				ud_verdicts "$(ud4_judge "$br" "$rec" "$g")"
			else pr_needs_person "UD4: 04 did not come back after the panicking trial (power-cycle it)"; ud_end wrote-b; return; fi
		fi
	fi
	# ---- UD1 (+ UD10, UD5 ii): T -> trial -> commit -> 5
	bs=$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null')
	[ "$bs" = "slot=B version=$hv" ] && ok "UD5 (ii) P: bad-slot = slot=B version=V before UD1" || inv "UD5 (ii) P: bad-slot [$bs]"
	if ud_to3 "$VHEX" "$X" "$PAYH" UD1; then
		bi=$(ud_bootinfo)
		q '/etc/init.d/batman-provhelper restart >/dev/null 2>&1'; sleep 5
		r=$(ud_poll 90 0 23); ud_phase "$r" 0 23 && ok "UD10: after a helper restart 0 + 23" || no "UD10: after the restart [$r]"
		r=$(ud_check "$VHEX"); r=$(ud_status); ud_phase "$r" 3 && ok "UD10: a re-check without upload -> phase 3 (no worker)" || no "UD10: after the re-check [$r]"
		[ "$(ud_bootinfo)" = "$bi" ] && ok "UD10: bootinfo B unchanged" || no "UD10: bootinfo B changed"
		if ud_hold; then
			b=$(boot8); r=$(ud_apply "$X"); say "UD1 apply: $r"
			if ud_land "$b" UD1; then
				r=$(ud_status); ud_phase "$r" 4 && ok "UD1: phase 4 in the trial" || no "UD1: in the trial [$r]"
				r=$(ud_check "$VHEX"); [ "$(f "$r" ok)" = false ] && [ "$(f "$r" reason)" = 1 ] && ok "UD1: update.check in the trial -> ok=false reason 1" || no "UD1: check in the trial [$r]"
				o=$(QT=900 q "$(release_guarded "$PR_LAND_BOOT" B)" | tail -1); say "UD1 release: $o"
				grep -q 'release: committed' <<< "$o" && ok "UD1: release: committed" || no "UD1: release [$o]"
				pr_pc_place; r=$(ud_status); ud_phase "$r" 5 && ok "UD1 / UD5 (ii): phase 5" || no "UD1: after the commit [$r]"
				[ -z "$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null')" ] && ok "UD5 (ii): bad-slot removed by the commit" || no "UD5 (ii): bad-slot still there"
				back_to_a && pr_pc_place && { r=$(ud_status); ud_phase "$r" 0 - && ok "UD1: back on A, phase 0" || no "UD1: after back_to_a [$r]"; }
			fi
		fi
	fi
	ud_end wrote-b
}

# ==== t1 (the R rows on any image) ====================================================================================
arm_t1(){
pr_begin 1200 || { pr_result; exit 1; }
pr_h0 && pr_pc_place || { pr_abort "provclient / bench owner key"; pr_result; exit 1; }
V_NOW=$(field "$(qr "$ST")" ver); BOARD=$(qr "sed -n 's/^BATMAN_BOARD=//p' /etc/batman-build"); BOARD=${BOARD:-ekh-bcm2711}
PAYH=$(ls "$OUTS/$V_NOW/ekh-bcm2711/"*-ab-payload.tar.gz 2>/dev/null | head -1)
[ -n "$PAYH" ] || { inv "no payload tar for $V_NOW under $OUTS (the manifest is built from it)"; pr_end; pr_result; exit 2; }
PAYW=/home/yello/out/$V_NOW/ekh-bcm2711/$(basename "$PAYH")   # the same file, WSL path (signrel runs in the venv)
MDIR=/home/yello/.batman-dv/run-$RUN; wsl_ bash -c "umask 077; mkdir -p $MDIR" >/dev/null
m=$(wsl_ "$PYW" "$REPO_WSL/tests/tools/peer/signrel.py" "$PAYW" --board "$BOARD" --version "$V_NOW" --allow-no-key --out "$MDIR" 2>&1 | tr -d '\r' | tail -1); say "manifest: $m"
case "$m" in "MANIFEST sha="*) ok "a T-signed manifest for $V_NOW / $BOARD (P)";; *) inv "signrel did not produce a manifest: [$m]"; wsl_ rm -rf "$MDIR"; pr_end; pr_result; exit 2;; esac
v=$(wsl_ "$PYW" "$REPO_WSL/tests/tools/peer/signrel.py" --verify "$MDIR/manifest.cbor" --board "$BOARD" 2>&1 | tr -d '\r' | tail -1); say "verify: $v"
case "$v" in "VERIFY ok"*) ok "the manifest verifies under T on the host (P: what the node refuses is the root, not the object)";; *) inv "the test manifest does not verify under T: [$v]";; esac
HEX=$(wsl_ cat "$MDIR/manifest.hex" | tr -d '\r\n'); wsl_ rm -rf "$MDIR" >/dev/null
s=$(pr_pc h0.pem -- status-get "$H0" full | grep '^RESULT status.get'); say "trust: $(cut -c1-240 <<< "$s")"
TR=$(f "$s" trust); d=$(pr_trust_want "$s"); WANT=""
case "$d" in want\ *) WANT=${d#want } ;; inv\ *) inv "UD-T1: ${d#inv }" ;; *) no "UD-T1: ${d#fail }" ;; esac
if [ -n "$TR" ]; then
	k=$(qr "$RK_Q" | grep '^RK ' | tail -1); say "rom key files: $k"
	k=$(rk_judge "$NODE" "$k" "$(tr -d '\r\n' < "$REPO/tests/keys/T.pub" 2>/dev/null)" "$TR") && ok "UD-T1: /rom key files agree with status trust=$TR (${k#PASS release-key-254: })" || no "UD-T1: ${k#FAIL release-key-254: }"
fi
t0=$(pr_slot_ticks)
r=$(pr_pc h0.pem -- update-check "$H0" "$HEX" | grep '^RESULT update.check'); say "UD-T1: $(cut -c1-200 <<< "$r")"
if [ -n "$WANT" ]; then
	if [ "$(code "$r")" = 0 ]; then
		[ "$(f "$r" ok)" = false ] && [ "$(f "$r" reason)" = "$WANT" ] && ok "UD-T1: a T-signed manifest -> ok=false reason=$WANT on an image trusting $TR" || no "UD-T1: update.check answered ok=$(f "$r" ok) reason=$(f "$r" reason) (want false / $WANT, trust $TR)"
	else no "UD-T1: update.check code $(code "$r") (want 0 with ok=false reason=$WANT): [$r]"; fi
fi
if why=$(pr_precheck_ran "$r"); then pr_slot_free "update.check (precheck-node$([ "$(f "$r" ok)" = true ] && echo ' + bootinfo'))" "$t0"
else nj "UD-L: $why — no lock-holding verb ran in this step (the read-only verbs' release is judged every run by prov-fw-boot-254 FB6)"; fi
r=$(pr_pc h0.pem -- update-status "$H0" | grep '^RESULT update.status'); say "status: $r"
[ "$(code "$r")" = 0 ] && [ "$(f "$r" phase)" = 0 ] && ok "update.status idle: phase 0" || no "update.status on an idle node: code $(code "$r") phase $(f "$r" phase) (want 0 / 0): [$r]"
pr_end
pr_result
}

# UD_LIB_ONLY=1 (scripts/dv/test-prov-update-254.sh): every function defined, nothing run
[ "${UD_LIB_ONLY:-0}" = 1 ] && return 0
case "${1:-t1}" in
	t1) arm_t1 ;;
	refuse) arm_refuse ;;
	write) arm_write ;;
	kill) arm_kill ;;
	trial) arm_trial ;;
	*) echo "usage: $0 [t1|refuse|write|kill|trial]"; exit 2 ;;
esac
