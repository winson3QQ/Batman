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
UD_LASTCHK=0; UDLOG=""; UDR=""
# Verdicts and subshells (device run 2026-11-23 12:05, review of 0a6cb73): a judgement made inside $(…) — ud_pc's caps
# INVALID, pr_pc's refusal FAIL — incremented a counter of the subshell and printed into the captured output, so both
# were lost. Every verdict is tallied in a file (one letter per verdict) and printed to stderr when it is made in a
# subshell (it reaches the log, not the caller's variable); the counters are re-read from the file.
UDV=$(mktemp) || { echo "FAIL prov-update-254: mktemp"; exit 2; }
_ud_v(){ local t=$1; shift; if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; echo "$t" >> "$UDV"; ud_sync; }
ud_sync(){ fails=$(grep -c '^F$' "$UDV"); invalid=$(grep -c '^I$' "$UDV"); notjudged=$(grep -c '^N$' "$UDV"); return 0; }
# A tool / ssh failure inside a row's own call (review v12 B MAJOR-1; device run ud36d "INVALID … no caps line" then
# "FAIL UD4: check []"): ud_pc records it in $UDTOOLF (a file: it runs inside $(…)). The next row verdict made in the
# main shell after it is INVALID, not FAIL — the row could not be judged. Each main-shell verdict marks the file as
# seen, so a later row is judged normally.
UDTOOLF=$(mktemp) || { echo "FAIL prov-update-254: mktemp"; exit 2; }
ud_tool_n(){ wc -l < "$UDTOOLF" | tr -d ' '; }
ud_tool_note(){ printf '%s\n' "$*" >> "$UDTOOLF"; }
ud_seen(){ UD_TOOL_SEEN=$(ud_tool_n); }
no(){ local n; n=$(ud_tool_n)
	if [ "$n" -gt "${UD_TOOL_SEEN:-0}" ]; then UD_TOOL_SEEN=$n; _ud_v I "INVALID $PR_UNIT: $* — not judged: a provclient / ssh failure in this row's own call ($(tail -1 "$UDTOOLF"))"
	else _ud_v F "FAIL $PR_UNIT: $*"; fi; }
inv(){ [ "${BASH_SUBSHELL:-0}" -gt 0 ] || ud_seen; _ud_v I "INVALID $PR_UNIT: $*"; }
nj(){ [ "${BASH_SUBSHELL:-0}" -gt 0 ] || ud_seen; _ud_v N "NOT-JUDGED $PR_UNIT: $*"; }
ok(){ [ "${BASH_SUBSHELL:-0}" -gt 0 ] || ud_seen; echo "PASS $PR_UNIT: $*"; }
# ud_tool_inv <why>: a tool INVALID (printed and counted once, recorded for the row); UD_PC_QUIET=1 (ud_poll's reads):
# recorded only — a poll that later gets its answer was not hurt by one failed read
ud_tool_inv(){ ud_tool_note "$*"; [ "${UD_PC_QUIET:-0}" = 1 ] || _ud_v I "INVALID $PR_UNIT: $*"; }   # not inv: the row has not been judged yet
# pr_needs_person counts a FAIL with fails=$((…)), which ud_sync overwrote from the tally file (device run 2026-11-23
# ud36c trial: NEEDS-PERSON and "RESULT fails=2" without it). Its FAIL goes into the file as well.
eval "$(declare -f pr_needs_person | sed '1s/^pr_needs_person/pr_needs_person_base/')"
pr_needs_person(){ pr_needs_person_base "$@"; echo F >> "$UDV"; ud_sync; return 1; }
# ud_person_stop <rows>: after a NEEDS-PERSON no further row is sent: the rows are NOT-RUN and the arm goes to its end
# (the restore). rc 0 = stopped (the caller returns). Device run 2026-11-23 ud36c: UD4, UD5 (ii) and UD1 ran on a node
# with no provclient after UD2's NEEDS-PERSON.
ud_person_stop(){ [ "${PR_PERSON:-0}" = 1 ] || return 1
	nj "$1: NOT-RUN — a NEEDS-PERSON earlier in the arm; straight to the restore"; "${2:-ud_end}" ${PR_WROTE_B:+wrote-b}; return 0; }
pr_result(){ ud_sync; say "RESULT fails=$fails invalid=$invalid notjudged=$notjudged"
	if [ "$fails" = 0 ] && [ "$invalid" = 0 ]; then echo "UNIT $PR_UNIT PASS"; return 0; fi
	[ "$fails" = 0 ] && { echo "UNIT $PR_UNIT INVALID"; return 2; }; echo "UNIT $PR_UNIT FAIL"; return 1; }

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
	case "$sf" in PASS) ;; JUDGED) echo "INFO UD9 kill: the slot flock check after the orphan did not pass (its own line above)"; r=1 ;; *) echo "FAIL UD9 kill: the slot flock after the orphan: $sf"; r=1 ;; esac
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
# the mark carries 8 random bytes made on the host (review v12 B m1: not guessable before it is written)
ud_mark(){ UDM="ud-$RUN-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; q "logger -t batman-dv-ud mark $UDM"; }
ud_log(){ qr "logread | sed -n '/batman-dv-ud: mark $UDM\$/,\$p' | grep -E 'batman-provhelper\\[|batman-slot|batman-config-save' | cut -c1-400"; }
ud_bootinfo(){ local o i; for i in 1 2 3; do o=$(qr "batman-slot bootinfo B 2>&1; echo rc=\$?"); case "$o" in *rc=14) sleep 10 ;; *) break ;; esac; done; printf '%s\n' "$o"; }
ud_pc(){	# pr_pc + the caps rule; PCBIN=old exempt. INVALID (rc 2) on a missing caps line, with the tool's sha
	local o pb=new a; for a in "$@"; do [ "$a" = PCBIN=old ] && pb=old; [ "$a" = -- ] && break; done
	ud_pc_replace
	o=$(pr_pc "$@"); printf '%s\n' "$o"
	grep -qE "$PCD/provclient(\.old)?: (not found|No such file)" <<< "$o" && { ud_tool_inv "provclient missing on the node ($(grep -m1 -E 'not found|No such file' <<< "$o" | cut -c1-120)) — not placed since the node's last boot"; return 2; }
	[ -n "$o" ] || { ud_tool_inv "provclient printed no output at all (not placed on the node since its last boot, or no ssh answer)"; return 2; }
	ud_caps "$o" "$pb" || { ud_tool_inv "provclient printed no caps line (sha $(sha256sum < "$TOOLS/provclient-arm64" | cut -c1-16)): a stale tool — rebuild (scripts/dv-provclient-tools.sh)"; return 2; }
	return 0; }
# provclient lives in the node's tmpfs: a boot removes it (device run 2026-11-23 ud36d: UD4 / UD1 ran after a back_to_a
# with no tool). pr_pc_place records the boot it placed for (a file: ud_pc runs inside $(…) too); ud_pc re-places once
# the boot differs, and pr_pc_place is a no-op for a boot already placed. pr_keys_drop removes the tool: record cleared.
UDPLF=$(mktemp) || { echo "FAIL prov-update-254: mktemp"; exit 2; }
eval "$(declare -f pr_pc_place | sed '1s/^pr_pc_place/pr_pc_place_base/')"
pr_pc_place(){ local b; b=$(boot8)
	[ -n "$b" ] && [ "$b" = "$(cat "$UDPLF" 2>/dev/null)" ] && return 0
	pr_pc_place_base || return 1; printf '%s\n' "$b" > "$UDPLF"; return 0; }
eval "$(declare -f pr_keys_drop | sed '1s/^pr_keys_drop/pr_keys_drop_base/')"
pr_keys_drop(){ : > "$UDPLF"; pr_keys_drop_base "$@"; }
ud_pc_replace(){ local p b; p=$(cat "$UDPLF" 2>/dev/null); [ -n "$p" ] || return 0
	b=$(boot8); [ -n "$b" ] && [ "$b" != "$p" ] || return 0
	say "provclient re-placed: the node booted since it was placed ($p -> $b)" >&2; pr_pc_place >&2; }
ud_status(){ ud_pc h0.pem -- update-status "$H0" | grep '^RESULT update.status'; }
# ud_poll <secs> <phase> [reason] [sha16]: status every 5 s until it says that; prints the last line
# ud_poll: a failed read is recorded, not printed (UD_PC_QUIET); a poll in which NO read answered records that too, so
# the row's "phase not reached" becomes INVALID (review v12 B MAJOR-1)
ud_poll(){ local t0 l n=0 a=0; t0=$(mono)
	while :; do l=$(UD_PC_QUIET=1 ud_status); n=$((n + 1)); [ -n "$l" ] && a=$((a + 1))
		ud_phase "$l" "$2" "${3:-any}" "${4:-any}" && { echo "$l"; return 0; }
		[ $(( $(mono) - t0 )) -ge "$1" ] && { [ $a = 0 ] && ud_tool_note "update.status: no answer in any of $n reads within $1 s"; echo "$l"; return 1; }
		sleep 5; done; }
# ud_check <manifest hex> [PCBIN=old]: update-check, >= 11 s after the last one; ERate -> one retry; code 7 with a slot /
# config-save busy why -> one retry after 20 s. Sets UDR (the RESULT line), UDLOG (the helper's lines since the mark) and
# UD_LASTCHK. Call it directly, NEVER as $(ud_check …): a subshell's globals never reach the caller (the 0a6cb73 crash,
# "UDLOG: unbound variable").
ud_check(){ local hx=$1 pb=${2:-} r w i
	for i in 1 2; do
		w=$(( UD_LASTCHK + 11 - $(mono) )); [ $w -gt 0 ] && sleep $w
		ud_mark; r=$(ud_pc h0.pem $pb -- update-check "$H0" "$hx" | grep '^RESULT update.check'); UD_LASTCHK=$(mono); UDLOG=$(ud_log)
		case "$(code "$r")" in
			17) [ $i = 1 ] && { say "update.check ERate — one retry"; continue; } ;;
			7) if [ $i = 1 ] && grep -qE 'batman-slot busy|config-save' <<< "$UDLOG"; then say "update.check busy (slot / config-save lock) — one retry after 20 s"; sleep 20; continue; fi ;;
		esac; break
	done; UDR=$r; return 0; }
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
# hostdir <dir>: make ONE directory level (the parent must exist). Git Bash `mkdir -p` on a //wsl.localhost path fails
# even when the directory exists: it tries to create //wsl.localhost itself ("Read-only file system").
hostdir(){ [ -d "$1" ] || mkdir "$1"; }
# ud_window <sha>: bulk-open; prints the line (ssid / ip / port / expires only)
ud_window(){ ud_pc h0.pem -- bulk-open "$H0" "$1" | grep '^RESULT bulk.open'; }
ud_close(){ ud_pc h0.pem -- bulk-close "$H0" | grep '^RESULT bulk.close'; }
# ud_open <sha> <row>: the window an upload needs (the helper's tick deletes every file in the bulk dir while no window is
# open, updwork.go UpdateTick); rc 1 + INVALID with the answer and the helper's lines when bulk.open did not answer 0
ud_open(){ local r; ud_g; ud_mark; r=$(ud_window "$1"); say "$2: bulk-open: ${r:-no answer}"
	[ "$(code "$r")" = 0 ] && return 0
	ud_c3 "$r" "$2: bulk-open"
	inv "$2: bulk-open [${r:-no answer}] — no window, nothing uploaded ($(ud_log | grep 'batman-provhelper\[' | tail -2 | cut -c1-200 | tr '\n' '|'))"; return 1; }
# ud_upload <host file>: as 471 (provclient exec); root only lstats it; size + sha read as 471 under a host timeout
ud_upload(){ local fl=$1 o sz sh p
	o=$(timeout 300 ssh $SSHO root@$NODE "$PCD/provclient node exec /bin/sh -c 'id -u; umask 077; cat > $BULK; echo cat-rc=\$?'" < "$fl" 2>&1 | tr -d '\r')
	[ "$(head -1 <<< "$o")" = 471 ] || { inv "upload: the writer is not uid 471 ([$(head -1 <<< "$o")])"; return 1; }
	grep -qx 'cat-rc=0' <<< "$o" || { inv "upload: the 471 writer failed: [$(tail -n +2 <<< "$o" | tr '\n' '|' | cut -c1-200)]"; return 1; }
	# an empty answer is the file being absent (0a6cb73 crashed here on `set -- ''` under set -u): INVALID with the evidence
	o=$(qr "ls -ln $BULK 2>&1; ls -lnd ${BULK%/*} 2>&1")
	p=$(head -1 <<< "$o")
	case "$p" in
		-*) [ "$(awk '{print $3}' <<< "$p")" = 471 ] || { inv "upload: ls -ln [$p] (want a regular file of 471)"; return 1; } ;;
		*) inv "upload: $BULK is absent right after a 471 write that ended rc 0 [$(tr '\n' '|' <<< "$o")]; status [$(ud_status)] (no open window -> the helper's tick deletes it)"; return 1 ;;
	esac
	o=$(timeout 90 ssh $SSHO root@$NODE "$PCD/provclient node exec /bin/sh -c 'echo \$\$; wc -c < $BULK; sha256sum < $BULK'" 2>/dev/null | tr -d '\r'); r=$?
	if [ $r = 124 ]; then p=$(head -1 <<< "$o"); case "$p" in ''|*[!0-9]*) ;; *) q "kill $p" ;; esac; inv "upload: the 471 reader hit the host timeout"; return 1; fi
	sz=$(sed -n 2p <<< "$o" | tr -d ' '); sh=$(sed -n 3p <<< "$o" | cut -c1-64)
	[ "$sz" = "$(wc -c < "$fl" | tr -d ' ')" ] && [ "$sh" = "$(sha256sum < "$fl" | cut -c1-64)" ] || { inv "upload: size / sha as 471 [$sz $sh] differ from the host file"; return 1; }
	say "uploaded $(basename "$fl") as 471: $sz B"; return 0; }
# ud_prepare <sum> [ENV=...]: the guarded prepare in this boot
ud_prepare(){ local s=$1 r; shift; r=$(ud_pc h0.pem GUARD=prepare:"$(boot8)" "$@" -- update-prepare "$H0" "$s" | grep -E '^(RESULT update.prepare|WRONG-STATE)'); ud_c3 "$r" "update.prepare"; printf '%s\n' "$r"; }
ud_apply(){ local r; r=$(ud_pc h0.pem GUARD=apply:"$(boot8)" -- update-apply "$H0" "$1" | grep -E '^(RESULT update.apply|WRONG-STATE)'); ud_c3 "$r" "update.apply"; printf '%s\n' "$r"; }
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


# ==== v8-v11 (254-v16-ud §4.4): temporary ownership by H0, the trial arm's member join, the leak checks, 02 =========
UD_S0_DIR=${UD_S0_DIR:-//wsl.localhost/Ubuntu-24.04/home/yello/.batman-dv/ud-s0}
UDLS=/tmp/run/batman-dv/$RUN   # the node's root-only scratch of this run (ud9-watch uses it too)
# our own log tags (§4.4 "mesh id, our tags only"): the unit's logger tags and the tools this PR drives
UD_TAGRE='batman-dv|batman-provhelper|batman-provd|halow-setkey|batman-config-save|ud9-watch|slot-guard|dv-'
UDWANT=claimed
# ud_scan_state <UDSCAN line>: the state= field; ud_s0_ok: the start states accepted (unclaimed -> INVALID)
ud_scan_f(){ sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<< " $1" | head -1; }
ud_s0_ok(){ case "$(ud_scan_f "$1" state)" in member|claimed|legacy) return 0 ;; esac; return 1; }
# ud_guard_judge <UDSCAN line> <info line "state=… owners=…"> <want state>: "ok" | "inv H0 not an owner: …" (§4.4 item 6)
ud_guard_judge(){
	if [ "$(ud_scan_f "$1" state)" = "$3" ] && [ "$(ud_scan_f "$2" state)" = "$3" ] && [ "$(ud_scan_f "$2" owners)" = 1 ] \
		&& [ "$(ud_scan_f "$1" H0-IN-RECORD)" = yes ]; then echo ok
	else echo "inv H0 not an owner (want state=$3 owners=1 H0-IN-RECORD=yes; scan [$1] info [$2])"; fi; }
# ud_g: the owner-op guard (before an owner-op, after every reboot). A failed guard ends the arm: its owner-op rows are
# INVALID "H0 not an owner", never FAIL; the restore still runs (ud_end). Main shell only (it may exit).
ud_g(){ local s i v
	ud_person_stop "the arm's remaining rows" && exit 2
	s=$(ud_owner_scan); i=$(pr_info)
	v=$(ud_guard_judge "$s" "$i" "$UDWANT")
	[ "$v" = ok ] && return 0
	inv "${v#inv }: the arm's owner-op rows are not run"; ud_end ${PR_WROTE_B:+wrote-b}; exit 2; }
# ud_c3 <RESULT line> <what>: a code 3 while the guard holds is a FAIL (the owner-op was signed by an owner)
ud_c3(){ [ "$(code "$1")" = 3 ] && ! grep -q ' signed-for=' <<< "$1" && no "$2: code 3 (owner-op signature / nonce) while H0 owns the record [$1]"; return 0; }
# ud_claim_h0: right after make_legacy (no step in between, §7 note): the H0 claim, publickey proven first
ud_claim_h0(){ local r
	pr_keys || return 1
	pk_proof || { inv "publickey not proven — 04 not claimed by H0"; return 1; }
	r=$(pr_pc h0.pem -- claim "$H0" "$ENC" | grep '^RESULT claim.verify'); say "H0 claim: $(cut -c1-80 <<< "$r")"
	[ "$(code "$r")" = 0 ] || { inv "H0 claim: [$(cut -c1-80 <<< "$r")]"; return 1; }
	ok "04 claimed by H0 for this arm (Owners=[H0], radio kept)"; return 0; }

# ---- leak checks (§4.4): patterns from a pipe on the node; an empty value is never used as a pattern
# ud_leak_cmd <mode> <arg>: the node-side command. mode mark (arg = the mark: the ring from it), boot (arg = boot8: the
# whole ring, which must start at this boot), file (arg = an uploaded file in the scratch). It prints
#   LEAK-NOWINDOW <why> | KEY=EMPTY | KEY=<count> rc=<rc> | MESH=EMPTY | MESH=<count> rc=<rc> [MESHSYS=<count> rc=<rc>]
ud_leak_cmd(){ local w
	case "$1" in
		mark) w="logread > \$d/leak.r 2>/dev/null; c=\$(grep -c 'batman-dv-ud: mark $2\$' \$d/leak.r); [ \"\$c\" = 1 ] || { [ \"\$c\" = 0 ] && echo 'LEAK-NOWINDOW mark' || echo \"LEAK-NOWINDOW mark not unique (\$c)\"; rm -f \$d/leak.*; exit 0; }; sed -n '/batman-dv-ud: mark $2\$/,\$p' \$d/leak.r > \$d/leak.w" ;;
		boot) w="[ \"\$(cut -c1-8 /proc/sys/kernel/random/boot_id)\" = '$2' ] || { echo 'LEAK-NOWINDOW boot'; exit 0; }; logread > \$d/leak.w 2>/dev/null; head -1 \$d/leak.w | grep -q 'kernel: \[ *0\.' || { echo 'LEAK-NOWINDOW ring start'; rm -f \$d/leak.*; exit 0; }" ;;
		file) w="cp \$d/$2 \$d/leak.w 2>/dev/null || { echo 'LEAK-NOWINDOW file'; exit 0; }; rm -f \$d/$2" ;;
	esac
	printf '%s' "d=$UDLS; mkdir -p -m 700 \$d 2>/dev/null; $w
k=\$(uci -q get wireless.default_radio1.key); if [ -z \"\$k\" ]; then echo KEY=EMPTY; else c=\$(printf '%s\n' \"\$k\" | grep -cFf - \$d/leak.w); echo \"KEY=\$c rc=\$?\"; fi
m=\$(uci -q get wireless.default_radio1.mesh_id); if [ -z \"\$m\" ]; then echo MESH=EMPTY; else
$( [ "$1" = file ] && echo "cp \$d/leak.w \$d/leak.o" || echo "grep -E '$UD_TAGRE' \$d/leak.w > \$d/leak.o; grep -vE '$UD_TAGRE' \$d/leak.w > \$d/leak.s" )
c=\$(printf '%s\n' \"\$m\" | grep -cFf - \$d/leak.o); echo \"MESH=\$c rc=\$?\"
[ -f \$d/leak.s ] && { c=\$(printf '%s\n' \"\$m\" | grep -cFf - \$d/leak.s); echo \"MESHSYS=\$c rc=\$?\"; }; fi
rm -f \$d/leak.*"; }
# ud_leak_judge <label> <output of ud_leak_cmd>: PASS / FAIL / INVALID / INFO lines (§4.4 "result handling")
ud_leak_judge(){ local l=$1 o=$2 k m s c rc
	grep -q '^LEAK-NOWINDOW' <<< "$o" && { echo "INVALID leak check ($l): logread window lost ($(grep -m1 '^LEAK-NOWINDOW' <<< "$o"))"; return; }
	grep -qx 'KEY=EMPTY' <<< "$o" && { echo "INVALID leak check ($l): pattern unreadable (empty mesh key) — no grep was run"; return; }
	grep -qx 'MESH=EMPTY' <<< "$o" && { echo "INVALID leak check ($l): pattern unreadable (empty mesh id) — no grep was run"; return; }
	for k in KEY MESH; do
		s=$(grep -m1 "^$k=" <<< "$o"); c=$(sed -n "s/^$k=\([^ ]*\) rc=.*/\1/p" <<< "$s"); rc=$(sed -n 's/.* rc=\([^ ]*\)$/\1/p' <<< "$s")
		case "$c" in ''|*[!0-9]*) echo "INVALID leak check ($l): did not run ($k [$s])"; return ;; esac
		case "$rc" in 0|1) ;; *) echo "INVALID leak check ($l): did not run ($k grep rc [$rc])"; return ;; esac
	done
	k=$(sed -n 's/^KEY=\([0-9]*\) .*/\1/p' <<< "$o"); m=$(sed -n 's/^MESH=\([0-9]*\) .*/\1/p' <<< "$o")
	s=$(grep -m1 '^MESHSYS=' <<< "$o"); c=$(sed -n 's/^MESHSYS=\([^ ]*\) rc=.*/\1/p' <<< "$s"); rc=$(sed -n 's/.* rc=\([^ ]*\)$/\1/p' <<< "$s")
	if [ -n "$s" ]; then case "$c$rc" in *[!0-9]*|'') echo "INVALID leak check ($l): did not run (MESHSYS [$s])"; return ;; esac; case "$rc" in 0|1) ;; *) echo "INVALID leak check ($l): did not run (MESHSYS rc [$rc])"; return ;; esac; fi
	[ "$k" = 0 ] || echo "FAIL leak check ($l): the mesh key appears $k time(s)"
	[ "$m" = 0 ] || echo "FAIL leak check ($l): the mesh id appears $m time(s) in our own lines"
	[ -n "$c" ] && [ "$c" != 0 ] && echo "INFO leak check ($l): the mesh id in $c system-daemon line(s) (pre-existing, also on air)"
	[ "$k$m" = 00 ] && echo "PASS leak check ($l): no mesh key, no mesh id in our lines"; }
ud_leak_ring(){ ud_verdicts "$(ud_leak_judge "$1" "$(qr "$(ud_leak_cmd "$2" "$3")")")"; }
ud_leak_file(){	# <label> <host file>: the file goes to the node's root-only scratch, is grepped there and removed
	local n=leakf.$(date +%s%N)
	q "mkdir -p -m 700 $UDLS" >/dev/null; scp -q $SSHO "$2" "root@$NODE:$UDLS/$n" || { inv "leak check ($1): the file was not copied"; return; }
	ud_verdicts "$(ud_leak_judge "$1" "$(qr "$(ud_leak_cmd file "$n")")")"; }
# ud_leak_final: the unit log, pr_end / pr_abort output included (it is tee'd), grepped after the end (once)
ud_leak_final(){ [ -n "${UDLOGF:-}" ] && [ "${UDLEAKDONE:-0}" = 0 ] || return 0; UDLEAKDONE=1; ud_leak_file "the unit log incl. pr_end / pr_abort" "$UDLOGF"; rm -f "$UDLOGF"; }

# ud_late_ring <label>: the trial boot's ring once more at its last controllable point (review v11 A m2 / B m2): its
# ring is lost at the revert / back_to_a. Design v12 (device run 2026-11-23 ud36d): over the landing mark .. now, not
# the whole boot — a held trial's ring wraps within ~10 min, so "the ring starts at this boot" can never hold late. The
# mark is written at landing BEFORE the landing grep (boot start .. landing), so the two windows overlap. The mark is a
# RAM-ring line: it is gone once the boot ends and after a wrap past it — both INVALID "logread window lost".
ud_late_ring(){ ud_roll_step "$1"; }
# ud_roll_step <label> [quiet]: v13 rolling marks (review v12 A m1 / B m2): write a new mark FIRST, then grep from the
# previous mark (landing, or the last step's) to now — the window holds its start mark exactly once and the new mark,
# so consecutive windows overlap. The chain covers landing .. the last step even when the ring wraps several times; a
# step whose start mark is gone (wrapped past it, or a new boot) -> INVALID. quiet: a PASS is said, not a verdict line.
ud_roll_step(){ local prev=${UD_ROLL_MARK:-${UD_LAND_MARK:-}} o
	ud_mark; UD_ROLL_MARK=$UDM; UD_ROLL_T=$(mono)
	o=$(ud_leak_judge "$1" "$(qr "$(ud_leak_cmd mark "$prev")")")
	if [ "${2:-}" = quiet ] && [ "$(grep -c . <<< "$o")" = 1 ] && grep -q '^PASS' <<< "$o"; then say "$o"; else ud_verdicts "$o"; fi; }
# ud_roll_tick: a quiet step every UD_ROLL_S (60) s — the 04 ring (128 KiB) grows ~77 B / 120 s at idle (§25)
ud_roll_tick(){ [ $(( $(mono) - ${UD_ROLL_T:-0} )) -ge "${UD_ROLL_S:-60}" ] || return 0; ud_roll_step "${1:-UD2: the held trial, rolling step}" quiet; }
# ud2_late: UD2 is held until its deadline: wait for the last HELD sample before it (deadline - 60 s), then grep
ud2_late(){ local dl u b
	dl=$(qr '. /usr/lib/batman/rundir.sh; cat $RUNDIR/autocommit.deadline 2>/dev/null')
	case "$dl" in ''|*[!0-9]*) inv "UD2: no autocommit deadline: the late leak grep cannot be placed (window lost)"; return ;; esac
	while :; do
		b=$(boot8); u=$(qr 'cut -d. -f1 /proc/uptime')
		[ "$b" = "$PR_LAND_BOOT" ] || { inv "leak check (UD2: the B trial boot before its revert): logread window lost (boot $b)"; return; }
		case "$u" in ''|*[!0-9]*) sleep 10; continue ;; esac
		[ "$u" -ge $((dl - 60)) ] && break
		ud_roll_tick "UD2: the held trial, rolling step"
		sleep 15
	done
	ud_late_ring "UD2: the B trial boot, last HELD sample before the deadline"; }

# ---- the member join (trial arm only, §4.4 items 4, 5, 7)
UD_FD3='m=$(uci -q get wireless.default_radio1.mesh_id); k=$(uci -q get wireless.default_radio1.key); c=$(uci -q get wireless.radio1.channel); n=$(uci -q get wireless.radio1.country); printf "mesh_id=%s\nchannel=%s\nbw=2\nsae=%s\ncountry=%s\n" "$m" "$c" "$k" "$n"'
ud_join(){ local r
	ud_mark; UDJOINMARK=$UDM
	r=$(pr_pc h0.pem FD3="$UD_FD3" PROVCLIENT_NET_QUIET=1 -- net-apply --first "$H0")
	grep -q '^NETCFG' <<< "$r" && no "member join: provclient printed NETCFG (PROVCLIENT_NET_QUIET not honoured)"
	r=$(grep '^RESULT net.apply' <<< "$r"); say "member join: $r"
	[ "$(code "$r")" = 0 ] && grep -q ' mesh_id=withheld' <<< "$r" || { UDJOINWHY="net.apply [$r]"; return 1; }
	return 0; }
# ud_prerow: before any trial row (no post-join reboot): .txn absent; --check rc 0 (rc 8 retried 3 x 5 s); p6 prov-state
# field 6 = radio; 02 a neighbour within 180 s. Prints "ok" | "invalid <why>" | "person <why>"
ud_prerow(){ local o rc i t0 why=""
	o=$(qr '[ -e /etc/batman-prov/.txn ] && echo TXN || echo NOTXN'); [ "$o" = NOTXN ] || why=".txn present after the join [$o]"
	if [ -z "$why" ]; then
		for i in 1 2 3 4; do rc=$(qr 'batman-config-save --check >/dev/null 2>&1; echo $?'); [ "$rc" = 8 ] && [ $i -lt 4 ] && { sleep 5; continue; }; break; done
		[ "$rc" = 0 ] || why="batman-config-save --check rc [$rc]"
	fi
	if [ -z "$why" ]; then o=$(qr "cut -d' ' -f6 /opt/batdata/state/prov-state"); [ "$o" = radio ] || why="prov-state field 6 [$o], not radio"; fi
	t0=$(mono); until nbmac "$PEERMAC"; do [ $(( $(mono) - t0 )) -ge 180 ] && { echo "person 02 ($PEERMAC) not a neighbour of 04 within 180 s${why:+ ($why)}"; return; }; sleep 10; done
	[ -z "$why" ] && echo ok || echo "invalid mesh not rejoined: $why"; }

# ---- 02 during the trial arm (§4.4, read-only under the 02 contract; review v11 A m1)
UD_02FMT='commit: |--prov-only rc=|overlay write after a committed p5 write failed|claim committed, lock / save incomplete|network\.leave: |: save rc=|finish \(|CRIT finish|resolve: overlay rebuil|: the overlay was stale \(generation |update\.prepare: |update\.apply: |update worker: |ssh_keys\.set: --save rc=|CRIT settings\.set|prov-state mesh_expect: |--save: p5 busy|--save after the failed lock step|best-effort --save after the restore|last_known_state not updated'
# ud_02_match <lines>: the batman-provhelper lines of 02 that name a state-changing path (secondary signal: a successful
# record commit logs nothing; the primary proof is ud_02_state equal at the start and the end)
ud_02_match(){ grep 'batman-provhelper\[[0-9]*\]: ' <<< "$1" | sed 's/^.*batman-provhelper\[[0-9]*\]: //' | grep -E "^($UD_02FMT)|($UD_02FMT)"; }
ud_02_state(){ qp "echo \"META \$(head -1 /etc/batman-prov/prov.meta 2>/dev/null)\"; [ -e /etc/batman-prov/.txn ] && echo TXN=yes || echo TXN=no; echo \"PS \$(cut -d' ' -f2-6 /opt/batdata/state/prov-state 2>/dev/null)\""; }
# ud_02_judge <start state> <end state> <02 log since the mark, or LOST>: PASS / FAIL / INVALID lines
ud_02_judge(){ local x
	[ -n "$1" ] && [ "$1" = "$2" ] && grep -qx 'TXN=no' <<< "$2" && grep -q '^META .*gen=' <<< "$2" \
		&& echo "PASS 02's record unchanged over the arm (prov.meta, no .txn, prov-state fields 2-6)" || echo "FAIL 02's record changed over the arm: start [$(tr '\n' '|' <<< "$1")] end [$(tr '\n' '|' <<< "$2")]"
	[ "$3" = LOST ] && { echo "INVALID 02's log since the arm's mark: window lost"; return; }
	x=$(ud_02_match "$3")
	[ -z "$x" ] && echo "PASS 02's helper logged no state-changing line" || echo "FAIL 02's helper logged a state-changing line: $(head -3 <<< "$x" | tr '\n' '|')"; }

# pr_abort's output (the EXIT trap) is grepped too: the unit log is tee'd, ud_leak_final runs after the trap's restore
eval "$(declare -f pr_on_exit | sed '1s/^pr_on_exit/pr_on_exit_base/')"
pr_on_exit(){ local rc=$?; (exit $rc); pr_on_exit_base; ud_leak_final; }

# ==== the arms ========================================================================================================
ud_begin(){	# common start: S0 owner evidence, lease + snapshot, make-legacy, the H0 claim, tools, S0 status, AP, V
	UDLOGF=$(mktemp); exec > >(tee -a "$UDLOGF") 2>&1   # the unit log, grepped for the key / id at the end (§4.4)
	pr_h0 || { pr_result; exit 1; }
	UDS0=$(ud_owner_scan); say "S0 owners: $UDS0"
	ud_s0_ok "$UDS0" || { inv "start state [$(ud_scan_f "$UDS0" state)] (member / claimed / legacy accepted): not run"; pr_keys_drop; pr_result; exit 2; }
	hostdir "$UD_S0_DIR" && printf '%s\n' "$UDS0" > "$UD_S0_DIR/$RUN.txt" || { inv "cannot write $UD_S0_DIR/$RUN.txt"; pr_result; exit 2; }
	PR_BASE=legacy   # pr_begin: snapshot first, then pr_make_legacy (§4.4 item 2); the H0 claim follows at once
	pr_begin "$1" || { pr_result; exit 1; }
	pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
	ud_claim_h0 || { ud_end; exit 2; }
	UDWANT=claimed; ud_g
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
ud_end(){ local s
	[ -n "${MDIR:-}" ] && wsl_ rm -rf "$MDIR" >/dev/null
	pr_end "$@"
	# the end state is the start state: the record (§4.4 item 8) — pr_h0's key is gone after pr_end, H0 is still set
	s=$(ud_owner_scan); if [ -n "${UDS0:-}" ]; then
		[ "$s" = "$(cat "$UD_S0_DIR/$RUN.txt" 2>/dev/null)" ] && ok "04's record at the end = S0 ($s)" || no "04's record at the end [$s] != S0 [$(cat "$UD_S0_DIR/$RUN.txt" 2>/dev/null)]"
	fi
	ud_leak_final; pr_result; }
ud_ul(){ UDT0=$(pr_slot_ticks); ud_check "$1"; say "check: $UDR"; }
# ud_verdicts: a judge's PASS / FAIL / INVALID lines counted in THIS shell (never through a pipe into a subshell)
ud_verdicts(){ local x; while IFS= read -r x; do case "$x" in PASS*) ok "${x#PASS }" ;; FAIL*) no "${x#FAIL }" ;; INVALID*) inv "${x#INVALID }" ;; *) say "$x" ;; esac; done <<< "$1"; }
ud_lk(){ local why; if why=$(pr_precheck_ran "$UDR"); then pr_slot_free "$1" "$UDT0"; else nj "UD-L ($1): $why"; fi; }

arm_refuse(){
	ud_begin 7200
	# ---- step 0: the provclient flip (pre-UD binary vs this one, same image / manifest / minute)
	if q "[ -x $PCD/provclient.old ]"; then
		ud_check "$VHEX" PCBIN=old; r=$UDR; say "old: $r"
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
		ud_check "$MHEX"; r=$UDR; say "UD7 $n: $r"
		if [ "$(code "$r")" = 0 ] && [ "$(f "$r" ok)" = false ] && [ "$(f "$r" reason)" = "$rs" ] && ud_why "$UDLOG" "update.check: refused, reason $rs (" && ud_why "$UDLOG" "$w"; then ok "UD7 $n: ok=false reason $rs, why \"$w\""
		else no "UD7 $n: [$r] want ok=false reason $rs and \"$w\" ($(grep 'batman-provhelper\[' <<< "$UDLOG" | tail -1 | cut -c1-200))"; fi
	done
	ud_g; r=$(ud_window "$X"); say "UD7 P: $r"; [ "$(code "$r")" = 0 ] && ok "UD7 P: bulk-open X still succeeds (the refusals did not replace the pending)" || no "UD7 P: bulk-open X [$r]"
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
			ud_check "$VHEX"; r=$UDR; [ "$(f "$r" ok)" = true ] || no "UD20c: owner check X [$r]"
			ud_check "$YHEX"; r=$UDR; say "UD20c: provclient check Y: $r"
			ud_g; r=$(ud_window "$Y"); [ "$(code "$r")" = 0 ] && ok "UD20c P: bulk-open Y succeeds (the pending is now Y)" || no "UD20c P: bulk-open Y [$r]"
			ud_close >/dev/null
			ud_mark; ud_g; r=$(ud_window "$X"); ud_refused "$r" 24 15 "no pending update of this owner for this sha" "UD20c bulk-open X"
			ud_g; ud_mark; r=$(ud_prepare "$X"); ud_refused "$r" 24 15 "no pending update for this sha" "UD20c prepare X"
			r=$(ud_status); case " $r " in *" phase=2 "*) no "UD20c: a worker started [$r]" ;; *) ok "UD20c: no worker ($r)" ;; esac
			ud_check "$VHEX"; r=$UDR; ud_g; r=$(ud_window "$X"); [ "$(code "$r")" = 0 ] || no "UD20c arm 2: bulk-open X [$r]"
			ud_check "$YHEX"; r=$UDR; [ "$(code "$r")" = 7 ] && ud_why "$UDLOG" "an update is being uploaded or written" && ok "UD20c arm 2: update-check Y in a window -> code 7" || no "UD20c arm 2: [$r]"
			r=$(ud_status); ud_phase "$r" 1 any "$X16" && ok "UD20c arm 2: status phase=1 sha=$X16" || no "UD20c arm 2 status [$r]"
			ud_close >/dev/null
			# ---- UD20b: pending X, an owner-op valid over Y
			ud_g; ud_mark; r=$(ud_prepare "$Y"); ud_refused "$r" 24 15 "no pending update for this sha" "UD20b prepare Y"
		else inv "UD20c: sums_sha(Y) = X ($Y): Y would test nothing"; fi
	fi
	# ---- UD8b: a FIFO instead of the upload
	ud_check "$VHEX"; r=$UDR; r=$(ud_window "$X")
	if [ "$(code "$r")" = 0 ]; then
		o=$(q "$PCD/provclient node exec /bin/sh -c 'id -u; mkfifo $BULK'"); p=$(qr "ls -ln $BULK")
		if [ "$(head -1 <<< "$o")" = 471 ] && [ "${p:0:1}" = p ] && [ "$(awk '{print $3}' <<< "$p")" = 471 ]; then ok "UD8b P: the upload is a FIFO of 471 ($p)"
			ud_g; ud_mark; r=$(ud_prepare "$X"); ud_refused "$r" 24 15 "the upload is missing or incomplete" "UD8b prepare"
			ud_close >/dev/null; sleep 8; [ -z "$(qr "ls -ln $BULK 2>/dev/null")" ] && ok "UD8b: the FIFO is gone after bulk-close" || no "UD8b: still there: $(qr "ls -ln $BULK")"
		else inv "UD8b P: [$o] [$p]"; ud_close >/dev/null; fi
	else no "UD8b: bulk-open X [$r]"; fi
	ud_end
}

# ud8_ok <status line> <helper log> <version from the prepare reply> <why>: phase 0 + 11 and the worker's refusal line,
# "update worker: <version> refused, reason 11 (<why>)" (feed/batman-prov/src/node/updwork.go:291 logs r.Version, not
# the verb; device run 2026-11-23 expected "prepare refused" and FAILed UD8 (1)-(4) on a correct refusal)
ud8_ok(){ [ -n "$3" ] && ud_phase "$1" 0 11 && ud_why "$2" "update worker: $3 refused, reason 11 (" && ud_why "$2" "$4"; }
arm_write(){
	ud_begin 10800; PR_WROTE_B=1
	local n w bi0 bi v
	bi0=$(ud_bootinfo)
	for n in 1 2 3 4; do
		pr_lease_renew +1800 || break
		ud_gen "mal$n" "m$n.tar.gz" || continue
		if [ $n = 3 ]; then ud_manifest "$PAYW" "m3" --size-of "$GENF" || continue; else ud_manifest "$GENF" "m$n" || continue; fi
		case $n in 1) w="is not a regular file" ;; 2) w="members after root.squashfs" ;; 3) w="data after the gzip stream" ;; 4) w="too many members" ;; esac
		ud_check "$MHEX"; r=$UDR; [ "$(f "$r" ok)" = true ] || { no "UD8 ($n): check [$r]"; continue; }
		ud_open "$MSUMS" "UD8 ($n)" && ud_upload "$(hostp "$GENF")" || { ud_close >/dev/null; continue; }
		ud_g; ud_mark; r=$(ud_prepare "$MSUMS"); say "UD8 ($n) prepare: $r"; v=$(f "$r" version)
		r=$(ud_poll 300 0 11); log=$(ud_log)
		if ud8_ok "$r" "$log" "$v" "$w"; then ok "UD8 ($n): phase 0 + 11, worker why \"$w\""
		else no "UD8 ($n): [$r] $(grep 'batman-provhelper\[' <<< "$log" | tail -1 | cut -c1-200)"; fi
		bi=$(ud_bootinfo); [ "$bi" = "$bi0" ] && ud_flag0 && ok "UD8 ($n): bootinfo B unchanged, tryboot flag 0" || no "UD8 ($n): B changed or flag set ($(tr '\n' ' ' <<< "$bi"))"
	done
	# ---- UD8c: V uploaded, then replaced (rm first: two copies do not fit) by the same-length mutant
	if ud_gen mutate mut.tar.gz; then
		ud_check "$VHEX"; r=$UDR
		if ud_open "$X" UD8c && ud_upload "$PAYH"; then
			q "$PCD/provclient node exec /bin/rm -f $BULK" >/dev/null
			if ud_upload "$(hostp "$GENF")"; then
				ud_g; ud_mark; r=$(ud_prepare "$X"); r=$(ud_poll 300 0 11); log=$(ud_log)
				ud_phase "$r" 0 11 && ud_why "$log" "root.squashfs does not match SHA256SUMS" && ok "UD8c: phase 0 + 11, 'root.squashfs does not match SHA256SUMS'" || no "UD8c: [$r]"
				bi=$(ud_bootinfo); [ "$bi" = "$bi0" ] && ok "UD8c: B unchanged" || no "UD8c: B changed"
			fi
		fi; ud_close >/dev/null 2>&1
	fi
	# ---- UD6 (b): p5 stale at the worker's precheck (joinwatch stopped: nothing re-saves p5)
	pr_lease_renew +1800
	ud_check "$VHEX"; r=$UDR; [ "$(f "$r" ok)" = true ] || no "UD6 (b): check [$r]"
	if ud_open "$X" "UD6 (b)" && ud_upload "$PAYH" && ud_ssid_on "dv-s${RUN: -8}" "UD6 (b)"; then
		ud_g; ud_mark; r=$(ud_prepare "$X"); r=$(ud_poll 300 0 17); log=$(ud_log)
		ud_phase "$r" 0 17 && ud_why "$log" "batman-slot write rc 12: " && ud_why "$log" "p5 (config) is STALE vs the running config (wireless.default_radio0.ssid)" \
			&& ok "UD6 (b): phase 0 + 17, batman-slot write rc 12 'p5 (config) is STALE …'" || no "UD6 (b): [$r] $(grep 'batman-provhelper\[' <<< "$log" | tail -1 | cut -c1-200)"
		bi=$(ud_bootinfo); [ "$bi" = "$bi0" ] && ok "UD6 (b): B unchanged (precheck before begin_write)" || no "UD6 (b): B changed"
		ud_ssid_off "UD6 (b)"
	fi
	ud_close >/dev/null 2>&1
	# ---- UD20 neg / pos (+ the UD9 observe watcher)
	pr_lease_renew +2400
	ud_check "$VHEX"; r=$UDR
	if ud_open "$X" UD20 && ud_upload "$PAYH"; then
		ud_g; ud_mark; r=$(ud_prepare "$X" PROVCLIENT_SIGN_ARGS_SHA="$(printf 'ud20-neg' | sha256sum | cut -c1-64)"); say "UD20 neg: $r"
		log=$(ud_log); s=$(ud_status)
		if [ "$(code "$r")" = 3 ] && grep -q ' signed-for=' <<< "$r"; then
			ud_why "$log" "owner-op" && ok "UD20 neg: code 3 (signed for another sha), the helper logged the owner-op refusal" || no "UD20 neg: code 3 but no owner-op log line"
		else no "UD20 neg: [$r] want code 3 with signed-for="; fi
		case " $s " in *" phase=2 "*) no "UD20 neg: a worker started" ;; esac
		[ "$(qr "ls -ln $BULK" | cut -c1)" = - ] && ok "UD20 neg: the upload is still there" || no "UD20 neg: the upload is gone"
		ud_watch observe || :
		ud_g; t0=$(pr_slot_ticks); r=$(ud_prepare "$X"); say "UD20 pos: $r"
		[ "$(code "$r")" = 0 ] || no "UD20 pos: prepare [$r]"
		r=$(ud_poll 900 3); if ud_phase "$r" 3 - "$X16"; then ok "UD20 pos: phase 2 -> 3 ($r)"; else no "UD20 pos: [$r]"; fi
		bi=$(ud_bootinfo); b=$(qr 'cat /proc/sys/kernel/random/boot_id')
		grep -q "verified=$X $b" <<< "$bi" && ok "UD20 pos: bootinfo B verified=<X> <this boot>" || no "UD20 pos: bootinfo B [$(tr '\n' ' ' <<< "$bi")]"
		pr_slot_free "the UD20 worker" "$t0"
		ud_watch_obs_end
		# ---- UD10b: a reboot drops the pending; the re-check stays 0 + 23, apply 24 / 15
		b=$(boot8); o=$(q "$(reboot_guarded "$b" A 1 prov-update-254)")
		if [ "$o" = SENT ] && pr_find 900 "$b" && pr_pc_place && ud_g; then
			r=$(ud_poll 120 0 23); ud_phase "$r" 0 23 && ok "UD10b: after the reboot 0 + 23" || no "UD10b: after the reboot [$r]"
			ud_check "$VHEX"; r=$UDR; r=$(ud_status); ud_phase "$r" 0 23 && ok "UD10b: after the re-check still 0 + 23 (verified= carries the old boot)" || no "UD10b: after the re-check [$r]"
			ud_g; ud_mark; r=$(ud_apply "$X"); ud_refused "$r" 24 15 "the target slot is not verified for this sha in this boot" "UD10b apply"
		else no "UD10b: reboot [$o] / node not found"; fi
	fi
	ud_end wrote-b
}
# ---- the UD9 watcher: start + register in ONE ssh call, ud9.go only after the kill-pg line (254-v16-ud §1.5-1)
ud_watch(){ local o
	o=$(q "d=/tmp/run/batman-dv/$RUN; mkdir -m 700 \$d 2>/dev/null; [ -d \$d ] && cd \$d || exit 1; setsid sh $PRD/ud9-watch-254.sh $1 $RUN $SQ /dev/mmcblk0p4 </dev/null >/dev/null 2>&1 & p=\$!; echo \$p > \$d/ud9.pid; RUN_ID=$RUN sh $PRD/prov-lease-254.sh undo-add kill-pg \$p ud9-watch && touch \$d/ud9.go && echo WATCH \$p")
	UDW=$(sed -n 's/^WATCH //p' <<< "$o"); UDWID=$(sed -n 's/^UNDO-ADDED \([0-9]*\) .*/\1/p' <<< "$o")
	[ -n "$UDW" ] && [ -n "$UDWID" ] || { inv "UD9 watcher ($1) not started / not registered: $(echo $o)"; return 1; }
	# the pid in ud9.pid must be the watcher itself, alive, leader of its own group (a setsid that forked leaves a dead
	# $! here, and the journal's kill-pg would miss the real one)
	o=$(qr "[ -d /proc/$UDW ] && echo \"PG \$(sed 's/.*) //' /proc/$UDW/stat | cut -d' ' -f3) \$(tr '\\0' ' ' < /proc/$UDW/cmdline | grep -c ud9-watch)\" || echo GONE")
	[ "$o" = "PG $UDW 1" ] || { inv "UD9 watcher ($1): pid $UDW is not a live group-leading watcher right after the start [$o]"; return 1; }
	say "UD9 watcher $1: pid $UDW, journal line $UDWID"; return 0; }
ud_watch_log(){ qr "tr -s ' ' < /opt/batdata/log/dv-ud9-$RUN.log 2>/dev/null | grep '^UD9-' | sed 's/ *\$//'"; }
ud_watch_gone(){ local i; for i in $(seq 1 "${1:-30}"); do [ -z "$(qr "[ -d /proc/$UDW ] && tr '\\0' ' ' < /proc/$UDW/cmdline | grep -c ud9-watch")" ] && return 0; sleep 2; done; return 1; }
ud_watch_done(){ local o; q "touch /tmp/run/batman-dv/$RUN/ud9.stop"
	ud_watch_gone 30 || { no "the UD9 watcher $UDW did not exit"; return 1; }
	o=$(pl undo-done "$UDWID"); grep -q "^UNDO-DONE $UDWID$" <<< "$o" || no "undo-done of the watcher line: $o"; }
ud_watch_obs_end(){ local l mac g=gone d
	ud_watch_gone 30 || g=alive; l=$(ud_watch_log); say "UD9 observe: $l"
	# no result line: say what is known (device run 2026-11-23 ud36c: an empty line, and a log removed as 4096 spaces)
	[ -n "$l" ] || { d=$(ud9_diag "$g"); say "UD9 observe diagnosis: $d"; }
	ud_watch_done
	mac=$(field "$(qr "$ST")" mac)
	if grep -qE '^UD9-OBS .* result=ok$' <<< "$l"; then
		hostdir "$UD9_OBS_DIR" && { echo "run=$RUN"; echo "version=$V_NOW"; echo "mac=$mac"; echo "date=$(date -u +%FT%TZ)"; echo "$l" | grep '^UD9-OBS'
			echo "log_sha256=$(qr "sha256sum < /opt/batdata/log/dv-ud9-$RUN.log | cut -c1-64")"; } > "$UD9_OBS_DIR/$V_NOW-${mac//:/}.txt" \
			&& ok "UD9 premise (output side): fd 1 = B's root, pos grows — saved for the kill arm" || no "cannot write $UD9_OBS_DIR"
	else inv "UD9 premise (output side) not shown: [$l]${d:+ — $d}"; fi; }
# ud9_diag <gone|alive>: why the observe watcher left no result line: was it still running at the read (no stream dd
# seen), did its log stay the 4096 pre-sized spaces (no line written), and its syslog lines (each line also goes there)
ud9_diag(){ local o
	o=$(qr "f=/opt/batdata/log/dv-ud9-$RUN.log; if [ -f \$f ]; then echo \"LOGSIZE \$(wc -c < \$f) NONSPACE \$(tr -d ' \\n' < \$f | wc -c)\"; else echo NOLOG; fi; logread 2>/dev/null | grep 'ud9-watch' | tail -3 | cut -c1-160 | sed 's/^/SYSLOG /'
dmesg 2>/dev/null | grep -iE 'oom|killed process|out of memory' | tail -5 | cut -c1-160 | sed 's/^/DMESG /'; free 2>/dev/null | sed -n '2p' | tr -s ' ' | sed 's/^/FREE /'")
	ud9_diag_text "$1" "$o"; }
ud9_diag_text(){ local s
	case "$1" in alive) s="the watcher was still running at the read (no stream dd seen within the step)" ;; *) s="the watcher had exited" ;; esac
	if grep -q '^NOLOG' <<< "$2"; then s="$s; its log does not exist (it never started)"
	elif grep -q '^LOGSIZE [0-9]* NONSPACE 0$' <<< "$2"; then s="$s; its log holds no line (pre-sized spaces only)"; fi
	grep -q '^SYSLOG ' <<< "$2" && s="$s; syslog: $(grep '^SYSLOG ' <<< "$2" | sed 's/^SYSLOG //' | tr '\n' '|')" || s="$s; no ud9-watch line in syslog"
	grep -q '^DMESG ' <<< "$2" && s="$s; dmesg (oom / killed): $(grep '^DMESG ' <<< "$2" | sed 's/^DMESG //' | tr '\n' '|')" || s="$s; no oom / killed-process line in dmesg"
	grep -q '^FREE ' <<< "$2" && s="$s; free: $(grep -m1 '^FREE ' <<< "$2" | sed 's/^FREE //')"
	echo "$s"; }

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
	ud_check "$VHEX"; r=$UDR
	if ud_open "$X" "UD9 kill" && ud_upload "$PAYH" && ud_watch kill; then
		ud_g; tk=$(pr_slot_ticks); r=$(ud_prepare "$X"); say "UD9 kill prepare: $r"
		t0=$(mono); while [ $(( $(mono) - t0 )) -lt 900 ]; do l=$(ud_watch_log); grep -qE '^UD9-(FIRE|MISS)' <<< "$l" && break; sleep 2; done
		say "watcher: $l"; orph=$(sed -n 's/.* orphan=\([0-9]*\).*/\1/p' <<< "$l")
		g=0; if [ -n "$orph" ]; then for i in $(seq 1 60); do [ -z "$(qr "[ -d /proc/$orph ] && echo up")" ] && { g=1; break; }; sleep 5; done; fi
		ud_sync; f0=$fails; i0=$invalid; pr_slot_free "the orphan's exit" "$tk"; ud_sync
		sf=PASS; [ "$fails$invalid" = "$f0$i0" ] || sf=JUDGED   # pr_slot_free printed and counted its own verdict
		st=$(ud_poll 180 0 22); bi=$(ud_bootinfo); s=$(qr "$ST"); tr=$(qr 'tail -40 /opt/batdata/log/ota-trace.log')
		ud_verdicts "$(ud_kill_judge "$l" "$SQ" "$g" "$sf" "$st" "$bi" "$s" "$tr")"
		ud_flag0 && ok "UD9 kill: tryboot flag 0" || no "UD9 kill: tryboot flag set"
		ud_watch_done
	fi
	ud_close >/dev/null 2>&1
	# ---- cut sub-arm: the host polls the p6 log; MISS -> INVALID, no pr_find; a lost connection after PRE-B = cut
	pr_lease_renew +2400
	ud_check "$VHEX"; r=$UDR
	if ud_open "$X" "UD9 cut" && ud_upload "$PAYH" && ud_watch cut; then
		ud_g; b=$(boot8); r=$(ud_prepare "$X"); say "UD9 cut prepare: $r"
		ud_cut_wait "$b"; v=$UDCUTV
		case "$v" in
			cut) if [ "$UDCUTF" = 0 ] && pr_pc_place && ud_g; then
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
	local b r o ul hv bs off1 off2 c0 c1 rec v; UD2OK=0
	hv=$V_NOW
	# 02 at the arm's start (read-only), and a mark in its log
	UD02A=$(ud_02_state); UD02M="ud-$RUN-02"; qp "logger -t batman-dv-ud mark $UD02M" >/dev/null; say "02 at the start: $(tr '\n' '|' <<< "$UD02A")"
	# the member join of the bench mesh (§4.4 item 4) and the pre-row checks (item 5); item 7 on any failure
	if ud_join; then v=$(ud_prerow); else v="invalid member join failed: $UDJOINWHY"; fi
	say "member join / pre-row checks: $v"
	case "$v" in
		ok) UDWANT=member; ud_g; ok "04 is a member of the bench mesh (Owners=[H0]), the pre-row checks hold"
			ud_leak_ring "right after the member join" mark "$UDJOINMARK" ;;
		person*) pr_needs_person "member join: ${v#person }"; inv "member rows (UD1, UD2, UD4, UD5, UD10): member join failed"; ud_trial_end; return ;;
		*) inv "member rows (UD1, UD2, UD4, UD5, UD10): ${v#invalid }"; ud_trial_end; return ;;
	esac
	ud_to3(){	# <hex> <sums> <host file> <row>: check -> window -> upload -> prepare -> phase 3
		ud_check "$1"; r=$UDR; [ "$(f "$r" ok)" = true ] || { no "$4: check [$r]"; return 1; }
		ud_open "$2" "$4" && ud_upload "$3" || return 1
		ud_g; r=$(ud_prepare "$2"); r=$(ud_poll 900 3); ud_phase "$r" 3 && { ok "$4: phase 3 ($r)"; return 0; }; no "$4: phase 3 not reached [$r]"; return 1; }
	ud_hold(){	# the hold flag, journalled first (rm-hold)
		o=$(pl undo-add rm-hold); UDHOLD=$(sed -n 's/^UNDO-ADDED \([0-9]*\) .*/\1/p' <<< "$o"); [ -n "$UDHOLD" ] || { inv "undo-add rm-hold: $o"; return 1; }
		q "printf '%s\n' '$hv' > $HOLDF; sync"; [ "$(qr "cat $HOLDF")" = "$hv" ]; }
	ud_land(){	# after a guarded apply: the B trial of V, hold effective
		pr_find 900 "$1" || { pr_needs_person "$2: no node after the apply"; return 1; }
		pr_lease_renew +1800; s=$PR_STATE; PR_LAND_BOOT=$(field "$s" boot)
		[ "$(field "$s" slot)" = B ] && [ "$(field "$s" trial_rc)" = 0 ] && [ "$(field "$s" held)" = 1 ] && [ "$(field "$s" hold)" = "[]" ] \
			|| { no "$2: not a held B trial ($s)"; return 1; }
		pr_trial_guard; o=$(pl undo-done "$UDHOLD"); grep -q "^UNDO-DONE" <<< "$o" || no "$2: undo-done rm-hold: $o"
		pr_pc_place; ud_g; ok "$2: landed in the held B trial"
		ud_mark; UD_LAND_MARK=$UDM; UD_ROLL_MARK=$UDM; UD_ROLL_T=$(mono)   # the rolling chain's start (v12 / v13), before the landing grep: the windows overlap
		ud_leak_ring "$2: the B trial boot, at landing" boot "$PR_LAND_BOOT"; }
	# ---- UD2: same version reverted -> 6
	if ud_to3 "$VHEX" "$X" "$PAYH" UD2 && ud_hold; then
		ud_g; b=$(boot8); r=$(ud_apply "$X"); say "UD2 apply: $r"
		if ud_land "$b" UD2; then
			r=$(ud_status); ud_phase "$r" 4 && pr_wait_held 480 && ok "UD2: phase 4 + HELD in the trial" || no "UD2: in the trial [$r]"
			ud2_late
			# the held trial's revert may be deferred up to DEFER_MAX: the rolling steps go on while its boot lasts (v13)
			if PR_HELD_OK=1 PR_WAIT_HOOK=ud_roll_tick pr_wait_reverted && pr_pc_place && ud_g; then
				# UD2's own verdict does not depend on the leak check of the A boot (review v12 A m3)
				ud_leak_ring "UD2: the A boot after the revert, at landing" boot "$(boot8)"
				r=$(ud_status)
				if ud_phase "$r" 6 - && [ "$(field "$PR_STATE" slot)" = A ] && [ "$(field "$PR_STATE" trial_rc)" = 1 ]; then ok "UD2: reverted, A committed, phase 6"; UD2OK=1
				else no "UD2: after the revert [$r] ($PR_STATE)"; fi
			fi
		fi
	fi
	ud_person_stop "UD4 / UD5 (i), UD5 (ii), UD1, UD10" ud_trial_end && return
	# UD4 / UD5 / UD1 / UD10 start from UD2's end state (A committed, phase 6, bad-slot B): without it they are not run
	# (device run 2026-11-23 ud36d: UD2 FAILed, the node went back to A by back_to_a, and UD4 / UD1 ran anyway)
	[ "${UD2OK:-0}" = 1 ] || { nj "UD4 / UD5 (i), UD5 (ii), UD1, UD10: NOT-RUN — prerequisite UD2 not met (not A committed at phase 6 after its revert)"; ud_trial_end; return; }
	bs=$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null'); say "bad-slot after UD2: [$bs]"
	off1=$(qr "grep -b 'TRIAL-REVERTED' /opt/batdata/log/autocommit.log | tail -1 | cut -d: -f1")
	# ---- UD4 (= UD5 i): a B that does not boot -> 6 + 18; B's boot evidenced by the PANIC record
	if ud_gen badpayload bad.tar.gz && ud_manifest "$GENF" bad --allow-no-key; then
		c0=$(qr 'ls /opt/batdata/crash 2>/dev/null')
		if ud_to3 "$MHEX" "$MSUMS" "$(hostp "$GENF")" UD4; then
			off2=$(qr 'wc -c < /opt/batdata/log/autocommit.log')
			ud_g; b=$(boot8); r=$(ud_apply "$MSUMS"); say "UD4 apply: $r"
			if pr_find 900 "$b" && pr_pc_place && ud_g; then
				ud_leak_ring "UD4: the A boot after the panic, at landing" boot "$(boot8)"
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
	ud_person_stop "UD5 (ii), UD1, UD10" ud_trial_end && return
	bs=$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null')
	[ "$bs" = "slot=B version=$hv" ] && ok "UD5 (ii) P: bad-slot = slot=B version=V before UD1" || inv "UD5 (ii) P: bad-slot [$bs]"
	if ud_to3 "$VHEX" "$X" "$PAYH" UD1; then
		bi=$(ud_bootinfo)
		q '/etc/init.d/batman-provhelper restart >/dev/null 2>&1'; sleep 5
		r=$(ud_poll 90 0 23); ud_phase "$r" 0 23 && ok "UD10: after a helper restart 0 + 23" || no "UD10: after the restart [$r]"
		ud_check "$VHEX"; r=$UDR; r=$(ud_status); ud_phase "$r" 3 && ok "UD10: a re-check without upload -> phase 3 (no worker)" || no "UD10: after the re-check [$r]"
		[ "$(ud_bootinfo)" = "$bi" ] && ok "UD10: bootinfo B unchanged" || no "UD10: bootinfo B changed"
		if ud_hold; then
			ud_g; b=$(boot8); r=$(ud_apply "$X"); say "UD1 apply: $r"
			if ud_land "$b" UD1; then
				r=$(ud_status); ud_phase "$r" 4 && ok "UD1: phase 4 in the trial" || no "UD1: in the trial [$r]"
				ud_check "$VHEX"; r=$UDR; [ "$(f "$r" ok)" = false ] && [ "$(f "$r" reason)" = 1 ] && ok "UD1: update.check in the trial -> ok=false reason 1" || no "UD1: check in the trial [$r]"
				ud_late_ring "UD1: the B trial boot, before the release"
				o=$(QT=900 q "$(release_guarded "$PR_LAND_BOOT" B)" | tail -1); say "UD1 release: $o"
				grep -q 'release: committed' <<< "$o" && ok "UD1: release: committed" || no "UD1: release [$o]"
				pr_pc_place; r=$(ud_status); ud_phase "$r" 5 && ok "UD1 / UD5 (ii): phase 5" || no "UD1: after the commit [$r]"
				[ -z "$(qr 'cat /opt/batdata/state/bad-slot 2>/dev/null')" ] && ok "UD5 (ii): bad-slot removed by the commit" || no "UD5 (ii): bad-slot still there"
				ud_late_ring "UD1: the B boot, before back_to_a"
				back_to_a && pr_pc_place && ud_g && { r=$(ud_status); ud_phase "$r" 0 - && ok "UD1: back on A, phase 0" || no "UD1: after back_to_a [$r]"; }
			fi
		fi
	fi
	ud_trial_end
}
# ud_trial_end: the arm's last ring, 02's record and log over the arm, then the end
ud_trial_end(){ local e l
	ud_leak_ring "the arm's end" boot "$(boot8)"
	e=$(ud_02_state); l=$(qp "if logread | grep -q 'batman-dv-ud: mark $UD02M\$'; then logread | sed -n '/batman-dv-ud: mark $UD02M\$/,\$p' | grep 'batman-provhelper\['; else echo LOST; fi")
	ud_verdicts "$(ud_02_judge "$UD02A" "$e" "$l")"
	ud_end wrote-b; }

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
