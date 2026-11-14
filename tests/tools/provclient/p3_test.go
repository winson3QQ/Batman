package main

// p3_test.go — the pure parts of p3.go: argument parsing, the CBOR bodies (against hand-written encodings), the
// result-line format, and that no secret value ever reaches a formatted output line.

import (
	"encoding/hex"
	"strings"
	"testing"
)

const testPSK = "CorrectHorse-Battery9.Staple" // 28 chars, in the key-20 charset

func mustHex(t *testing.T, b []byte, want string) {
	t.Helper()
	if got := hex.EncodeToString(b); got != want {
		t.Fatalf("encoding\n got  %s\n want %s", got, want)
	}
}

func TestSettingsSetBodyCountry(t *testing.T) {
	body, err := settingsSetBody("2", []string{"TW"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	// {2: "TW"} = a1 02 62 54 57
	mustHex(t, cEnc(body), "a10262"+"5457")
}

func TestSettingsSetBodyName(t *testing.T) {
	body, err := settingsSetBody("1", []string{"node-7"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(body), "a10166"+hex.EncodeToString([]byte("node-7")))
}

func TestSettingsSetBodyHalow(t *testing.T) {
	body, err := settingsSetBody("10", []string{"40", "4"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	// {10: {1: 40, 2: 4}} = a1 0a a2 01 18 28 02 04
	mustHex(t, cEnc(body), "a10aa20118280204")
	body, err = settingsSetBody("10", []string{"40"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(body), "a10aa1011828")
}

func TestSettingsSetBodySubKeys(t *testing.T) {
	b, err := settingsSetBody("11", []string{"7"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(b), "a10ba10107")
	b, err = settingsSetBody("12", []string{"true"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(b), "a10ca101f5")
	b, err = settingsSetBody("13", []string{"ab"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(b), "a10da101626162")
}

func TestSettingsSetBodyKey20(t *testing.T) {
	fd3 := parseKV("ssid=team-a\r\npsk=" + testPSK + "\n")
	body, err := settingsSetBody("20", nil, fd3)
	if err != nil {
		t.Fatal(err)
	}
	// {20: {1: "team-a", 2: psk}} = a1 14 a2 01 66 "team-a" 02 78 1c psk
	mustHex(t, cEnc(body), "a114a20166"+hex.EncodeToString([]byte("team-a"))+"02781c"+hex.EncodeToString([]byte(testPSK)))
	// the values never come on argv
	if _, err := settingsSetBody("20", []string{"team-a", testPSK}, fd3); err == nil {
		t.Fatal("key 20 accepted argv values")
	}
	// both lines are required
	if _, err := settingsSetBody("20", nil, parseKV("ssid=team-a\n")); err == nil {
		t.Fatal("key 20 accepted a missing psk")
	}
	if _, err := settingsSetBody("20", nil, nil); err == nil {
		t.Fatal("key 20 accepted no fd 3")
	}
}

func TestSettingsSetBodyRejects(t *testing.T) {
	for _, c := range [][]string{{"x", "v"}, {"3", "v"}, {"1"}, {"10", "ch"}, {"12", "maybe"}, {"11", "-1"}} {
		if _, err := settingsSetBody(c[0], c[1:], nil); err == nil {
			t.Errorf("accepted %v", c)
		}
	}
}

func TestP3NeedsFd3(t *testing.T) {
	if !p3NeedsFd3("settings-set", []string{"settings-set", "04aa", "20"}) {
		t.Fatal("key 20 must read fd 3")
	}
	if p3NeedsFd3("settings-set", []string{"settings-set", "04aa", "2", "TW"}) || p3NeedsFd3("settings-get", []string{"settings-get", "04aa"}) {
		t.Fatal("fd 3 read for an op that has no secret")
	}
}

func TestUpdateCheckBody(t *testing.T) {
	// a minimal manifest {1: "v", 2: "b"} = a2 01 61 76 02 61 62; the body wraps it verbatim: {1: manifest}
	man, _ := hex.DecodeString("a2016176026162")
	body, err := updateCheckBody(man)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(body), "a101"+"a2016176026162")
	// a realistic one round-trips too (the client does not interpret the manifest)
	full := cEnc(cmap{{uint64(1), "1.5.14-wsl.23"}, {uint64(2), "bcm2711"}, {uint64(3), uint64(126000000)},
		{uint64(4), make([]byte, 32)}, {uint64(5), []byte{0x82, 0xf6, 0xf6}}, {uint64(6), []any{"1.5.15-wsl.1"}}})
	body, err = updateCheckBody(full)
	if err != nil {
		t.Fatal(err)
	}
	mustHex(t, cEnc(body), "a101"+hex.EncodeToString(full))
	for _, bad := range [][]byte{nil, {0x01}, {0xa1, 0x01}, append(append([]byte{}, man...), 0x00)} {
		if _, err := updateCheckBody(bad); err == nil {
			t.Errorf("accepted %x as a manifest", bad)
		}
	}
}

func TestResultLineReason(t *testing.T) {
	if got := resultLine("settings.set", 24, cmap{{uint64(2), uint64(13)}}, ""); got != "RESULT settings.set code=24 reason=13" {
		t.Fatal(got)
	}
	if got := resultLine("settings.set", 7, cmap{}, ""); got != "RESULT settings.set code=7" {
		t.Fatal(got)
	}
	// on code 0 result key 2 is body data, not a reason
	if got := resultLine("x", 0, cmap{{uint64(2), uint64(13)}}, " a=1"); got != "RESULT x code=0 a=1" {
		t.Fatal(got)
	}
	if got := resultLine("x", 6, nil, ""); got != "RESULT x code=6" {
		t.Fatal(got)
	}
}

func TestNoSecretInOutput(t *testing.T) {
	want := short([]byte(testPSK))
	// a settings map that (against the design) carries the passphrase under key 20
	s := fmtSettings(cmap{{uint64(1), "n"}, {uint64(2), "TW"}, {uint64(20), cmap{{uint64(1), "team-a"}, {uint64(2), testPSK}}}})
	if strings.Contains(s, testPSK) || !strings.Contains(s, want) {
		t.Fatalf("settings leaks or lacks the sha: %q", s)
	}
	if !strings.Contains(s, "keys=1,2,20") || !strings.Contains(s, ` ssid="team-a"`) || !strings.Contains(s, ` country="TW"`) {
		t.Fatalf("settings rendering: %q", s)
	}
	// bulk-open-resp: key 2 is the passphrase
	b := fmtBulkOpen(cmap{{uint64(1), "team-a"}, {uint64(2), testPSK}, {uint64(3), "10.41.0.1"}, {uint64(4), uint64(8095)}, {uint64(5), uint64(900)}})
	if strings.Contains(b, testPSK) || !strings.Contains(b, "psk_sha="+want) || !strings.Contains(b, "port=8095") {
		t.Fatalf("bulk.open leaks or lacks the sha: %q", b)
	}
	// the whole result line of a settings.set reply echoing the settings
	line := resultLine("settings.set(key 20)", 0, nil, ifOK(0, s))
	if strings.Contains(line, testPSK) {
		t.Fatalf("result line leaks: %q", line)
	}
	// an error reply renders no body at all
	if got := ifOK(24, s); got != "" {
		t.Fatalf("body rendered on an error: %q", got)
	}
}

func TestFmtProgressStatus(t *testing.T) {
	if got := fmtProgress(cmap{{uint64(1), uint64(0)}, {uint64(2), uint64(0)}, {uint64(3), uint64(11)}}); got != " phase=0 percent=0 fail_reason=11" {
		t.Fatal(got)
	}
	if got := fmtProgress(cmap{{uint64(1), uint64(3)}, {uint64(2), uint64(100)}}); got != " phase=3 percent=100" {
		t.Fatal(got)
	}
	st := fmtStatus(cmap{{uint64(1), uint64(2)}, {uint64(2), uint64(0)}, {uint64(3), uint64(4)}, {uint64(4), true},
		{uint64(5), cmap{{uint64(1), uint64(3)}, {uint64(2), "no peers"}}}, {uint64(15), cmap{{"uptime_s", uint64(1)}, {"image", "x"}}}})
	if st != " state=2 verdict=0 neighbours=4 p5_saved=true join_failure=3 f15=image,uptime_s self=- peers=- bytes=43" {
		t.Fatal(st)
	}
	for _, c := range []struct {
		in   any
		want string
	}{
		{"none", " trust=none"}, {"bad", " trust=bad"}, {"0123456789abcdef", " trust=0123456789abcdef"},
		{"0123456789ABCDEF", " trust=?"}, {"x y", " trust=?"}, {uint64(1), " trust=?"},
	} {
		st = fmtStatus(cmap{{uint64(1), uint64(2)}, {uint64(15), cmap{{"trust", c.in}}}})
		if !strings.Contains(st, " f15=trust"+c.want+" ") { // the team fields follow it (key 8 / 9 / bytes)
			t.Fatalf("trust %v: %q", c.in, st)
		}
	}
	ds := fmtDiagSummary(cmap{{uint64(1), []any{cmap{{uint64(1), "join.no_peers"}, {uint64(2), uint64(1)}}}}})
	if ds != " n=1 items=join.no_peers:1" {
		t.Fatal(ds)
	}
	if handleHex([]byte{0xab, 0xcd}) != "abcd" || handleHex("ab") != "6162" || handleHex(uint64(255)) != "ff" {
		t.Fatal("handleHex")
	}
}

// status.get's key 1 is a bool (node/status.go:291-293): the uint 0 sent before 2026-11-13 was ESchema on every node
func TestStatusGetBodyIsBool(t *testing.T) {
	for opt, want := range map[string]bool{"": true, "full": true, "member": false} {
		b, err := statusGetBody(opt)
		if err != nil || len(b) != 1 {
			t.Fatalf("%q: %v %v", opt, b, err)
		}
		if v, ok := b.get(1).(bool); !ok || v != want {
			t.Fatalf("%q: key 1 = %#v, want the bool %v", opt, b.get(1), want)
		}
	}
	if _, err := statusGetBody("0"); err == nil {
		t.Fatal("the old scope argument 0 accepted")
	}
}

// whole-team status keys (254-app-team-status §4.1): key 8 -> self, key 9 -> addr/ago (sorted); empty -> none; a key 9
// the app would drop (§4.1 "missing / broken") -> bad
func TestFmtStatusTeam(t *testing.T) {
	a, b := []byte{0xa8, 0xdd, 0x9f, 0x4d, 0xc7, 0x60}, []byte{0xa8, 0xdd, 0x9f, 0x4d, 0xc6, 0xd3}
	st := fmtStatus(cmap{{uint64(1), uint64(3)}, {uint64(8), []byte{0xa8, 0xdd, 0x9f, 0x4d, 0xc6, 0x10}},
		{uint64(9), []any{cmap{{uint64(1), a}, {uint64(2), uint64(0)}}, cmap{{uint64(1), b}, {uint64(2), uint64(2)}}}}})
	// 1 map hdr + 2 (k1) + 8 (k8 bstr6) + 2 (k9, array hdr) + 2 x 11 (map hdr, k1 bstr6, k2 uint) = 35
	if !strings.HasSuffix(st, " self=a8:dd:9f:4d:c6:10 peers=a8:dd:9f:4d:c6:d3/2,a8:dd:9f:4d:c7:60/0 bytes=35") {
		t.Fatal(st)
	}
	if st := fmtStatus(cmap{{uint64(9), []any{}}}); !strings.Contains(st, " peers=none ") {
		t.Fatal(st)
	}
	if st := fmtStatus(cmap{{uint64(8), []byte{1, 2}}}); !strings.Contains(st, " self=- peers=- ") {
		t.Fatal("a 2-byte key 8 printed as an address: " + st)
	}
	many := make([]any, 33)
	for i := range many {
		many[i] = cmap{{uint64(1), a}, {uint64(2), uint64(0)}}
	}
	for name, k9 := range map[string]any{
		"not a list": "x", "33 entries": many, "entry not a map": []any{uint64(1)},
		"short addr":  []any{cmap{{uint64(1), []byte{1}}, {uint64(2), uint64(0)}}},
		"ago missing": []any{cmap{{uint64(1), a}}}, "ago negative": []any{cmap{{uint64(1), a}, {uint64(2), int64(-1)}}},
	} {
		if st := fmtStatus(cmap{{uint64(9), k9}}); !strings.Contains(st, " peers=bad ") {
			t.Fatalf("%s: %s", name, st)
		}
	}
}
