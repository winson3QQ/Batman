package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
	"testing"

	"batman-prov/proto"
)

// records: n lines signed here with proto.SignES256 (a stand-in for the phone: the real file comes from the Keystore)
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
	n, _, fails := check(strings.NewReader(strings.Join(lines, "\n")), min)
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
