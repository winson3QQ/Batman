#!/bin/bash
# scripts/dv/prov-claim-254.sh — #254 tier B unit prov-claim (docs/design/254-p1-impl.md §5.3; claim-lock fix
# docs/design/254-claim-lock-fix.md §11.3): snap S0 -> claim a LEGACY node with provclient (owner keys generated per
# run on the WSL host, never on the node) -> assert the node is LOCKED and the password the helper returned is the one
# in shadow (musl crypt() probe ON the node; the password never leaves the node) -> claim/replay and
# root_password/reset rotate it -> attacker / re-claim / rename refused -> no secret in any log -> restore S0.
# Runs from Git Bash on the Windows host (key auth, LAN); the signer runs in WSL (owner key on ext4, 0600).
# On an image without the claim-lock fix (1.5.13) the lock / probe / replay assertions FAIL by design.
set -u
NODE=${NODE:-10.41.1.3}
RUN=${RUN:-claim$(date +%m%d%H%M)}
HT=$(mktemp -d); RUNLOG=$HT/out.log; exec > >(tee "$RUNLOG") 2>&1
H=$(cd "$(dirname "$0")/../.." && pwd)
TOOLS=${DV_PROV_TOOLS:?DV_PROV_TOOLS = host dir with provclient-arm64 (pushed to the node)}
TOOLS_WSL=${DV_PROV_TOOLS_WSL:-/home/yello/batman-dv-tools/prov}
PROBE=${DV_CRYPTPROBE:?DV_CRYPTPROBE = host dir from scripts/dv-cryptprobe-tools.sh (cryptprobe-arm64, MUSL, SHA256SUMS)}
LABKEY=${LABKEY:-$HOME/.ssh/id_ed25519}
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes"
WSLK=/home/yello/.batman-dv/prov-keys/$RUN
PCD=/tmp/run/batman-dvpc.$RUN
say(){ echo "[$(date +%H:%M:%S) prov-claim $RUN] $*"; }
fails=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
q(){ timeout 120 ssh $SSHO root@$NODE "$@" 2>/dev/null | tr -d '\r'; }
nb(){ timeout 900 ssh $SSHO root@$NODE sh -s -- "$@" < "$H/scripts/node/prov-base-254.sh" 2>&1 | tr -d '\r'; }
wsl_(){ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; }
bid(){ timeout 20 ssh $SSHO root@$NODE 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n '; }
waitboot(){ local b0=$1 t0=$SECONDS b; while [ $((SECONDS-t0)) -lt 900 ]; do b=$(bid); [ -n "$b" ] && [ "$b" != "$b0" ] && return 0; sleep 10; done; return 1; }
settle(){ local t0=$SECONDS u; while [ $((SECONDS-t0)) -lt 600 ]; do u=$(q 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 90 ] && return 0; sleep 10; done; return 1; }
# publickey PROOF: OpenSSH always tries `none` first and an open node accepts it, so the key is proven against a
# temporary publickey-only listener of the same dropbear (-s -g, port 2222, a tagged nft accept rule), whose own
# negative control is that `none` is denied there; listener and rule are removed and that is asserted.
PKO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $LABKEY -o LogLevel=VERBOSE"
NONEO="-o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PreferredAuthentications=none -o PubkeyAuthentication=no -o LogLevel=ERROR"
pk_proof(){ local r=1 o
	q 'pid=/tmp/run/dv-pk.pid; [ -s $pid ] && kill $(cat $pid) 2>/dev/null; nft -a list chain inet fw4 input 2>/dev/null | grep -q dv-pk-proof || nft insert rule inet fw4 input tcp dport 2222 accept comment "dv-pk-proof" 2>/dev/null; dropbear -s -g -p 2222 -P $pid && sleep 1 && [ -s $pid ] && echo LISTEN' | grep -q LISTEN || { echo "    pk_proof: listener did not start"; return 1; }
	o=$(timeout 30 ssh -p 2222 $PKO root@$NODE 'echo PKOK' 2>&1 | tr -d '\r')
	if grep -qE 'Authenticated to .* using "publickey"' <<< "$o" && grep -q PKOK <<< "$o"; then
		timeout 30 ssh -p 2222 $NONEO root@$NODE 'echo NONEOK' 2>&1 | grep -q "Permission denied" && r=0 || echo "    pk_proof: 'none' not denied on the publickey-only listener (probe invalid)"
	else echo "    pk_proof: no publickey authentication on the listener"; fi
	o=$(q 'pid=/tmp/run/dv-pk.pid; kill $(cat $pid) 2>/dev/null; rm -f $pid; for h in $(nft -a list chain inet fw4 input 2>/dev/null | sed -n "s/.*dv-pk-proof.*# handle \([0-9]*\).*/\1/p"); do nft delete rule inet fw4 input handle $h; done; sleep 1; echo "left=$(nft -a list chain inet fw4 input 2>/dev/null | grep -c dv-pk-proof) listen=$(netstat -ltn 2>/dev/null | grep -c ":2222 ")"')
	[ "$o" = "left=0 listen=0" ] || { echo "    pk_proof: cleanup incomplete ($o)"; r=1; }
	return $r; }
# the server's offered methods on port 22, read from a `none` attempt (not a wrong-password attempt)
offered(){ timeout 30 ssh -v $NONEO -o LogLevel=DEBUG root@$NODE true 2>&1 | tr -d '\r' | sed -n 's/.*Authentications that can continue: //p' | tail -1; }
# probe <pwfile on node> -> MATCH / NOMATCH / ... of crypt(password, shadow's root hash), computed ON the node
probe(){ q "h=\$(grep '^root:' /etc/shadow | cut -d: -f2); $PCD/cryptprobe \"\$h\" < $1"; }

# --- 0. preconditions: legacy, committed on A, helper serving; publickey proven
s=$(q 'echo "slot=$(batman-slot active) trial=$(batman-slot is-trial >/dev/null 2>&1; echo $?) state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) helper=$(pidof batman-provhelper >/dev/null && echo up || echo down) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build)"')
say "pre: $s"
case "$s" in *"slot=A trial=1 state=legacy helper=up"*) ;; *) no "precondition (want A committed, legacy, helper up): $s"; exit 1;; esac
pk_proof && ok "publickey proven before the claim (the claim turns password / none login off)" || { no "publickey not proven — not claiming"; exit 1; }
# probe tool and libc version (the probe is static against the toolchain's musl; refuse a mismatch)
(cd "$PROBE" && sha256sum -c --quiet SHA256SUMS) || { no "$PROBE/SHA256SUMS does not verify"; exit 1; }
nm=$(q '/lib/libc.so 2>&1 | sed -n "s/^Version //p"'); pm=$(cat "$PROBE/MUSL")
[ -n "$nm" ] && [ "$nm" = "$pm" ] && ok "probe musl $pm == node libc $nm" || { no "probe musl [$pm] != node libc [$nm]"; exit 1; }

# --- 1. snapshot (S0) and per-run owner keys (WSL ext4, 0600)
q "mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$H/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt || { no "allow-list upload"; exit 1; }
o=$(nb snap "$RUN"); echo "$o" | tail -1; grep -q "^SNAP $RUN" <<< "$o" || { no "snap"; exit 1; }
# (no loop variable: wsl.exe mangles an escaped `$k` on its way into bash -c)
wsl_ bash -c "umask 077; mkdir -p $WSLK && $TOOLS_WSL/provclient-amd64 keygen $WSLK/owner.pem > $WSLK/owner.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/enc.pem > $WSLK/enc.pub && $TOOLS_WSL/provclient-amd64 keygen $WSLK/attacker.pem > $WSLK/attacker.pub && stat -c '%a' $WSLK/owner.pem"
OWNER=$(wsl_ cat $WSLK/owner.pub | tr -d '\r'); ENC=$(wsl_ cat $WSLK/enc.pub | tr -d '\r'); ATK=$(wsl_ cat $WSLK/attacker.pub | tr -d '\r')
[ ${#OWNER} = 130 ] && [ ${#ENC} = 130 ] || { no "owner keys"; exit 1; }

# --- 2. provclient + probe onto the node: $PCD root 0711, files root 0755 / 0700, sha checked
scp -q $SSHO "$TOOLS/provclient-arm64" root@$NODE:/tmp/run/batman-dv/pc.$RUN.upload && scp -q $SSHO "$PROBE/cryptprobe-arm64" root@$NODE:/tmp/run/batman-dv/cp.$RUN.upload || { no "upload"; exit 1; }
PSHA=$(sha256sum < "$TOOLS/provclient-arm64" | cut -c1-64); CSHA=$(sha256sum < "$PROBE/cryptprobe-arm64" | cut -c1-64)
q "set -e; mkdir -m 0711 $PCD; mv /tmp/run/batman-dv/pc.$RUN.upload $PCD/provclient; mv /tmp/run/batman-dv/cp.$RUN.upload $PCD/cryptprobe; chown root:root $PCD $PCD/provclient $PCD/cryptprobe; chmod 0755 $PCD/provclient; chmod 0700 $PCD/cryptprobe; [ \"\$(sha256sum < $PCD/provclient | cut -c1-64)\" = $PSHA ] && [ \"\$(sha256sum < $PCD/cryptprobe | cut -c1-64)\" = $CSHA ] && echo PCOK" | grep -q PCOK && ok "provclient + cryptprobe placed ($PCD, sha checked)" || no "tool placement"
# pc <key> [ENV=v ...] -- <op> [args]: provclient on the node; its "SIGN …" lines go to the WSL signer (coproc); each
# "SIG …" answer goes back on the node's stdin through a FIFO; every other line is the op's output (secrets as sha only)
pc(){
	local key=$1; shift; local envs=""; while [ "$1" != -- ]; do envs="$envs $1"; shift; done; shift
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
	done < <(ssh $SSHO root@$NODE "$envs $PCD/provclient node $*" < "$f" 2>&1)
	exec {W}>&-; kill "$SIGNP_PID" 2>/dev/null; rm -rf "${f%/p}"   # stop the signer ({SIGNP[1]}>&- is not valid bash)
	printf '%s' "$out"
}
lockstate(){ q 'echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) lock=$(cat /opt/batdata/state/lock-status) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth) rootpw=$(uci -q get dropbear.@dropbear[0].RootPasswordAuth) tty=$(uci -q get system.@system[0].ttylogin) hash=$(grep ^root: /etc/shadow | cut -d: -f2 | cut -c1-3) lks=$(awk "NR==1 {print \$3}" /opt/batdata/state/prov-state) dbs=$(ubus call service list "{\"name\":\"dropbear\"}" | jsonfilter -e "@.dropbear.instances[*].command" | grep "\"-s\"" | grep -c "\"-g\"")"'; }
p5shadow(){ q 'd=$(mktemp -d /tmp/run/batman-dv/p5s.XXXXXX) && mount -o ro,noload /dev/mmcblk0p5 $d && { [ -s $d/identity/shadow-root ] && sha256sum < $d/identity/shadow-root | cut -c1-16 || echo none; [ -f $d/.seeded ] && echo seeded || echo unseeded; umount $d; }; rmdir $d'; }

# --- 3. negative first (state must not change): the buyer's response bound to the OWNER key, sent with the ATTACKER key
r=$(pc owner.pem -- claim-attacker "$ATK" "$ENC" "$OWNER"); echo "$r"
grep -q "RESULT claim.verify code=3 " <<< "$r" && ok "attacker owner_pub with the buyer's response -> E_FORBIDDEN" || no "attacker claim not refused: $r"
[ "$(q 'sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta')" = legacy ] && ok "state still legacy after the refused claim" || no "state changed by a refused claim"

# --- 4. the claim: locked, the returned password is the one in shadow, p5 seeded with it
r=$(pc owner.pem PROVCLIENT_PW_FILE=$PCD/pw.claim -- claim "$OWNER" "$ENC"); echo "$r"
grep -q "RESULT claim.verify code=0 " <<< "$r" && ok "claim.verify code 0" || no "claim failed: $r"
st=$(lockstate); say "after claim: $st"
for want in state=claimed lock=LOCKED " pw=off " rootpw=off tty=1 'hash=$6$' lks=claimed "dbs=1"; do case " $st" in *"$want"*) ok "claimed node: $want";; *) no "claimed node: want $want";; esac; done
m=$(offered); [ "$m" = publickey ] && ok "sshd offers only: $m" || no "sshd offers [$m] (want publickey only)"
timeout 30 ssh $NONEO root@$NODE 'echo NONEOK' 2>&1 | grep -q "Permission denied" && ok "port 22: none denied" || no "port 22: none not denied"
pk_proof && ok "publickey proven after the claim (L47)" || no "publickey lost after the claim"
c=$(probe $PCD/pw.claim); [ "$c" = MATCH ] && ok "musl crypt(): the claim's password matches shadow" || no "probe on the claim's password: [$c]"
c=$(q "printf 'not-the-password\n' > $PCD/pw.wrong; h=\$(grep '^root:' /etc/shadow | cut -d: -f2); $PCD/cryptprobe \"\$h\" < $PCD/pw.wrong"); [ "$c" = NOMATCH ] && ok "probe negative control: a wrong password -> NOMATCH" || no "probe negative control: [$c]"
p=$(p5shadow); say "p5: $(echo $p)"
lh=$(q "grep '^root:' /etc/shadow | sha256sum | cut -c1-16"); case "$(echo $p)" in "$lh seeded") ok "p5 seeded with the live root line (shadow-root == live)";; *) no "p5 shadow-root [$(echo $p)] != live [$lh] / not seeded";; esac
q 'd=$(mktemp -d /tmp/run/batman-dv/pg.XXXXXX); rmdir $d; batman-config-save --prov-get $d >/dev/null 2>&1; cmp -s $d/prov.meta /etc/batman-prov/prov.meta && echo P5SAME; rm -rf $d' | grep -q P5SAME && ok "p5 prov.meta == overlay after the claim" || no "p5 / overlay differ after the claim"

# --- 5. claim/replay: a NEW password, the old one stops matching, p5 follows
r=$(pc owner.pem PROVCLIENT_PW_FILE=$PCD/pw.replay -- replay "$OWNER"); echo "$r"
grep -q "RESULT claim.replay code=0 " <<< "$r" && ok "claim.replay code 0" || no "claim.replay: $r"
[ "$(probe $PCD/pw.replay)" = MATCH ] && ok "probe: the replay's password matches" || no "probe: the replay's password does not match"
[ "$(probe $PCD/pw.claim)" = NOMATCH ] && ok "probe: the claim's password no longer matches (rotated)" || no "claim password still matches after replay"
p2=$(p5shadow); [ "$(echo $p2 | cut -d' ' -f1)" != "$(echo $p | cut -d' ' -f1)" ] && ok "p5 shadow-root changed with the replay" || no "p5 shadow-root unchanged after the replay"
# --- 6. root_password/reset (owner-op)
r=$(pc owner.pem PROVCLIENT_PW_FILE=$PCD/pw.reset -- root-reset); echo "$r"
grep -q "RESULT root_password.reset code=0 " <<< "$r" && ok "root_password.reset code 0" || no "reset: $r"
[ "$(probe $PCD/pw.reset)" = MATCH ] && ok "probe: the reset's password matches" || no "probe: the reset's password does not match"
# --- 7. refusals
r=$(pc owner.pem -- claim "$OWNER" "$ENC"); grep -q "RESULT claim.verify code=3 " <<< "$r" && ok "re-claim of a claimed node -> E_FORBIDDEN" || no "re-claim: $r"
r=$(pc owner.pem -- rename); grep -q "code=6" <<< "$r" && ok "settings.set hostname -> E_UNSUPPORTED (P-U7)" || no "rename: $r"

# --- 8. no secret in any log or output: claim.secret and every password the helper returned (checked ON the node)
o=$(q "logread > $PCD/logread; cat /opt/batdata/log/*.log 2>/dev/null >> $PCD/logread; n=0; for f in $PCD/pw.claim $PCD/pw.replay $PCD/pw.reset; do [ -s \$f ] && grep -qF -f \$f $PCD/logread && n=\$((n + 1)); done; cs=\$(hexdump -v -e '/1 \"%02x\"' /etc/batman-prov/identity/claim.secret | cut -c1-16); grep -qi \"\$cs\" $PCD/logread && n=\$((n + 1)); echo leaks=\$n; echo cs=\$cs")
case "$o" in *"leaks=0"*) ok "no password / claim.secret in logread or p6 logs";; *) no "secret found in node logs: $o";; esac
cs=$(sed -n 's/^cs=//p' <<< "$o"); sync; [ -n "$cs" ] && ! grep -qi "$cs" "$RUNLOG" && ok "claim.secret not in this run's output" || no "claim.secret canary (run output)"

# --- 9. remove the passwords and the probe from the node (asserted)
q "rm -f $PCD/pw.* $PCD/logread $PCD/cryptprobe"
q "ls $PCD/pw.* $PCD/cryptprobe 2>/dev/null | wc -l" | grep -qx 0 && ok "passwords and probe removed from the node" || no "passwords / probe left on the node"

# --- 10. restore S0 (the node is LOCKED: publickey still works, proven above)
o=$(nb p5-restore "$RUN"); echo "$o" | tail -1; grep -q "^P5-RESTORED" <<< "$o" || no "p5 restore"
o=$(nb overlay-restore "$RUN"); echo "$o" | grep -E "EXTRA-REMOVED|OVERLAY" | tail -8; grep -q "^OVERLAY-RESTORED" <<< "$o" || no "overlay restore"
b0=$(bid); q "(batman-slot reboot committed prov-claim </dev/null >/dev/null 2>&1 &)"; waitboot "$b0" && settle || no "reboot after restore"
q "mkdir -p -m 0700 /tmp/run/batman-dv"; scp -q $SSHO "$H/tests/prov-p1/overlay-allow.txt" root@$NODE:/tmp/run/batman-dv/overlay-allow.txt
q "/etc/init.d/joinwatch stop >/dev/null 2>&1"
o=""; for _ in 1 2 3; do nb manifest "$RUN" after >/dev/null; o=$(nb compare "$RUN" after); grep -q "p5 unreadable" <<< "$o" || break; sleep 10; done
q "/etc/init.d/joinwatch start >/dev/null 2>&1"; echo "$o" | sed 's/^/    /' | tail -30
if grep -q "diffs=0" <<< "$o"; then ok "S0 restored (p5 / overlay / uci / identity / p6 state)"; nb finish "$RUN" | tail -1; else no "S0 not restored — snapshot and dirty flag kept"; fi
st=$(q 'echo "state=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta) lock=$(cat /opt/batdata/state/lock-status) pw=$(uci -q get dropbear.@dropbear[0].PasswordAuth)"'); say "after restore: $st"
case "$st" in *"state=legacy lock=UNPROVISIONED pw=on"*) ok "back to legacy / UNPROVISIONED / password auth on";; *) no "not back to legacy: $st";; esac
q "rm -rf $PCD"; wsl_ rm -rf "$WSLK"
say "fails=$fails"; rm -rf "$HT"; [ "$fails" = 0 ]
