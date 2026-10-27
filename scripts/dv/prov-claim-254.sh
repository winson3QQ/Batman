#!/bin/bash
# scripts/dv/prov-claim-254.sh — #254 tier B unit prov-claim (docs/design/254-p1-impl.md §5.3; claim-lock fix
# docs/design/254-claim-lock-fix.md §11.3): snap S0 -> claim a LEGACY node with provclient (owner keys generated per
# run on the WSL host, never on the node) -> assert the node is LOCKED and the password the helper returned is the one
# in shadow (musl crypt() probe ON the node; the password never leaves the node) -> claim/replay and
# root_password/reset rotate it -> attacker / re-claim / rename refused -> no secret in any log -> restore S0.
# Runs from Git Bash on the Windows host (key auth, LAN); the signer runs in WSL (owner key on ext4, 0600).
# On an image without the claim-lock fix (1.5.13) the lock / probe / replay assertions FAIL by design.
set -u
PL_NAME=prov-claim
# shellcheck source=scripts/dv/prov-lib-254.sh
. "$(dirname "$0")/prov-lib-254.sh"
pl_prep

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


pl_restore
pl_end
