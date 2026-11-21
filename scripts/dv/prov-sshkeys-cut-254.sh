#!/bin/bash
# scripts/dv/prov-sshkeys-cut-254.sh — #329 (v1.6): ssh_keys.set must keep every app-added key tracked across a power
# loss or a failed --save (docs/design/329-sshkeys-cut.md v5 §8; reproduction #329 issuecomment-7059208023).
# Invariant I, judged on the node: every app key (A or B, throwaway ed25519 keys made for this run) that is in the
# overlay authorized_keys or in p5's identity/dropbear/authorized_keys is listed in p5's record (prov.cbor: the
# SSHKeysAdded lines are CBOR text, so a fixed-string grep finds them). Then the app's "remove all" (ssh_keys.set [])
# must leave neither A nor B logging in.
# Flow: claim (run owner) -> ssh_keys.set [A] (normal) -> batman-config-save bound with a hook -> ssh_keys.set [B] with
# the hook armed for one --save -> judge I -> ssh_keys.set [] -> A and B refused.
# The hook (one-shot) acts on the --save of the helper (parent /usr/bin/batman-provhelper) whose overlay prov.meta
# generation is G0 (pre-commit = the fix's step 1; today's code has none) or G0+1 (post-commit = the fix's step 3 =
# today's only --save). G0 = p5's generation just before the op. It logs every call (any mode, any parent).
# ARM (expected on wsl.33 = today | after the fix):
#   POST      sysrq at the post-commit --save        FAIL (rec B, p5 copy A: the negative control) | PASS
#   FAILPOST  the post-commit --save exits 1 unsaved FAIL (answers OK, p5 A, record B: negative control) | PASS (reason 25)
#   CUT1      sysrq at the pre-commit --save         INVALID (no step 1) | PASS
#   FAIL1     the pre-commit --save exits 1 unsaved, then a resend whose post-commit --save exits 1   INVALID | PASS
#   RC6       the post-commit --save runs, then exits 6   PASS | PASS (a guard: rc 6 is not a failure)
# INVALID (never a PASS): the hook never fired; a --save from another caller ran in the window; after a reboot, p5's
# authorized_keys was rewritten before the judgement.
# Type: — / F. Side effects: 04 claimed by this run ~25 min; the cut arms: 1 sysrq reboot + the restore's reboot.
# Run from Git Bash on the bench PC: NODE=<04> PEER=<02> bash scripts/dv/prov-sshkeys-cut-254.sh <ARM>
set -u
PR_UNIT=prov-sshkeys-cut-254
ARM=${1:-${ARM:-POST}}   # the suite passes it as $1 (prov-dv-254.sh)
case "$ARM" in
POST) MODE="cut"; AT=post ;; FAILPOST) MODE="fail"; AT=post ;; CUT1) MODE="cut"; AT=pre ;; FAIL1) MODE="fail"; AT=pre ;;
RC6) MODE="rc6"; AT=post ;; *) echo "FAIL $PR_UNIT: unknown ARM=$ARM (POST FAILPOST CUT1 FAIL1 RC6)"; exit 2 ;;
esac
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
W=/tmp/run/batman-dv/wbox/$RUN
AK=/etc/dropbear/authorized_keys
HELPER=/usr/bin/batman-provhelper
KD=$(mktemp -d); chmod 700 "$KD"
ssh-keygen -q -t ed25519 -N '' -C dv-cut-A -f "$KD/a" && ssh-keygen -q -t ed25519 -N '' -C dv-cut-B -f "$KD/b" || { echo "FAIL key generation"; exit 2; }
KA=$(cat "$KD/a.pub"); KB=$(cat "$KD/b.pub")
BA=$(cut -d' ' -f2 <<< "$KA"); BB=$(cut -d' ' -f2 <<< "$KB")   # the base64 bodies: what is grepped for (fixed strings)
cleanup_keys(){ rm -rf "$KD"; }
say "ARM=$ARM (hook: $MODE at the $AT-commit --save)"
# pk_login <private key>: 0 = that key logs in by publickey on the publickey-only listener; 1 = refused; 2 = probe broken
pk_login(){ local r=2 o
	q 'mkdir -p -m 0700 /tmp/run/batman-dv; pid=/tmp/run/batman-dv/dv-pk.pid; [ -s $pid ] && kill $(cat $pid) 2>/dev/null; nft -a list chain inet fw4 input 2>/dev/null | grep -q dv-pk-proof || nft insert rule inet fw4 input tcp dport 2222 accept comment "dv-pk-proof" 2>/dev/null; dropbear -s -g -p 2222 -P $pid && sleep 1 && [ -s $pid ] && echo LISTEN' | grep -q LISTEN || { echo "    pk_login: listener did not start"; return 2; }
	o=$(timeout 30 ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i "$1" -o LogLevel=VERBOSE root@$NODE 'echo PKOK' 2>&1 | tr -d '\r')
	if grep -qE 'Authenticated to .* using "publickey"' <<< "$o" && grep -q PKOK <<< "$o"; then r=0
	elif grep -q 'Permission denied' <<< "$o"; then r=1; fi
	o=$(q 'pid=/tmp/run/batman-dv/dv-pk.pid; kill $(cat $pid) 2>/dev/null; rm -f $pid; for h in $(nft -a list chain inet fw4 input 2>/dev/null | sed -n "s/.*dv-pk-proof.*# handle \([0-9]*\).*/\1/p"); do nft delete rule inet fw4 input handle $h; done; sleep 1; echo "left=$(nft -a list chain inet fw4 input 2>/dev/null | grep -c dv-pk-proof) listen=$(netstat -ltn 2>/dev/null | grep -c ":2222 ")"')
	[ "$o" = "left=0 listen=0" ] || { echo "    pk_login: cleanup incomplete ($o)"; r=2; }
	return $r; }
# where: "rec=.. file=.. p5rec=.. p5file=.. p5gen=.. ovgen=.. p5new=<0|1>" — which of A / B (A, B, AB, none) the overlay
# record, the overlay file, p5's record and p5's copy hold; both generations; p5new=1 when p5's authorized_keys was
# written after this boot began. p5 is mounted read-only with the journal replayed (-o ro, as batman-config-save's
# --prov-get), never ro,noload. Counts only, never a key printed.
where(){ qr "c(){ a=\$(grep -cF '$BA' \$1 2>/dev/null); b=\$(grep -cF '$BB' \$1 2>/dev/null); case \"\${a:-0}\${b:-0}\" in 00) echo none;; 0*) echo B;; *0) echo A;; *) echo AB;; esac; }
g(){ sed -n 's/.* gen=\([0-9]*\).*/\1/p' \$1 2>/dev/null; }
mkdir -p -m 0700 /tmp/run/batman-dv; m=\$(mktemp -d /tmp/run/batman-dv/p5k.XXXXXX)
if mount -t ext4 -o ro /dev/mmcblk0p5 \$m 2>/dev/null; then
 bt=\$((\$(date +%s) - \$(cut -d. -f1 /proc/uptime))); mt=\$(stat -c %Y \$m/identity/dropbear/authorized_keys 2>/dev/null || echo 0)
 echo \"rec=\$(c /etc/batman-prov/prov.cbor) file=\$(c $AK) p5rec=\$(c \$m/prov.cbor) p5file=\$(c \$m/identity/dropbear/authorized_keys) p5gen=\$(g \$m/prov.meta) ovgen=\$(g /etc/batman-prov/prov.meta) p5new=\$([ \$mt -gt \$bt ] && echo 1 || echo 0)\"
 umount \$m
else echo 'p5-mount-failed'; fi
rmdir \$m"; }
# holdsI <where line>: 0 = every app key in the overlay file and in p5's copy is in p5's record
holdsI(){ local rec f k
	rec=$(field "$1" p5rec)
	for f in "$(field "$1" file)" "$(field "$1" p5file)"; do
		for k in A B; do case "$f" in *$k*) case "$rec" in *$k*) ;; *) return 1 ;; esac ;; esac; done
	done; return 0; }
sk(){ pr_pc owner.pem -- ssh-keys "$@"; }
fired(){ qr "cat $W/fired 2>/dev/null"; }
calls(){ qr "cat $W/calls 2>/dev/null"; }   # every batman-config-save call the hook saw: "<mode> <parent exe> <g>"
fail_out(){ pr_abort "$1"; cleanup_keys; pr_result; exit 1; }

pr_begin 2400 || { cleanup_keys; pr_result; exit 1; }
pk_proof || fail_out "the lab key does not log in at the start"
pr_keys && pr_pc_place && pr_claim || fail_out "claim"
hp=$(qr "readlink /proc/\$(pidof batman-provhelper | cut -d' ' -f1)/exe"); [ "$hp" = "$HELPER" ] || { inv "the helper runs as '$hp', not $HELPER: the hook's parent check cannot work"; fail_out "precondition"; }
# --- A, the normal way
r=$(sk "'$KA'"); say "ssh_keys.set [A]: $r"
grep -q 'RESULT ssh_keys.set code=0' <<< "$r" || fail_out "ssh_keys.set [A] failed"
w=$(where); say "after [A]: $w"
case "$w" in "rec=A file=A p5rec=A p5file=A "*) ;; *) inv "after [A]: $w (want A everywhere)"; fail_out "precondition" ;; esac
pk_login "$KD/a"; [ $? = 0 ] || { inv "key A does not log in after a normal ssh_keys.set"; fail_out "precondition"; }
pk_proof || fail_out "the lab key stopped logging in after [A] (it was app-added?)"
ok "precondition: [A] set normally, A in the record, the file and p5's copy; A and the lab key log in"
# --- the hook. $W/arm = "<mode> <pre|post>", $W/g0 = G0; one-shot: removed when it acts, $W/fired records it.
pw prep >/dev/null
q "sync; cp -p /usr/bin/batman-config-save $W/cfgsave.real && chmod 700 $W/cfgsave.real && cat > $W/cfgsave.cut <<'HOOK'
#!/bin/sh
W=$W
pe=\$(readlink /proc/\$PPID/exe); g=\$(sed -n 's/.* gen=\([0-9]*\).*/\1/p' /etc/batman-prov/prov.meta 2>/dev/null)
[ -e \$W/window ] && echo \"\$1 \$pe \$g\" >> \$W/calls
if [ \"\$1\" = --save ] && [ -e \$W/arm ] && [ \"\$pe\" = $HELPER ]; then
	read mode at < \$W/arm; g0=\$(cat \$W/g0)
	case \"\$g\" in \"\$g0\") now=pre ;; \"\$((g0 + 1))\") now=post ;; *) now=other ;; esac
	logger -t batman-dv \"dv-cut $RUN: --save g0=\$g0 g=\$g at=\$now armed=\$mode/\$at\"
	if [ \"\$now\" = \"\$at\" ]; then
		rm -f \$W/arm; echo \"\$mode \$at \$g\" > \$W/fired; sync
		case \$mode in
		cut) logger -t batman-dv \"dv-cut $RUN: sysrq instead of --save\"; echo b > /proc/sysrq-trigger; sleep 30 ;;
		fail) logger -t batman-dv \"dv-cut $RUN: exit 1 instead of --save\"; echo 'batman-config-save: dv simulated failure' >&2; exit 1 ;;
		rc6) \$W/cfgsave.real \"\$@\"; rc=\$?; logger -t batman-dv \"dv-cut $RUN: real --save rc=\$rc, answered 6\"; exit 6 ;;
		esac
	fi
fi
exec \$W/cfgsave.real \"\$@\"
HOOK
chmod 755 $W/cfgsave.cut && sync"
h=$(qr "sha256sum < $W/cfgsave.cut | cut -c1-64"); o=$(pw bind cfgsave.cut "$h" /usr/bin/batman-config-save); say "$o"
grep -q '^BOUND /usr/bin/batman-config-save' <<< "$o" || fail_out "bind of the hook"
# arm <mode> <pre|post>: G0 = p5's generation now (== the overlay's; a mismatch is INVALID)
arm(){ local w0 g0
	w0=$(where); g0=$(field "$w0" p5gen)
	[ -n "$g0" ] && [ "$g0" = "$(field "$w0" ovgen)" ] || { inv "G0: p5 gen '$g0' vs overlay gen '$(field "$w0" ovgen)'"; return 1; }
	q "echo $g0 > $W/g0; rm -f $W/fired $W/calls; touch $W/window; echo '$1 $2' > $W/arm"; say "armed $1 at the $2-commit --save (G0=$g0)"; }
# other_calls: any config-save call in the window that is not the helper's (it could rewrite p5's copy)
other_calls(){ calls | awk -v h="$HELPER" '$2 != h' ; }
b0=$(field "$(qr "$ST")" boot)
reply=""
if [ "$ARM" = FAIL1 ]; then
	arm fail pre || fail_out "arm"
	r=$(sk "'$KB'"); say "ssh_keys.set [B], pre-commit save fails: $(echo $r)"
	[ -n "$(fired)" ] || { inv "the pre-commit --save never ran (today's code has no step 1)"; fail_out "not judged"; }
	grep -q 'RESULT ssh_keys.set code=21 reason=25' <<< "$r" && ok "first try answers EApply reason 25" || no "first try: want code=21 reason=25 ($(echo $r))"
	w=$(where); say "after the failed removal: $w"; holdsI "$w" && ok "I holds after the failed removal ($w)" || no "I broken after the failed removal ($w)"
	arm fail post || fail_out "arm"
fi
[ "$ARM" = FAIL1 ] || { arm "$MODE" "$AT" || fail_out "arm"; }
if [ "$MODE" = cut ]; then
	lf=$(mktemp); timeout 900 ssh $SSHO root@$NODE 'logread -f' > "$lf" 2>/dev/null & lp=$!
	sleep 2
fi
r=$(sk "'$KB'"); reply=$(echo $r); say "ssh_keys.set [B] ($ARM): $reply"
if [ "$MODE" = cut ]; then
	if grep -q '^RESULT' <<< "$r"; then
		kill $lp 2>/dev/null; rm -f "$lf"
		inv "the op got a reply: the cut never fired ($(echo $r); fired=[$(fired)])"; q "rm -f $W/arm $W/window"; fail_out "not judged"
	fi
	ok "no reply to ssh_keys.set [B] (the node went down)"
	pr_find 900 "$b0" || { kill $lp 2>/dev/null; no "no node after the cut"; pr_needs_person "04 did not come back after the sysrq"; cleanup_keys; pr_result; exit 1; }
	kill $lp 2>/dev/null; wait $lp 2>/dev/null
	grep "dv-cut $RUN" "$lf" | sed 's/^/    /'
	grep -q "dv-cut $RUN: sysrq instead of --save" "$lf" && ok "the cut hit the $AT-commit --save (log line seen)" || { inv "no dv-cut sysrq line ($(wc -l < "$lf") lines): where the power went is unknown"; }
	rm -f "$lf"
	o=$(qr 'tail -1 /opt/batdata/log/boot-reasons.log'); case "$o" in *UNCLEAN*"hints: sysrq"*) ok "boot-reasons: UNCLEAN, hints: sysrq" ;; *) inv "boot-reasons: $o" ;; esac
	w=$(where); say "after the cut: $w"
	[ "$(field "$w" p5new)" = 0 ] || inv "p5's authorized_keys was rewritten after the reboot, before the judgement"
	pr_pc_place || fail_out "provclient after the reboot"
else
	f=$(fired); [ -n "$f" ] || { inv "the $AT-commit --save never ran (fired empty; calls: $(calls | tr '\n' ';'))"; q "rm -f $W/arm $W/window"; fail_out "not judged"; }
	say "hook fired: $f; calls: $(calls | tr '\n' ';')"
	w=$(where); say "after the op: $w"
	case "$ARM" in
	FAILPOST|FAIL1) grep -q 'RESULT ssh_keys.set code=21 reason=25' <<< "$r" && ok "the failed save answers EApply reason 25" || no "the failed save answered '$reply' (want code=21 reason=25: a not-persisted change must not answer OK)" ;;
	RC6) grep -q 'RESULT ssh_keys.set code=0' <<< "$r" && ok "rc 6 answers OK" || no "rc 6 answered '$reply' (want code=0)" ;;
	esac
fi
oc=$(other_calls); [ -z "$oc" ] || inv "another batman-config-save caller ran in the window: $(echo $oc)"
q "rm -f $W/arm $W/window"
# --- (1) invariant I
holdsI "$w" && ok "(1) I holds: every app key in the file and in p5's copy is in p5's record ($w)" || no "(1) I broken: an app key is in the file or in p5's copy but not in p5's record ($w)"
pk_login "$KD/a"; la=$?; pk_login "$KD/b"; lb=$?; say "logins after the op: A rc=$la B rc=$lb (0 in, 1 refused)"
# --- (2) the app's "remove every key the app added" (hook disarmed: the real --save)
r=$(sk); say "ssh_keys.set []: $(echo $r)"
grep -q 'RESULT ssh_keys.set code=0' <<< "$r" || no "(2) ssh_keys.set [] failed ($(echo $r))"
w=$(where); pk_login "$KD/a"; la=$?; pk_login "$KD/b"; lb=$?
say "after ssh_keys.set []: $w, A rc=$la B rc=$lb"
[ $la = 1 ] && [ $lb = 1 ] && ok "(2) neither A nor B logs in after the app removed its keys" || no "(2) a key the app added still logs in after the app removed its keys (A rc=$la, B rc=$lb; $w)"
case "$w" in *" file=none p5rec=none p5file=none "*) ok "(2) A and B gone from the file, p5's record and p5's copy" ;; *) no "(2) after ssh_keys.set []: $w" ;; esac
pk_proof && ok "the lab key still logs in" || no "the lab key does not log in"
pr_end
# after the restore: the throwaway keys are gone from the node
w=$(where); case "$w" in *" file=none "*) ok "after the restore: A and B not in authorized_keys" ;; *) no "after the restore: $w" ;; esac
cleanup_keys
pr_result
