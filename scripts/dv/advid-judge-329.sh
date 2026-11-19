# shellcheck shell=bash
# scripts/dv/advid-judge-329.sh — #329 rotating identifier (docs/design/329-rotating-id-plan.md §8, D1): a claimed node
# registers its advertisement with one Manufacturer Data AD (company 0xFFFF, 6 B = nonce || tag), a new one at every
# registration, and what the controller is given is what provd registered. Sourced by prov-provd-254.sh (unit rpa).
# No node access in here: aj_judge reads text on stdin, so scripts/test-dv-ble-254.sh runs it offline.
#
# aj_judge <BATMAN_VERSION> <prov state>
#   stdin, in this order:
#     04's provd lines after the unit's log mark, as logread prints them
#       ("Sun Jul 27 22:44:15 2025 daemon.info batman-provd[1234]: provd: adv field id=1"
#        "... provd: adv registered reason=start");
#     the btmon -t text of the same span, cut down to the MGMT Add Extended Advertising Data (0x0055) command blocks
#     and the HCI LE Set (Extended) Advertising Data (0x08|0x0008, 0x08|0x0037) command blocks: the header line and
#     its indented lines.
#   stdout: "PASS ..." / "FAIL ..." lines, whole (the caller adds only the unit name).
#   An image without the field prints exactly one line, "FAIL no adv field line on 04 (<version>): an image without
#   the field", and nothing else: the known-failures entry matches that line.
#   The log has whole seconds, btmon microseconds: a registration's payload is the last 0x0055 block whose time is at
#   most 1 s after the line's second. A run that crosses midnight is handled (+86400).
aj_judge(){
	awk -v ver="$1" -v st="$2" '
	function sec(t,   f) { split(t, f, ":"); return f[1] * 3600 + f[2] * 60 + f[3] }
	# seconds since the first time seen; a time more than 12 h "before" it is the next day
	function rel(t,   s) { s = sec(t); if (!hb) { base = s; hb = 1 }; s -= base; if (s < -43200) s += 86400; return s }
	function fail(m) { print "FAIL adv id: " m; nf++ }
	function close_blk() {
		if (cur == "M") { nM++; MT[nM] = bt; ML[nM] = blen; MN[nM] = bm; MO[nM] = bo; MD[nM] = bd; lastd = bd; lastn = bm }
		if (cur == "H") { nH++; HT[nH] = bt; HL[nH] = blen; HN[nH] = bm; HO[nH] = bo; HD[nH] = bd; HF[nH] = bfl; HU[nH] = bu; HW[nH] = lastd; HWN[nH] = lastn }
		cur = ""
	}
	function open_blk(k,   t) {
		cur = k; blen = ""; bm = 0; bo = 0; bd = ""; bfl = 0; bu = 0; co = 0
		t = $0; bt = "?"
		if (match(t, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+[ \t]*$/)) bt = substr(t, RSTART, 8)
	}
	/batman-provd\[[0-9]+\]: provd: adv field / { close_blk(); nF++; f = $0; sub(/.*provd: adv field /, "", f); curf = f; next }
	/batman-provd\[[0-9]+\]: provd: adv registered reason=/ { close_blk(); nR++; GT[nR] = $4; GW[nR] = $NF; sub(/.*reason=/, "", GW[nR]); GF[nR] = curf; curf = ""; next }
	/^[@<>=]/ {
		close_blk()
		if ($0 ~ /^@/ && $0 ~ /MGMT Command/ && $0 ~ /\(0x0055\)/) open_blk("M")
		else if ($0 ~ /^</ && $0 ~ /0x08\|0x00(08|37)/) open_blk("H")
		next
	}
	cur != "" {
		l = $0
		if (blen == "" && l ~ /(Advertising data length|Data length|Length): /) { blen = l; sub(/.*: /, "", blen); sub(/[ \t]+$/, "", blen); if (blen ~ /^0x/) blen = hex(blen) }
		if (l ~ /Flags: 0x/) bfl = 1
		if (l ~ /128-bit Service UUID/) bu = 1
		if (l ~ /Company: /) { if (l ~ /\(65535\)[ \t]*$/) { bm++; co = 1 } else { bo++; co = 0 } }
		else if (co && l ~ /Data(\[[0-9]+\])?: [0-9a-f ]+$/) { d = l; sub(/.*: /, "", d); gsub(/ /, "", d); bd = bd (bd == "" ? "" : ",") d; co = 0 }
	}
	function hex(s,   i, c, v) { v = 0; s = tolower(substr(s, 3)); for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)); if (!c) break; v = v * 16 + c - 1 }; return v }
	END {
		close_blk()
		if (nM == 0 || nR == 0) { fail("nothing captured"); exit }
		if (st != "claimed" && st != "member") { fail("node is " (st == "" ? "?" : st) ", nothing to check"); exit }
		if (nF == 0) { print "FAIL no adv field line on 04 (" ver "): an image without the field"; exit }
		# every registration was made with the field
		for (i = 1; i <= nR; i++) {
			if (GF[i] == "") fail("the registration at " GT[i] " (reason=" GW[i] ") has no adv field line before it")
			else if (GF[i] != "id=1") fail("the registration at " GT[i] " (reason=" GW[i] ") was made without the identifier [" GF[i] "]")
		}
		if (!nf) print "PASS adv id: " nR " registration(s), each logged id=1"
		# what provd handed to BlueZ
		b = nf
		for (i = 1; i <= nM; i++) {
			if (ML[i] != 31) fail("the 0x0055 block at " MT[i] " has advertising data length [" ML[i] "] (want 31)")
			if (MN[i] != 1 || MO[i] != 0) fail("the 0x0055 block at " MT[i] " has " MN[i] " Manufacturer AD(s) of company 0xFFFF and " MO[i] " of another company (want 1 and 0)")
			else if (length(MD[i]) != 12) fail("the 0x0055 block at " MT[i] " has a Manufacturer AD of " length(MD[i]) / 2 " B after the company id (want 6)")
		}
		if (nf == b) print "PASS adv id: " nM " MGMT Add Extended Advertising Data block(s), each 31 B with one 6 B Manufacturer AD of company 0xFFFF"
		# a new identifier at every registration
		b = nf; prev = 0
		for (i = 1; i <= nR; i++) {
			r = rel(GT[i]); p = 0
			for (k = 1; k <= nM; k++) if (MT[k] != "?" && rel(MT[k]) <= r + 1) p = k
			if (p <= prev) { fail("the registration at " GT[i] " (reason=" GW[i] ") has no 0x0055 block of its own"); continue }
			prev = p; PD[i] = MD[p]
			for (k = 1; k < i; k++) if (PD[k] != "" && PD[k] == PD[i]) fail("the registrations at " GT[k] " and " GT[i] " carry the same identifier")
		}
		if (nf == b) print "PASS adv id: " nR " registration(s), " nR " different identifier(s)"
		# what the controller was given
		b = nf
		if (nH == 0) fail("no HCI LE Set (Extended) Advertising Data command in the capture")
		for (i = 1; i <= nH; i++) {
			if (HL[i] != 31) fail("the HCI advertising data at " HT[i] " has length [" HL[i] "] (want 31)")
			if (!HF[i]) fail("the HCI advertising data at " HT[i] " has no Flags AD")
			if (!HU[i]) fail("the HCI advertising data at " HT[i] " has no 128-bit UUID list")
			if (HN[i] != 1 || HO[i] != 0) fail("the HCI advertising data at " HT[i] " has " HN[i] " Manufacturer AD(s) of company 0xFFFF and " HO[i] " of another company (want 1 and 0)")
			else if (HWN[i] != 1 || HD[i] != HW[i]) fail("the HCI advertising data at " HT[i] " does not carry the identifier of the 0x0055 block before it")
		}
		if (nf == b) print "PASS adv id: " nH " HCI advertising-data command(s), each 31 B: Flags, the UUID list and the registered identifier"
	}'
}
# aj_keep: the awk program (one line, busybox awk) that cuts a btmon text down to the blocks aj_judge reads
# shellcheck disable=SC2034,SC2016  # used by prov-provd-254.sh, run on the node
AJ_KEEP='/^[@<>=]/ {k = (($0 ~ /^@/ && $0 ~ /MGMT Command/ && $0 ~ /\(0x0055\)/) || ($0 ~ /^</ && $0 ~ /0x08\|0x00(08|37)/))} k'
