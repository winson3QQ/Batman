#!/bin/bash
# scripts/dv/prov-claim-254.sh — #254 PR-H2 tier B unit prov-claim (docs/design/254-p1-impl.md §5.3, parent L18/L34/L47):
# snap S0 -> claim a LEGACY node with provclient (owner key generated per run on the WSL host, never on the node)
# -> assert: claimed, sshd now publickey-only, ttylogin=1, LOCKED, key login still works, secrets not leaked ->
# negative: the buyer's response with the attacker's owner_pub is refused -> restore S0 (file-level: p5 dd back,
# overlay tar, p6 state) -> assert S0.
# Runs from Git Bash on the Windows host (key auth, LAN); the signer runs in WSL (owner key on ext4, 0600).
set -u
NODE=${NODE:-10.41.1.3}
RUN=${RUN:-claim$(date +%m%d%H%M)}
HT=$(mktemp -d); RUNLOG=$HT/out.log; exec > >(tee "$RUNLOG") 2>&1   # host-side scratch (Git Bash): mktemp -d
H=$(cd "$(dirname "$0")/../.." && pwd)
TOOLS=${DV_PROV_TOOLS:?DV_PROV_TOOLS = host dir with provclient-arm64 (pushed to the node)}
TOOLS_WSL=${DV_PROV_TOOLS_WSL:-/home/yello/batman-dv-tools/prov}   # provclient-amd64 (the signer) inside WSL
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes"
WSLK=/home/yello/.batman-dv/prov-keys/$RUN
say(){ echo "[$(date +%H:%M:%S) prov-claim $RUN] $*"; }
fails=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
q(){ timeout 120 ssh $SSHO root@$NODE "$@" 2>/dev/null | tr -d '\r'; }
nb(){ timeout 900 ssh $SSHO root@$NODE sh -s -- "$@" < "$H/scripts/node/prov-base-254.sh" 2>&1 | tr -d '\r'; }
wsl_(){ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; }
bid(){ timeout 20 ssh $SSHO root@$NODE 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n '; }
waitboot(){ local b0=$1 t0=$SECONDS b; while [ $((SECONDS-t0)) -lt 900 ]; do b=$(bid); [ -n "$b" ] && [ "$b" != "$b0" ] && return 0; sleep 10; done; return 1; }
settle(){ local t0=$SECONDS u; while [ $((SECONDS-t0)) -lt 600 ]; do u=$(q 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 90 ] && return 0; sleep 10; done; return 1; }

# --- 0. preconditions: legacy, committed on A, helper serving
s=$(q 'echo "slot=$(batman-slot active) trial=$(batman-slot is-trial >/dev/null 2>&1; echo $?) state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) helper=$(pidof batman-provhelper >/dev/null && echo up || echo down)"')
say "pre: $s"
case "$s" in *"slot=A trial=1 state=legacy helper=up"*) ;; *) no "precondition (want A committed, legacy, helper up): $s"; exit 1;; esac

# the claim turns password / `none` login off: prove a FRESH publickey-only login works first (A-m8), else abort
timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=6 -o PreferredAuthentications=publickey -o IdentitiesOnly=yes root@$NODE 'echo PKOK' 2>/dev/null | tr -d '\r' | grep -q PKOK \
	&& ok "publickey-only login works before the claim" || { no "publickey-only login does not work — not claiming (the claim would lock us out)"; exit 1; }

# --- 1. snapshot (S0) and per-run owner keys (WSL ext4, 0600)
o=$(nb snap "$RUN"); echo "$o" | tail -1; grep -q "^SNAP $RUN" <<< "$o" || { no "snap"; exit 1; }
wsl_ bash -c "umask 077; mkdir -p $WSLK && $TOOLS_WSL/provclient-amd64 keygen $WSLK/owner.pem > $WSLK/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/enc.pem > $WSLK/enc.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/attacker.pem > $WSLK/attacker.pub && stat -c '%a' $WSLK/owner.pem"
OWNER=$(wsl_ cat $WSLK/owner.pub | tr -d '\r'); ENC=$(wsl_ cat $WSLK/enc.pub | tr -d '\r'); ATK=$(wsl_ cat $WSLK/attacker.pub | tr -d '\r')
[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] || { no "owner keys"; exit 1; }

# --- 2. provclient onto the node: /tmp/run/batman-dvpc.<run>/ root 0711, file root 0755, sha checked (§4.3)
PCD=/tmp/run/batman-dvpc.$RUN
q "mkdir -p -m 0700 /tmp/run/batman-dv" >/dev/null; scp -q $SSHO "$TOOLS/provclient-arm64" root@$NODE:/tmp/run/batman-dv/pc.$RUN.upload || { no "upload"; exit 1; }
PSHA=$(sha256sum "$TOOLS/provclient-arm64" | cut -c1-64)
q "set -e; mkdir -m 0711 $PCD; mv /tmp/run/batman-dv/pc.$RUN.upload $PCD/provclient; chown root:root $PCD $PCD/provclient; chmod 0755 $PCD/provclient; [ \"\$(sha256sum < $PCD/provclient | cut -c1-64)\" = $PSHA ] && echo PCOK" | grep -q PCOK && ok "provclient placed ($PCD, sha checked)" || no "provclient placement"
# pc <key> <op> [args]: run provclient on the node; its "SIGN …" lines go to the WSL signer (coproc), each "SIG …"
# answer goes back to the node's stdin through a FIFO; every other line is the op's output (secrets only as sha prefixes)
pc(){
	local key=$1; shift
	local f; f=$(mktemp -d "$HT/fifo.XXXXXX")/p; mkfifo "$f"
	coproc SIGNP { wsl_ "$TOOLS_WSL/provclient-amd64" sign "$WSLK/$key"; }
	exec {W}<>"$f"
	local out="" line sig
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in
			SIGN\ *) echo "$line" >&"${SIGNP[1]}"; IFS= read -r -t 30 sig <&"${SIGNP[0]}" || sig=ERR; printf '%s\n' "$sig" | tr -d '\r' >&"$W" ;;
			*) out="$out$line
" ;;
		esac
	done < <(ssh $SSHO root@$NODE "$PCD/provclient node $*" < "$f" 2>&1)
	exec {W}>&-; exec {SIGNP[1]}>&-; rm -f "$f"
	printf '%s' "$out"
}

# --- 3. negative first (state must not change): the buyer's response bound to the OWNER key, sent with the ATTACKER key
r=$(pc owner.pem claim-attacker "$ATK" "$ENC" "$OWNER"); echo "$r"
grep -q "RESULT claim.verify code=3 " <<< "$r" && ok "attacker owner_pub with the buyer's response -> E_FORBIDDEN" || no "attacker claim not refused: $r"
[ "$(q 'sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta')" = legacy ] && ok "state still legacy after the refused claim" || no "state changed by a refused claim"

# --- 4. the claim
r=$(pc owner.pem claim "$OWNER" "$ENC"); echo "$r"
grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "claim.verify code 0" || no "claim failed: $r"
st=$(q 'echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) lock=$(cat /opt/batdata/state/lock-status) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth) rootpw=$(uci -q get dropbear.@dropbear[0].RootPasswordAuth) tty=$(uci -q get system.@system[0].ttylogin) hash=$(grep ^root: /etc/shadow | cut -d: -f2 | cut -c1-3)"')
say "after claim: $st"
for want in state=claimed lock=LOCKED pw=off rootpw=off tty=1 'hash=$6$'; do case "$st" in *"$want"*) ok "claimed node: $want";; *) no "claimed node: want $want";; esac; done
# the SERVER's offered auth methods (not a wrong-password attempt): only publickey left
m=$(ssh -v -o BatchMode=yes -o PreferredAuthentications=none -o PubkeyAuthentication=no root@$NODE true 2>&1 | sed -n 's/.*Authentications that can continue: //p' | tail -1 | tr -d '\r')
[ "$m" = publickey ] && ok "sshd offers only: $m" || no "sshd offers [$m] (want publickey only)"
q 'echo KEYOK' | grep -q KEYOK && ok "key login still works (L47)" || no "key login lost after the claim"
# p5 carries the claim (gen advanced) and agrees with the overlay
q 'd=$(mktemp -d /tmp/run/batman-dv/pg.XXXXXX); rmdir $d; batman-config-save --prov-get $d >/dev/null 2>&1; cmp -s $d/prov.meta /etc/batman-prov/prov.meta && echo P5SAME; rm -rf $d' | grep -q P5SAME && ok "p5 prov.meta == overlay after the claim" || no "p5 / overlay differ after the claim"
# a second claim of a claimed node is refused
r=$(pc owner.pem claim "$OWNER" "$ENC"); grep -q "RESULT claim.verify code=3 " <<< "$r" && ok "re-claim of a claimed node -> E_FORBIDDEN" || no "re-claim: $r"
# rename is not offered in P1 (P-U7)
r=$(pc owner.pem rename); grep -q "code=6" <<< "$r" && ok "settings.set hostname -> E_UNSUPPORTED (P-U7)" || no "rename: $r"

# --- 5. canary: no secret value in the node log ring or this run's output (only sha prefixes may appear)
q 'logread' > "$HT/logread" 2>/dev/null
cs=$(q 'hexdump -v -e "/1 \"%02x\"" /etc/batman-prov/identity/claim.secret' | cut -c1-16)
[ -n "$cs" ] && ! grep -qi "$cs" "$HT/logread" && ok "claim.secret not in logread" || no "claim.secret canary (logread)"
sync; [ -n "$cs" ] && ! grep -qi "$cs" "$RUNLOG" && ok "claim.secret not in this run's output" || no "claim.secret canary (run output)"
q "cat /opt/batdata/log/*.log 2>/dev/null" | grep -qi "$cs" && no "claim.secret canary (p6 logs)" || ok "claim.secret not in p6 logs"
rm -f "$HT/logread"

# --- 6. restore S0: p5 back, overlay back (tar + extras removed + p6 state), reboot committed, compare, finish
o=$(nb p5-restore "$RUN"); echo "$o" | tail -1; grep -q "^P5-RESTORED" <<< "$o" || no "p5 restore"
o=$(nb overlay-restore "$RUN"); echo "$o" | grep -E "EXTRA-REMOVED|OVERLAY" | tail -8; grep -q "^OVERLAY-RESTORED" <<< "$o" || no "overlay restore"
b0=$(bid); q "(batman-slot reboot committed prov-claim </dev/null >/dev/null 2>&1 &)"; waitboot "$b0" && settle || no "reboot after restore"
nb manifest "$RUN" after >/dev/null; o=$(nb compare "$RUN" after); echo "$o" | sed 's/^/    /' | tail -30
if grep -q "diffs=0" <<< "$o"; then ok "S0 restored (p5 / overlay / uci / identity / p6 state)"; nb finish "$RUN" | tail -1; else no "S0 not restored — snapshot and dirty flag kept"; fi
st=$(q 'echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) lock=$(cat /opt/batdata/state/lock-status) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth)"'); say "after restore: $st"
case "$st" in *"state=legacy lock=UNPROVISIONED pw=on"*) ok "back to legacy / UNPROVISIONED / password auth on";; *) no "not back to legacy: $st";; esac
q "rm -rf $PCD"; wsl_ rm -rf "$WSLK"
say "fails=$fails"; rm -rf "$HT"; [ "$fails" = 0 ]
