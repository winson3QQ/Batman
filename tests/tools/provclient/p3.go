package main

// p3.go — the P3 verbs of the helper (docs/design/254-p3-impl.md v7.1 §3.1 table, §3.3–§3.5, §3.7.4, §3.8.2; 219-protocol.cddl
// for the shapes the helper mirrors). Written to the design's contract BEFORE the product: today's helper answers every
// verb here with code 6 / 20, and the product is made to match this client. Where the design leaves a wire detail open the
// simplest reading is taken and marked "⚠️ design:".
//
//	op (provclient node …)                helper verb      owner-op  body / args
//	settings-get <owner_pub>              settings.get     no        {}                       (ro)
//	settings-set <owner_pub> <key> <v…>   settings.set     yes       {key: value}             one key per call (§3.3)
//	status-get <owner_pub> [scope]        status.get       no        {1: scope}               (ro; scope default 0 = self)
//	diag-summary <owner_pub>              diag.summary     no        {}                       (ro)
//	diag-bundle <owner_pub>               diag.bundle      yes       {1: session_id}          -> {1: handle} (P3 shape, §3.5)
//	diag-read <owner_pub> <handle-hex>    diag.read        no        {1: handle, 2: offset}   (ro; looped until total)
//	update-check <owner_pub> <manifest>   update.check     no        {1: update-manifest}     manifest = encoded CBOR map, hex
//	update-prepare <owner_pub> <sha-hex>  update.prepare   yes       {1: sha256(SHA256SUMS)}
//	update-apply <owner_pub> <sha-hex>    update.apply     yes       {1: sha256(SHA256SUMS)}
//	update-status <owner_pub>             update.status    no        {}                       (ro)
//	bulk-open <owner_pub>                 bulk.open        yes       {1: 0}                   purpose 0 = software update
//	bulk-close <owner_pub>                bulk.close       yes       {}
//
// Owner-ops are wrapped exactly as the P2 verbs (cl.ownerOp: envelope type = protocol msg-type, key 31; the helper gets
// {1: h, 2: envelope}). <owner_pub> is accepted (hex) on every op for a uniform CLI — the signer on the host holds the key.
//
// settings.set key 20 (phone-AP SSID + passphrase) comes in on fd 3 ("ssid=…" / "psk=…" lines, read as root before the
// privilege drop, like net.go's fd 3), never argv. Output never contains the passphrase: its SHA-256 prefix only.
//
// reason: the helper's error replies carry an optional reason-code (§3.1.8, §5.3 "helper 錯誤回覆 reason").
// ⚠️ design: its place in the helper response is not pinned; read here as key 2 of the result map (key 3), mirroring the
// protocol's error-detail {2 => reason-code} — the response envelope {1 id, 2 code, 3 result} stays as it is. Printed as
// "reason=<n>" whenever present.

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

// updateCheckBody: update.check {1: update-manifest}; the manifest is handed over as its encoded CBOR map (must decode).
func updateCheckBody(manifest []byte) (cmap, error) {
	x, rest, err := cDec(manifest)
	if _, ok := x.(cmap); err != nil || !ok || len(rest) != 0 {
		return nil, fmt.Errorf("update-check: the manifest is not one encoded CBOR map")
	}
	return cmap{{uint64(1), rawCBOR(manifest)}}, nil
}

// reasonOf: the optional reason-code of a helper reply (see the header): result key 2 when it is a uint
func reasonOf(r cmap) (uint64, bool) {
	v, ok := r.get(2).(uint64)
	return v, ok
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
// the air, §3.11-6), SHA-256 prefix for any string under key 20 other than the SSID (a passphrase must never be printed —
// the helper is not supposed to return it, and this client does not trust that).
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
					if s, ok := e.v.(string); ok { // anything else string-valued under key 20 is treated as a secret
						out += fmt.Sprintf(" k20.%v_sha=%s", e.k, short([]byte(s)))
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

// fmtProgress renders update-progress {1 phase, 2 percent, ? 3 reason}
func fmtProgress(r cmap) string {
	if r == nil {
		return ""
	}
	s := fmt.Sprintf(" phase=%v percent=%v", r.get(1), r.get(2))
	if fr, ok := r.get(3).(uint64); ok {
		s += fmt.Sprintf(" fail_reason=%d", fr)
	}
	return s
}

// fmtBulkOpen renders bulk-open-resp {1 ssid, 2 passphrase, 3 ip, 4 port, 5 expires}: the passphrase as a sha prefix
func fmtBulkOpen(r cmap) string {
	if r == nil {
		return ""
	}
	return fmt.Sprintf(" ssid=%q psk_sha=%s ip=%q port=%v expires=%v", str(r.get(1)), short([]byte(str(r.get(2)))), str(r.get(3)), r.get(4), r.get(5))
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
	case "status-get": // ⚠️ design: status.get's args are not written down; {1: scope} mirrors status-req
		hexArg(1)
		scope := uint64(0)
		if len(args) > 2 {
			v, err := strconv.ParseUint(args[2], 10, 8)
			if err != nil {
				die("status-get: scope %q", args[2])
			}
			scope = v
		}
		code, r := cl.call("status.get", cmap{{uint64(1), scope}})
		fmt.Println(resultLine(fmt.Sprintf("status.get(scope %d)", scope), code, r, ifOK(code, fmtStatus(r))))
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
		hexArg(1)
		body, err := updateCheckBody(hexArg(2))
		if err != nil {
			die("%v", err)
		}
		code, r := cl.call("update.check", body)
		extra := ""
		if code == 0 && r != nil { // update-check-resp {1 ok, ? 2 reason, 3 RAM}
			extra = fmt.Sprintf(" ok=%v ram=%v", r.get(1), r.get(3))
			if rs, ok := reasonOf(r); ok {
				extra += fmt.Sprintf(" reason=%d", rs)
			}
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
		env := cl.ownerOp(typ, cmap{{uint64(1), sum}})
		code, r := cl.call(verb, cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Println(resultLine(verb, code, r, ifOK(code, fmtProgress(r))))
	case "update-status":
		hexArg(1)
		code, r := cl.call("update.status", cmap{})
		fmt.Println(resultLine("update.status", code, r, ifOK(code, fmtProgress(r))))
	case "bulk-open":
		hexArg(1)
		env := cl.ownerOp("bulk/open", cmap{{uint64(1), uint64(0)}})
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
