package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/proto"
)

// TestMain: with SIGVERIFY_MAIN set this binary is sigverify itself (TestMainExits runs it that way, so the exit
// codes are those of the real main).
func TestMain(m *testing.M) {
	if os.Getenv("SIGVERIFY_MAIN") != "" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// records: n lines signed here with proto.SignES256 (a stand-in for the phone: the real file comes from the Keystore);
// every call makes a new key
func records(t *testing.T, n int) []string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub, _ := k.PublicKey.Bytes()
	out := make([]string, n)
	for i := range out {
		msg := []byte(fmt.Sprintf("batman-owner-auth-v1 record %d", i))
		sig, err := proto.SignES256(k, msg)
		if err != nil {
			t.Fatal(err)
		}
		out[i] = hex.EncodeToString(pub) + " " + hex.EncodeToString(msg) + " " + hex.EncodeToString(sig)
	}
	return out
}

func run(lines []string, min int) (int, []string) {
	n, _, fails := check(strings.NewReader(strings.Join(lines, "\n")), min, 1, nil)
	return n, fails
}

func wantFail(t *testing.T, what string, lines []string, min int, reason string) {
	t.Helper()
	_, fails := run(lines, min)
	if len(fails) == 0 {
		t.Fatalf("%s: accepted", what)
	}
	if !strings.Contains(strings.Join(fails, "\n"), reason) {
		t.Fatalf("%s: failed for another reason: %v", what, fails)
	}
}

func TestAThousandGoodSignaturesPass(t *testing.T) {
	l := records(t, 1000)
	l = append([]string{"# exported by the phone", ""}, l...)
	l[5] = strings.ToUpper(l[5]) + "\r" // hex case and CRLF do not matter
	if n, fails := run(l, 1000); n != 1000 || len(fails) != 0 {
		t.Fatalf("n=%d fails=%v", n, fails)
	}
}

func TestOneCorruptedSignatureFails(t *testing.T) {
	l := records(t, 1000)
	f := strings.Split(l[617], " ")
	sig, _ := hex.DecodeString(f[2])
	sig[40] ^= 0x01
	l[617] = f[0] + " " + f[1] + " " + hex.EncodeToString(sig)
	wantFail(t, "one flipped bit in one signature of 1000", l, 1000, "line 618: signature rejected")

	// the message of another record under this signature
	l = records(t, 1000)
	a, b := strings.Split(l[3], " "), strings.Split(l[4], " ")
	l[3] = a[0] + " " + b[1] + " " + a[2]
	wantFail(t, "a signature over another message", l, 1000, "line 4: signature rejected")
}

// a valid signature in its high-s form is what an un-normalised Keystore signature looks like: the node refuses it
func TestHighSFails(t *testing.T) {
	l := records(t, 1000)
	f := strings.Split(l[0], " ")
	sig, _ := hex.DecodeString(f[2])
	s := new(big.Int).Sub(elliptic.P256().Params().N, new(big.Int).SetBytes(sig[32:]))
	s.FillBytes(sig[32:])
	l[0] = f[0] + " " + f[1] + " " + hex.EncodeToString(sig)
	wantFail(t, "high-s", l, 1000, "line 1: signature rejected")
}

// a good signature under another key: record 10 carries key B's public key with key A's signature over its message
func TestWrongKeyFails(t *testing.T) {
	l := records(t, 1000)                     // key A
	b := strings.Split(records(t, 1)[0], " ") // a fresh key B
	f := strings.Split(l[9], " ")
	if b[0] == f[0] {
		t.Fatal("the two keys are the same")
	}
	l[9] = b[0] + " " + f[1] + " " + f[2]
	wantFail(t, "key B with key A's signature", l, 1000, "line 10: signature rejected")
}

func TestEmptyOrShortFileFails(t *testing.T) {
	wantFail(t, "an empty file", nil, 1000, "0 records, want at least 1000")
	wantFail(t, "only comments", []string{"# nothing", ""}, 1000, "0 records, want at least 1000")
	wantFail(t, "999 records", records(t, 999), 1000, "999 records, want at least 1000")
}

func TestMalformedOrRepeatedRecordFails(t *testing.T) {
	l := records(t, 1001)
	bad := append([]string(nil), l...)
	bad[10] = strings.Replace(bad[10], " ", "  ", 1)
	wantFail(t, "two spaces", bad, 1000, "line 11: 4 fields")
	bad = append([]string(nil), l...)
	bad[10] = bad[10][:len(bad[10])-2] // a 63-byte signature
	wantFail(t, "a short signature", bad, 1000, "line 11: not hex, or sizes 65/")
	bad = append([]string(nil), l...)
	bad[10] = "zz" + bad[10][2:]
	wantFail(t, "not hex", bad, 1000, "line 11: not hex")
	bad = append([]string(nil), l...)
	bad[10] = bad[9]
	wantFail(t, "the same record twice", bad, 1000, "line 11: the same record again")
}

func pubOf(line string) string { return strings.Split(line, " ")[0] }

func fprOf(line string) string {
	b, _ := hex.DecodeString(pubOf(line))
	return fpr(b)
}

// -keys: one key that signed 1000 times is not two keys, and every key needs its own 1000
func TestKeysMinimum(t *testing.T) {
	a, b := records(t, 1000), records(t, 1000)
	both := append(append([]string(nil), a...), b...)
	if n, keys, fails := check(strings.NewReader(strings.Join(both, "\n")), 1000, 2, nil); n != 2000 || keys != 2 || len(fails) != 0 {
		t.Fatalf("two keys, 1000 each: n=%d keys=%d fails=%v", n, keys, fails)
	}
	_, _, fails := check(strings.NewReader(strings.Join(a, "\n")), 1000, 2, nil)
	if len(fails) != 1 || fails[0] != "1 key(s), want at least 2" {
		t.Fatalf("one key signing 1000 times, -keys 2: %v", fails)
	}
	short := append(append([]string(nil), a...), b[:1]...)
	_, _, fails = check(strings.NewReader(strings.Join(short, "\n")), 1000, 2, nil)
	if len(fails) != 1 || fails[0] != "key "+fprOf(b[0])+": 1 records, want at least 1000" {
		t.Fatalf("the second key signed once: %v", fails)
	}
}

// -pub: by key or by fingerprint; a record of another key, or a pinned key that is not in the file, fails
func TestPinnedKeys(t *testing.T) {
	a, b := records(t, 1000), records(t, 1000)
	in := func(l []string) *strings.Reader { return strings.NewReader(strings.Join(l, "\n")) }
	for _, pin := range []string{pubOf(a[0]), fprOf(a[0])} {
		if _, _, fails := check(in(a), 1000, 1, pins{pin}); len(fails) != 0 {
			t.Fatalf("pinned to its own key (%d digits): %v", len(pin), fails)
		}
		_, _, fails := check(in(b), 1000, 1, pins{pin})
		if len(fails) != 10 || fails[0] != "line 1: key "+fprOf(b[0])+" is not a pinned one (-pub)" {
			t.Fatalf("1000 good signatures of another key (%d digits): %v", len(pin), fails)
		}
		_, _, fails = check(in(a), 1000, 1, pins{pin, fprOf(b[0])})
		if len(fails) != 1 || fails[0] != "pinned key "+fprOf(b[0])+": no record" {
			t.Fatalf("a pinned key with no record: %v", fails)
		}
	}
	var p pins
	if p.Set("zz") == nil || p.Set(pubOf(a[0])[:128]) == nil || p.Set(strings.ToUpper(fprOf(a[0]))) != nil || p[0] != fprOf(a[0]) {
		t.Fatalf("-pub parsing: %v", p)
	}
}

// the real main(): what it prints and its exit code
func TestMainExits(t *testing.T) {
	dir := t.TempDir()
	file := func(name string, l []string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(strings.Join(l, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	a, b := records(t, 1000), records(t, 1000)
	one, two, short := file("one", a), file("two", append(append([]string(nil), a...), b...)), file("short", a[:999])
	for _, c := range []struct {
		what string
		args []string
		code int
		out  string
	}{
		{"1000 of one key", []string{one}, 0, "PASS sigverify: 1000 signatures from 1 key(s), all accepted by proto.VerifyES256\n"},
		{"999, default -min", []string{short}, 1, "FAIL sigverify: key " + fprOf(a[0]) + ": 999 records, want at least 1000\n"},
		{"999, -min 999", []string{"-min", "999", short}, 0, "PASS sigverify: 999 signatures from 1 key(s), all accepted by proto.VerifyES256\n"},
		{"one key, -keys 2", []string{"-keys", "2", one}, 1, "FAIL sigverify: 1 key(s), want at least 2\n"},
		{"two keys, -keys 2", []string{"-keys", "2", two}, 0, "PASS sigverify: 2000 signatures from 2 key(s), all accepted by proto.VerifyES256\n"},
		{"pinned", []string{"-pub", fprOf(a[0]), "-pub", pubOf(b[0]), two}, 0, "PASS sigverify: 2000 signatures from 2 key(s), all accepted by proto.VerifyES256\n"},
		{"pinned to another key", []string{"-min", "1", "-pub", fprOf(b[0]), file("x", a[:1])}, 1,
			"FAIL sigverify: line 1: key " + fprOf(a[0]) + " is not a pinned one (-pub)\nFAIL sigverify: pinned key " + fprOf(b[0]) + ": no record\n"},
		{"an empty file", []string{file("empty", nil)}, 1, "FAIL sigverify: 0 records, want at least 1000\n"},
		{"no such file", []string{filepath.Join(dir, "none")}, 1, ""},
		{"no file argument", nil, 2, ""},
		{"-min 0", []string{"-min", "0", one}, 2, ""},
		{"-keys 0", []string{"-keys", "0", one}, 2, ""},
		{"-pub that is no key", []string{"-pub", "zz", one}, 2, ""},
	} {
		cmd := exec.Command(os.Args[0], c.args...)
		cmd.Env = append(os.Environ(), "SIGVERIFY_MAIN=1")
		var out bytes.Buffer
		cmd.Stdout = &out
		err := cmd.Run()
		code := 0
		if e, ok := err.(*exec.ExitError); ok {
			code = e.ExitCode()
		} else if err != nil {
			t.Fatalf("%s: %v", c.what, err)
		}
		if code != c.code || (c.out != "" && out.String() != c.out) || (c.code != 0) != !strings.HasPrefix(out.String(), "PASS") {
			t.Errorf("%s: exit %d, stdout %q; want exit %d, %q", c.what, code, out.String(), c.code, c.out)
		}
		if c.what == "no such file" && !strings.HasPrefix(out.String(), "FAIL sigverify: open ") {
			t.Errorf("%s: stdout %q", c.what, out.String())
		}
	}
}
