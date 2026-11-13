#!/bin/bash
# scripts/dv/prov-update-254.sh — #254 H4 appendix A.9, the R rows on the committed release image (p3-how "h"):
#   UD-T1  a manifest signed with the TEST keys (T -> K_test, signrel.py) is refused by an image that does not trust T.
#          First the image's root, from status key 15 "trust" (none / bad / the fingerprint's first 8 bytes, 16 hex):
#            = T's fingerprint (tests/keys/T.pub) -> INVALID "bench image: UD-T1 needs an R image" (a bench build
#              trusts T: the check would pass, which says nothing about a release image);
#            none (wsl / ci build, no key file)   -> update.check ok = false, reason 24 (no root key: no app update);
#            any other fingerprint (R)            -> ok = false, reason 11 (the release trusts only R; 254-p3 §3.7.1);
#            bad                                  -> FAIL (the image's key files are malformed);
#            no trust in key 15                   -> INVALID (a pre-S5 node, or a provclient that does not print it).
#          The manifest itself is valid (signrel --verify ok on the host: P) - what is refused is the root, not the object.
#          Then the image's /rom key files against that trust (release-key-254's rk_judge with status key 15: the files
#          read the way release.LoadTrust reads them must give the same none / fingerprint the helper reports; review r2
#          A-m2 / B-m10). On the bench fleet (02 / 04 trust T) UD-T1 is always INVALID: its R and none arms get their
#          evidence offline (A.9 UD-T1 / p3-how: Batman-p3 release_test.go TestVerifySignrelNegative "other root" -> 11
#          and "no trust" -> 24, node/update_test.go TestUpdateCheckRefusals "no key" -> 24, firmware
#          scripts/check-release-key-gate.sh + test-release-key-gate.sh) until an R image is on a node (review r2 B-m9).
#   UD-L   (254-p3-impl §3.7.3) after a step whose helper ran a lock-holding batman-slot verb reports done, the slot flock
#          is free within 1 s and nothing the step started still has the lock file open (pr_slot_free). Here: the
#          update.check, judged whenever it ran precheck-node (pr_precheck_ran: ok=true, or a refusal from precheck-node
#          or later — review r2 A-m3); one that stopped before it (R: reason 11, none: 24, board / version) is a
#          NOT-JUDGED line (nj), never silent. The prepare / apply / disarm steps get the same assertion when their RB
#          rows are written.
#   (P)    update.status on an idle node: phase 0, no failure reason.
# The other 29 rows need a prov_test image that trusts T (RB: the seven rejections UD7, the malicious tars UD8, the
# trial / commit / revert rows UD1-UD5 ...) or a fresh card (UD12): they follow with the RB vehicle (push-provd
# + T-trust) once P3's prov_test build exists. The manifest is built on the host from the running version's own
# payload tar (OUTS/<V>/ekh-bcm2711/*-ab-payload.tar.gz; --version given: pre-P3 payloads carry no release= line).
# W (pre-P3 image): update.check / update.status are unknown (20) -> the rows FAIL with the code they got.
# Type: R. Side effects: none beyond the unit's snapshot and restore (one reboot).
set -u
PR_UNIT=prov-update-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
# shellcheck source=scripts/dv/s5-254.sh
. "$(dirname "$0")/s5-254.sh"   # rk_judge / RK_Q (release-key-254), for the UD-T1 cross-check
OUTS=${OUTS:-//wsl.localhost/Ubuntu-24.04/home/yello/out}
PYW=${H4_PY_WSL:-/home/yello/.batman-dv/peer-venv/bin/python}
pr_begin 1200 || { pr_result; exit 1; }
pr_h0 && pr_pc_place || { pr_abort "provclient / bench owner key"; pr_result; exit 1; }
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
f(){ sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<< "$1" | head -1; }
V_NOW=$(field "$(qr "$ST")" ver); BOARD=$(qr "sed -n 's/^BATMAN_BOARD=//p' /etc/batman-build"); BOARD=${BOARD:-ekh-bcm2711}
PAYH=$(ls "$OUTS/$V_NOW/ekh-bcm2711/"*-ab-payload.tar.gz 2>/dev/null | head -1)
[ -n "$PAYH" ] || { inv "no payload tar for $V_NOW under $OUTS (the manifest is built from it)"; pr_end; pr_result; exit 2; }
PAYW=/home/yello/out/$V_NOW/ekh-bcm2711/$(basename "$PAYH")   # the same file, WSL path (signrel runs in the venv)
# ---- the T-signed manifest (built in WSL; the hex crosses to the node as a provclient argument: not a secret)
MDIR=/home/yello/.batman-dv/run-$RUN; wsl_ bash -c "umask 077; mkdir -p $MDIR" >/dev/null
m=$(wsl_ "$PYW" "$REPO_WSL/tests/tools/peer/signrel.py" "$PAYW" --board "$BOARD" --version "$V_NOW" --allow-no-key --out "$MDIR" 2>&1 | tr -d '\r' | tail -1); say "manifest: $m"
case "$m" in "MANIFEST sha="*) ok "a T-signed manifest for $V_NOW / $BOARD (P)";; *) inv "signrel did not produce a manifest: [$m]"; wsl_ rm -rf "$MDIR"; pr_end; pr_result; exit 2;; esac
v=$(wsl_ "$PYW" "$REPO_WSL/tests/tools/peer/signrel.py" --verify "$MDIR/manifest.cbor" --board "$BOARD" 2>&1 | tr -d '\r' | tail -1); say "verify: $v"
case "$v" in "VERIFY ok"*) ok "the manifest verifies under T on the host (P: what the node refuses is the root, not the object)";; *) inv "the test manifest does not verify under T: [$v]";; esac
HEX=$(wsl_ cat "$MDIR/manifest.hex" | tr -d '\r\n'); wsl_ rm -rf "$MDIR" >/dev/null
# ---- UD-T1: which root does the image trust (status key 15), then the T-signed manifest against it
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
# ---- UD-L: a check that got past the root ran precheck-node + bootinfo (both hold the slot flock)
if why=$(pr_precheck_ran "$r"); then pr_slot_free "update.check (precheck-node$([ "$(f "$r" ok)" = true ] && echo ' + bootinfo'))" "$t0"
else nj "UD-L: $why — no lock-holding verb ran in this step (the read-only verbs' release is judged every run by prov-fw-boot-254 FB6)"; fi
# ---- (P) idle status
r=$(pr_pc h0.pem -- update-status "$H0" | grep '^RESULT update.status'); say "status: $r"
[ "$(code "$r")" = 0 ] && [ "$(f "$r" phase)" = 0 ] && ok "update.status idle: phase 0" || no "update.status on an idle node: code $(code "$r") phase $(f "$r" phase) (want 0 / 0): [$r]"
pr_end
pr_result
