#!/bin/bash
# scripts/test-s5-dv-254.sh — offline tests of the #254 S5 host-side judges in scripts/dv/prov-254.sh (no node; qr is a
# stub returning canned node output):
#   pr_t_fpr        T's fingerprint = sha256 of the 65-byte point, first 8 bytes (computed here a second way); a T.pub
#                   that is not one line of 130 hex -> rc 1, never a fingerprint
#   pr_trust_want   UD-T1: T -> INVALID bench; none -> reason 24; another root -> 11; bad / "?" -> FAIL; no trust in key
#                   15 -> INVALID (pre-S5 node / old provclient); empty -> INVALID
#   pr_cddl_nu      the CDDL network/update capability: the helper's "update shape" text -> go on; none -> INVALID
#                   "pre-CDDL"; no helper / no answer -> INVALID; never a PASS or FAIL line
#   pr_slot_free    SLKFREE ok -> PASS; leak / nofile -> FAIL; other / garbage / no start time -> INVALID
# Zero cases = FAIL.
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
# shellcheck disable=SC2254  # $3 is a glob pattern on purpose
want(){ n=$((n + 1)); case "$2" in $3) echo "ok   $1" ;; *) echo "FAIL $1: [$2] want $3"; f=$((f + 1)) ;; esac; }
export TEMP=$T PR_UNIT=prov-s5test-254 NODE=192.0.2.1 PEER=192.0.2.2
# shellcheck source=scripts/dv/prov-254.sh
. "$R/scripts/dv/prov-254.sh" >/dev/null 2>&1 || { echo "FAIL cannot source prov-254.sh"; echo "S5-DV 0 passed, 1 failed"; exit 1; }
trap 'rm -rf "$T"' EXIT   # prov-254.sh sets no trap until pr_begin; keep ours
# ---- pr_t_fpr
h=$(tr -d '\r\n' < "$R/tests/keys/T.pub")
alt=$(printf '%s' "$h" | xxd -r -p 2>/dev/null | sha256sum | cut -c1-16)
[ -n "$alt" ] && [ "$alt" != e3b0c44298fc1c14 ] || alt=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(bytes.fromhex(sys.argv[1])).hexdigest()[:16])' "$h" 2>/dev/null)
want "pr_t_fpr = sha256(T point)[:8], computed a second way" "$(pr_t_fpr)" "$alt"
want "pr_t_fpr is 16 hex" "$(pr_t_fpr)" '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
mkdir -p "$T/r/tests/keys"; echo "04zz" > "$T/r/tests/keys/T.pub"
# shellcheck disable=SC2034  # REPO is read by pr_t_fpr in this subshell
o=$(REPO=$T/r; pr_t_fpr; echo "rc=$?"); want "pr_t_fpr: a malformed T.pub -> rc 1, no fingerprint" "$o" "rc=1"
TF=$(pr_t_fpr)
# ---- pr_trust_want (the RESULT line provclient prints, fmtStatus)
L="RESULT status.get(scope 0) code=0 state=member verdict=0 neighbours=1 p5_saved=true f15=age_s,image,join,trust"
want "trust T -> INVALID bench image" "$(pr_trust_want "$L trust=$TF")" "inv bench image*needs an R image"
want "trust none -> reason 24" "$(pr_trust_want "$L trust=none")" "want 24"
want "trust R (another fingerprint) -> reason 11" "$(pr_trust_want "$L trust=0011223344556677")" "want 11"
want "trust bad -> FAIL" "$(pr_trust_want "$L trust=bad")" "fail *malformed*"
want "trust ? (provclient: not a trust value) -> FAIL" "$(pr_trust_want "$L trust=?")" "fail *malformed*"
want "key 15 names trust, no value printed -> INVALID rebuild the provclient" "$(pr_trust_want "$L")" "inv *rebuild the tools*"
want "key 15 without trust -> INVALID pre-S5" "$(pr_trust_want "RESULT status.get(scope 0) code=0 state=member f15=age_s,image")" "inv status key 15 has no trust*"
want "no status line -> INVALID" "$(pr_trust_want "")" "inv status key 15 has no trust*"
# shellcheck disable=SC2034
o=$(REPO=$T/r; pr_trust_want "$L trust=none"); want "T unreadable -> INVALID, never a judgement" "$o" "inv T's fingerprint unreadable*"
# ---- pr_cddl_nu (qr stubbed: the first call is the capability probe, later ones the state line)
cddl(){ echo "$1" > "$T/q1"; fails=0; invalid=0
	o=$(qr(){ case "$1" in *"update shape"*) cat "$T/q1" ;; *) echo "mac=x ver=1.5.14-wsl.24+e5c89a1.fw7ce6e80 slot=A" ;; esac; }; pr_cddl_nu; echo "rc=$? fails=$fails invalid=$invalid"); }
cddl "SHAPE=1"; want "helper with the CDDL text -> rc 0, nothing printed" "$o" "rc=0 fails=0 invalid=0"
cddl "SHAPE=0"; want "pre-CDDL helper -> INVALID pre-CDDL (with the version)" "$o" "INVALID prov-s5test-254: pre-CDDL network/update helper on 1.5.14-wsl.24*rc=1 fails=0 invalid=1"
cddl "NOHELPER"; want "no helper -> INVALID cannot tell" "$o" "INVALID *cannot tell*rc=1 fails=0 invalid=1"
cddl ""; want "no answer -> INVALID cannot tell" "$o" "INVALID *cannot tell*rc=1 fails=0 invalid=1"
case "$o" in *PASS*|*FAIL*) n=$((n + 1)); f=$((f + 1)); echo "FAIL pr_cddl_nu printed a PASS / FAIL";; esac
# ---- pr_slot_free
sf(){ echo "$1" > "$T/q2"; fails=0; invalid=0
	o=$(qr(){ cat "$T/q2"; }; say(){ :; }; pr_slot_free "x" "${2-1234}"; echo "fails=$fails invalid=$invalid"); }
sf "SLKFREE ok t=0"; want "free -> PASS" "$o" "PASS prov-s5test-254: the slot flock is free <= 1 s after x*fails=0 invalid=0"
sf "SLKFREE leak holders=812:sleep:ours"; want "a child kept fd 9 -> FAIL" "$o" "FAIL *still held after x by what the step started: holders=812:sleep:ours*fails=1 invalid=0"
sf "SLKFREE nofile"; want "no lock file -> FAIL" "$o" "FAIL *no slot lock file after x*fails=1 invalid=0"
sf "SLKFREE other holders=900:batman-slot:other"; want "contention -> INVALID" "$o" "INVALID *contention*fails=0 invalid=1"
sf ""; want "no answer -> INVALID" "$o" "INVALID *printed \[\]*fails=0 invalid=1"
sf "SLKFREE ok t=0" ""; want "no start time -> INVALID, the node is not asked" "$o" "INVALID *no start time*fails=0 invalid=1"
echo "S5-DV $((n - f)) passed, $f failed"
[ "$n" -gt 0 ] && [ "$f" = 0 ]
