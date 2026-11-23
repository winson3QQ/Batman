package main

// p3.go — the P3 verbs of the helper (docs/design/254-p3-impl.md v7.1 §3.1 table, §3.3–§3.5, §3.7.4, §3.8.2; 219-protocol.cddl
// for the shapes the helper mirrors). Written to the design's contract BEFORE the product: today's helper answers every
// verb here with code 6 / 20, and the product is made to match this client. Where the design leaves a wire detail open the
// simplest reading is taken and marked "⚠️ design:".
//
//	op (provclient node …)                helper verb      owner-op  body / args
//	settings-get <owner_pub>              settings.get     no        {}                       (ro)
//	settings-set <owner_pub> <key> <v…>   settings.set     yes       {key: value}             one key per call (§3.3)
//	status-get <owner_pub> [full|member] status.get       no        {1: full bool}           (ro; default full)
//	diag-summary <owner_pub>              diag.summary     no        {}                       (ro)
//	diag-bundle <owner_pub>               diag.bundle      yes       {1: session_id}          -> {1: handle} (P3 shape, §3.5)
//	diag-read <owner_pub> <handle-hex>    diag.read        no        {1: handle, 2: offset}   (ro; looped until total)
//	update-check <owner_pub> <manifest>   update.check     no        {1: bstr(manifest), 2: sha256(owner_pub)}
//	update-prepare <owner_pub> <sha-hex>  update.prepare   yes       {1: sha256(SHA256SUMS)}
//	update-apply <owner_pub> <sha-hex>    update.apply     yes       {1: sha256(SHA256SUMS)}
//	update-status <owner_pub>             update.status    no        {}                       (ro)
//	bulk-open <owner_pub> <sha-hex>       bulk.open        yes       {1: 0, 2: sha256(SHA256SUMS)}  purpose 0 = software update
//	bulk-close <owner_pub>                bulk.close       yes       {}
//
// Owner-ops are wrapped exactly as the P2 verbs (cl.ownerOp: envelope type = protocol msg-type, key 31; the helper gets
// {1: h, 2: envelope}). <owner_pub> is accepted (hex) on every op for a uniform CLI — the signer on the host holds the key.
//
// settings.set key 20 (phone-AP SSID + passphrase) comes in on fd 3 ("ssid=…" / "psk=…" lines, read as root before the
// privilege drop, like net.go's fd 3), never argv. Output never contains the passphrase, nor anything derived from it
// (254-v16-ud.md §3.1: "present" only, no hash prefix).
//
// reason: the helper's error replies carry an optional reason-code at KEY 1 of the result map (node.go errBody:
// {1: reason}); printed as "reason=<n>" whenever present (until 254-v16-ud §0.1-7 this read key 2 and never printed it).
//
// PROVCLIENT_SIGN_ARGS_SHA=<64 hex> (update-prepare / update-apply only; UD20's negative arm): the owner-op is signed
// over args_hash({1: that sha}) while the body carries the argv sha; the line shows signed-for=<16 hex>. Any other value,
// or the variable set on another op, is fatal.

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// p3NeedsFd3: ops whose values arrive on fd 3 (read before the drop; cmdNode)
func p3NeedsFd3(op string, args []string) bool {
	return op == "settings-set" && len(args) >= 3 && args[2] == "20"
}

// readFd3KV reads "key=value" lines from fd 3 (<= 4 KiB) into a map; dies when fd 3 is not open.
func readFd3KV() map[string]string {
	f := os.NewFile(3, "fd3")
	if f == nil {
		die("p3: fd 3 is not open (ssid= / psk=)")
	}
	b, err := io.ReadAll(io.LimitReader(f, 4096))
	f.Close()
	if err != nil {
		die("p3: fd 3: %v", err)
	}
	return parseKV(string(b))
}

func parseKV(s string) map[string]string {
	m := map[string]string{}
	for _, l := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(strings.TrimRight(l, "\r"), "=")
		if ok {
			m[k] = v
		}
	}
	return m
}

// settingsSetBody builds the settings.set body (one key, §3.3) from the argv value(s) / the fd 3 values:
//
//	1  <name>                 tstr
//	2  <CC>                   tstr (country)
//	10 <channel> [bw]         {1: uint, ? 2: uint}     (halow-settings; the helper answers E_UNSUPPORTED reason 7)
//	11 <talkgroup>            {1: uint}                (ptt-settings)
//	12 true|false             {1: bool}                (gps-settings)
//	13 <short name>           {1: tstr}                (lora-settings)
//	20 (fd 3: ssid=, psk=)    {1: ssid, 2: passphrase} ⚠️ design: §3.3 gives settings.get key 20 = {1: ssid}; the set shape
//	                                                   is not written down — {1: ssid, 2: passphrase} is the simplest reading
func settingsSetBody(key string, vals []string, fd3 map[string]string) (cmap, error) {
	k, err := strconv.ParseUint(key, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("settings-set: key %q is not a uint", key)
	}
	need := func(n int) error {
		if len(vals) < n {
			return fmt.Errorf("settings-set key %d: %d value(s) needed", k, n)
		}
		return nil
	}
	switch k {
	case 1, 2:
		if err := need(1); err != nil {
			return nil, err
		}
		return cmap{{k, vals[0]}}, nil
	case 10:
		if err := need(1); err != nil {
			return nil, err
		}
		ch, err := strconv.ParseUint(vals[0], 10, 32)
		if err != nil {
			return nil, fmt.Errorf("settings-set key 10: channel %q", vals[0])
		}
		sub := cmap{{uint64(1), ch}}
		if len(vals) > 1 {
			bw, err := strconv.ParseUint(vals[1], 10, 32)
			if err != nil {
				return nil, fmt.Errorf("settings-set key 10: bw %q", vals[1])
			}
			sub = append(sub, kv{uint64(2), bw})
		}
		return cmap{{k, sub}}, nil
	case 11:
		if err := need(1); err != nil {
			return nil, err
		}
		tg, err := strconv.ParseUint(vals[0], 10, 32)
		if err != nil {
			return nil, fmt.Errorf("settings-set key 11: talk group %q", vals[0])
		}
		return cmap{{k, cmap{{uint64(1), tg}}}}, nil
	case 12:
		if err := need(1); err != nil {
			return nil, err
		}
		b, err := strconv.ParseBool(vals[0])
		if err != nil {
			return nil, fmt.Errorf("settings-set key 12: %q is not a bool", vals[0])
		}
		return cmap{{k, cmap{{uint64(1), b}}}}, nil
	case 13:
		if err := need(1); err != nil {
			return nil, err
		}
		return cmap{{k, cmap{{uint64(1), vals[0]}}}}, nil
	case 20:
		if len(vals) != 0 {
			return nil, fmt.Errorf("settings-set key 20: the SSID / passphrase come on fd 3, never argv")
		}
		ssid, psk := fd3["ssid"], fd3["psk"]
		if ssid == "" || psk == "" {
			return nil, fmt.Errorf("settings-set key 20: fd 3 lacks ssid= / psk=")
		}
		return cmap{{k, cmap{{uint64(1), ssid}, {uint64(2), psk}}}}, nil
	}
	return nil, fmt.Errorf("settings-set: key %d is not one of 1, 2, 10–13, 20", k)
}

// updateCheckBody: the helper's update.check {1: manifest BYTES, 2: owner key id} — what provd sends it
// (provd/update.go: the session's update-check-req {1: update-manifest map} is re-encoded and passed as a bstr, with
// kid = sha256(owner pub), server.go ownerKID). The manifest must decode as one CBOR map. The pre-UD client sent the map
// itself and no key 2: bytesArg(a, 1, 0) refused it first, ESchema 20 "arg 1: want 0 bytes" (update.go; found by
// tests/tools/provclient-helpercheck, 254-v16-ud §0.1-1 named only the missing key 2).
func updateCheckBody(manifest, ownerPub []byte) (cmap, error) {
	x, rest, err := cDec(manifest)
	if _, ok := x.(cmap); err != nil || !ok || len(rest) != 0 {
		return nil, fmt.Errorf("update-check: the manifest is not one encoded CBOR map")
	}
	if len(ownerPub) == 0 {
		return nil, fmt.Errorf("update-check: no owner key")
	}
	return cmap{{uint64(1), append([]byte(nil), manifest...)}, {uint64(2), sha(ownerPub)}}, nil
}

// bulkOpenBody: bulk.open {1: purpose 0, 2: sha256(SHA256SUMS)} (bulk.go:42-51 requires key 2, 32 bytes)
func bulkOpenBody(sum []byte) (cmap, error) {
	if len(sum) != 32 {
		return nil, fmt.Errorf("bulk-open: sha must be 32 bytes")
	}
	return cmap{{uint64(1), uint64(0)}, {uint64(2), sum}}, nil
}

// reasonOf: the optional reason-code of a helper ERROR reply: result key 1 when it is a uint (node.go errBody)
func reasonOf(r cmap) (uint64, bool) {
	v, ok := r.get(1).(uint64)
	return v, ok
}

// fmtUpdateCheck renders an OK update.check reply, update-check-resp {1: ok bool, ? 2: reason uint, 3: RAM}: a refusal
// is an OK reply {1: false, 2: reason, 3: RAM} (feed/batman-prov/src/node/update.go:270, passed through by provd,
// provd/update.go:47), so its reason is key 2. Key 1 is the bool here: reasonOf (key 1) is for ERROR bodies only.
func fmtUpdateCheck(r cmap) string {
	s := fmt.Sprintf(" ok=%v ram=%v", r.get(1), r.get(3))
	if rs, ok := r.get(2).(uint64); ok {
		s += fmt.Sprintf(" reason=%d", rs)
	}
	return s
}

// signArgsOverride: PROVCLIENT_SIGN_ARGS_SHA for update-prepare / update-apply (nil when unset); fatal otherwise
func signArgsOverride(op string) []byte {
	v, set := os.LookupEnv("PROVCLIENT_SIGN_ARGS_SHA")
	if !set {
		return nil
	}
	if op != "update-prepare" && op != "update-apply" {
		die("PROVCLIENT_SIGN_ARGS_SHA is only for update-prepare / update-apply, not %s", op)
	}
	b, err := hex.DecodeString(v)
	if err != nil || len(b) != 32 {
		die("PROVCLIENT_SIGN_ARGS_SHA=%q: want 64 hex", v)
	}
	return b
}

// resultLine formats "RESULT <verb> code=<n>[ reason=<r>]<extra>" — extra already starts with a space or is empty.
func resultLine(verb string, code uint64, r cmap, extra string) string {
	s := fmt.Sprintf("RESULT %s code=%d", verb, code)
	if code != 0 {
		if rs, ok := reasonOf(r); ok {
			s += fmt.Sprintf(" reason=%d", rs)
		}
	}
	return s + extra
}

// fmtSettings renders a `settings` map (CDDL): plain for name / country / numbers / the SSID (not a secret: it is on
// the air, §3.11-6); any other string under key 20 prints only "k20.<n>=present" (a passphrase must never be printed,
// nor a hash of it — the helper is not supposed to return it, and this client does not trust that).
func fmtSettings(r cmap) string {
	if r == nil {
		return ""
	}
	var keys []int
	for _, e := range r {
		if k, ok := e.k.(uint64); ok {
			keys = append(keys, int(k))
		}
	}
	sort.Ints(keys)
	ks := make([]string, 0, len(keys))
	for _, k := range keys {
		ks = append(ks, strconv.Itoa(k))
	}
	out := " keys=" + strings.Join(ks, ",")
	for _, k := range keys {
		v := r.get(uint64(k))
		switch k {
		case 1:
			out += fmt.Sprintf(" name=%q", str(v))
		case 2:
			out += fmt.Sprintf(" country=%q", str(v))
		case 10:
			if m, ok := v.(cmap); ok {
				out += fmt.Sprintf(" halow=%v/%v", m.get(1), m.get(2))
			}
		case 11, 12, 13:
			if m, ok := v.(cmap); ok {
				out += fmt.Sprintf(" k%d=%v", k, m.get(1))
			}
		case 20:
			if m, ok := v.(cmap); ok {
				out += fmt.Sprintf(" ssid=%q", str(m.get(1)))
				for _, e := range m {
					if e.k == uint64(1) {
						continue
					}
					if _, ok := e.v.(string); ok { // anything else string-valued under key 20 is treated as a secret
						out += fmt.Sprintf(" k20.%v=present", e.k)
					}
				}
			}
		}
	}
	return out
}

func str(v any) string { s, _ := v.(string); return s }

// ifOK: the body rendering only on code 0 (an error reply has an empty / reason-only result)
func ifOK(code uint64, s string) string {
	if code != 0 {
		return ""
	}
	return s
}

// fmtProgress renders update-progress {1 phase, 2 percent, ? 3 reason, ? 4 sha, ? 5 version} (updwork.go progress):
// sha = the first 16 hex of key 4 (sha256(SHA256SUMS), not a secret); a version outside the version charset prints "?"
func fmtProgress(r cmap) string {
	if r == nil {
		return ""
	}
	s := fmt.Sprintf(" phase=%v percent=%v", r.get(1), r.get(2))
	if fr, ok := r.get(3).(uint64); ok {
		s += fmt.Sprintf(" fail_reason=%d", fr)
	}
	if b, ok := r.get(4).([]byte); ok && len(b) == 32 {
		s += " sha=" + hex.EncodeToString(b)[:16]
	}
	if v, ok := r.get(5).(string); ok && v != "" {
		if !reVersion.MatchString(v) {
			v = "?"
		}
		s += " version=" + v
	}
	return s
}

var reVersion = regexp.MustCompile(`^[0-9A-Za-z.+-]{1,80}$`)

// fmtBulkOpen renders bulk-open-resp {1 ssid, 2 passphrase, 3 ip, 4 port, 5 expires, 6 bearer}: nothing from keys 2 / 6
func fmtBulkOpen(r cmap) string {
	if r == nil {
		return ""
	}
	return fmt.Sprintf(" ssid=%q ip=%q port=%v expires=%v", str(r.get(1)), str(r.get(3)), r.get(4), r.get(5))
}

// fmtStatus renders status-resp (keys 1–6, 15 as the sorted names of its tstr keys; values of 15 are not printed)
func fmtStatus(r cmap) string {
	if r == nil {
		return ""
	}
	s := fmt.Sprintf(" state=%v verdict=%v neighbours=%v p5_saved=%v", r.get(1), r.get(2), r.get(3), r.get(4))
	if jf, ok := r.get(5).(cmap); ok {
		s += fmt.Sprintf(" join_failure=%v", jf.get(1))
	}
	if m, ok := r.get(15).(cmap); ok {
		var names []string
		for _, e := range m {
			if n, ok := e.k.(string); ok {
				names = append(names, n)
			}
		}
		sort.Strings(names)
		s += " f15=" + strings.Join(names, ",")
		// key 15 "trust" (#254 S5, 254-p3-impl §3.7.1): the image's root key — "none", "bad" or 16 hex (the
		// fingerprint's first 8 bytes); its value is printed (prov-update-254 UD-T1 reads it), anything else as "?"
		for _, e := range m {
			if k, _ := e.k.(string); k == "trust" {
				v, _ := e.v.(string)
				if !reTrust.MatchString(v) {
					v = "?"
				}
				s += " trust=" + v
			}
		}
	}
	// whole-team status (254-app-team-status §4.1): key 8 = this node's mesh address, key 9 = the peers it sees; bytes =
	// the answer's CBOR size (§4.2: one provd reply is 8192 B). Absent keys print "-". Last on the line: older readers keep
	// their fields where they were.
	s += fmt.Sprintf(" self=%s peers=%s bytes=%d", macOrDash(r.get(8)), peerList(r.get(9)), len(cEnc(r)))
	return s
}

var reTrust = regexp.MustCompile(`^(none|bad|[0-9a-f]{16})$`)

// fmtDiagSummary renders diag-summary-resp {1: [* diag-item]} as "n=<count> items=id:level,…"
func fmtDiagSummary(r cmap) string {
	if r == nil {
		return ""
	}
	items, _ := r.get(1).([]any)
	var parts []string
	for _, it := range items {
		if m, ok := it.(cmap); ok {
			parts = append(parts, fmt.Sprintf("%s:%v", str(m.get(1)), m.get(2)))
		}
	}
	return fmt.Sprintf(" n=%d items=%s", len(items), strings.Join(parts, ","))
}

// p3Op runs one P3 op of cmdNode; false for an op it does not know. fd3 is the key=value map read before the drop
// (nil unless p3NeedsFd3).
func p3Op(cl *client, op string, args []string, fd3 map[string]string, hexArg func(int) []byte) bool {
	switch op {
	case "settings-get":
		hexArg(1)
		code, r := cl.call("settings.get", cmap{})
		fmt.Println(resultLine("settings.get", code, r, ifOK(code, fmtSettings(r))))
	case "settings-set":
		hexArg(1)
		if len(args) < 3 {
			die("usage: settings-set <owner_pub> <key> <value…>   (key 20: ssid= / psk= on fd 3)")
		}
		body, err := settingsSetBody(args[2], args[3:], fd3)
		if err != nil {
			die("%v", err)
		}
		env := cl.ownerOp("settings/set", body)
		code, r := cl.call("settings.set", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Println(resultLine("settings.set(key "+args[2]+")", code, r, ifOK(code, fmtSettings(r))))
	case "status-get":
		hexArg(1)
		opt := ""
		if len(args) > 2 {
			opt = args[2]
		}
		body, err := statusGetBody(opt)
		if err != nil {
			die("%v", err)
		}
		code, r := cl.call("status.get", body)
		fmt.Println(resultLine(fmt.Sprintf("status.get(full %v)", body.get(1)), code, r, ifOK(code, fmtStatus(r))))
	case "diag-summary":
		hexArg(1)
		code, r := cl.call("diag.summary", cmap{})
		fmt.Println(resultLine("diag.summary", code, r, ifOK(code, fmtDiagSummary(r))))
	case "diag-bundle": // P3 diag.bundle: {1: session id} in the body, background tar.gz, returns {1: handle} (§3.5)
		// ⚠️ design: the session id's type is not written down; a random 32-byte bstr here (provd's choice in the product).
		// ⚠️ design: the handle's type is not written down; printed with %x and taken back as hex by diag-read.
		hexArg(1)
		sid := make([]byte, 32)
		rand.Read(sid)
		env := cl.ownerOp("diag/bundle", cmap{{uint64(1), sid}})
		code, r := cl.call("diag.bundle", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Println(resultLine("diag.bundle(p3)", code, r, ifOK(code, fmt.Sprintf(" handle=%s", handleHex(r.get(1))))))
	case "diag-read": // diag.read {1: handle, 2: offset} -> {1: total (0 = not finished), 2: chunk <= 48 KiB}; looped
		hexArg(1)
		handle := hexArg(2)
		var all []byte
		var total uint64
		var code uint64
		var r cmap
		for {
			code, r = cl.call("diag.read", cmap{{uint64(1), handle}, {uint64(2), uint64(len(all))}})
			if code != 0 {
				break
			}
			total, _ = r.get(1).(uint64)
			chunk, _ := r.get(2).([]byte)
			all = append(all, chunk...)
			if total == 0 || uint64(len(all)) >= total || len(chunk) == 0 {
				break
			}
		}
		// diag-read <pub> <handle> [<out file>]: the bytes stay on the node for the unit's own checks (tar listing, a
		// grep of the real secret values) - written after the privilege drop, so the file's directory must be the
		// drop uid's (the unit makes $PCD/out 471:471 0700)
		if len(args) > 3 {
			if err := os.WriteFile(args[3], all, 0o600); err != nil {
				die("diag-read: write %s: %v", args[3], err)
			}
		}
		fmt.Println(resultLine("diag.read", code, r, fmt.Sprintf(" total=%d bytes=%d sha=%s", total, len(all), short(all))))
	case "update-check":
		body, err := updateCheckBody(hexArg(2), hexArg(1))
		if err != nil {
			die("%v", err)
		}
		code, r := cl.call("update.check", body)
		extra := ""
		if code == 0 && r != nil {
			extra = fmtUpdateCheck(r)
		}
		fmt.Println(resultLine("update.check", code, r, extra))
	case "update-prepare", "update-apply":
		hexArg(1)
		sum := hexArg(2)
		if len(sum) != 32 {
			die("%s: sha must be 32 bytes", op)
		}
		typ, verb := "update/prepare", "update.prepare"
		if op == "update-apply" {
			typ, verb = "update/apply", "update.apply"
		}
		body := cmap{{uint64(1), sum}}
		extra := ""
		var env []byte
		if over := signArgsOverride(op); over != nil {
			env = cl.ownerOpSigned(typ, body, cmap{{uint64(1), over}})
			extra = " signed-for=" + hex.EncodeToString(over)[:16]
		} else {
			env = cl.ownerOp(typ, body)
		}
		code, r := cl.call(verb, cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Println(resultLine(verb, code, r, ifOK(code, fmtProgress(r))+extra))
	case "update-status":
		hexArg(1)
		code, r := cl.call("update.status", cmap{})
		fmt.Println(resultLine("update.status", code, r, ifOK(code, fmtProgress(r))))
	case "bulk-open":
		hexArg(1)
		body, err := bulkOpenBody(hexArg(2))
		if err != nil {
			die("%v", err)
		}
		env := cl.ownerOp("bulk/open", body)
		code, r := cl.call("bulk.open", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Println(resultLine("bulk.open", code, r, ifOK(code, fmtBulkOpen(r))))
	case "bulk-close":
		hexArg(1)
		env := cl.ownerOp("bulk/close", cmap{})
		code, r := cl.call("bulk.close", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Println(resultLine("bulk.close", code, r, ""))
	default:
		return false
	}
	return true
}

// handleHex: a diag handle as hex, whatever its CBOR type (bstr / tstr / uint)
func handleHex(v any) string {
	switch x := v.(type) {
	case []byte:
		return hex.EncodeToString(x)
	case string:
		return hex.EncodeToString([]byte(x))
	case uint64:
		return fmt.Sprintf("%x", x)
	}
	return ""
}

// macOrDash: a 6-byte bstr as aa:bb:..., anything else "-"
func macOrDash(v any) string {
	b, ok := v.([]byte)
	if !ok || len(b) != 6 {
		return "-"
	}
	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5])
}

// peerList: key 9 [* {1: addr (6 B), 2: seen-ago s (uint), ...}] as "addr/ago,..." (sorted); "-" when key 9 is absent,
// "none" when empty, "bad" when it breaks 254-app-team-status §4.1 (not a list, > 32 entries, an entry that is not a map,
// an address that is not 6 bytes, a seen-ago that is not a uint) — the app drops the whole key 9 then
func peerList(v any) string {
	if v == nil {
		return "-"
	}
	l, ok := v.([]any)
	if !ok || len(l) > 32 {
		return "bad"
	}
	var out []string
	for _, e := range l {
		m, ok := e.(cmap)
		if !ok {
			return "bad"
		}
		a := macOrDash(m.get(1))
		ago, ok := m.get(2).(uint64)
		if a == "-" || !ok {
			return "bad"
		}
		out = append(out, fmt.Sprintf("%s/%d", a, ago))
	}
	if len(out) == 0 {
		return "none"
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

// statusGetBody: status.get's request {1: full} — a bool (node/status.go: a non-bool key 1 is ESchema 20; until
// 2026-11-13 this sent the uint 0 and every status-get FAILed with code 20 on every P3 node). "" / "full" -> true,
// "member" -> false, anything else is refused.
func statusGetBody(opt string) (cmap, error) {
	switch opt {
	case "", "full":
		return cmap{{uint64(1), true}}, nil
	case "member":
		return cmap{{uint64(1), false}}, nil
	}
	return nil, fmt.Errorf("status-get: [full|member], not %q", opt)
}
