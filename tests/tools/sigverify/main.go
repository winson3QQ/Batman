// sigverify — the host half of docs/design/254-app-s1.md §8 item 4: signatures made by the phone Keystore (and brought
// to raw r‖s low-s by the app's Rust core, as they go on the wire) are verified here with the NODE's own function,
// batman-prov/proto.VerifyES256 (rejects high-s) — an implementation the app does not share.
//
//	sigverify [-min N] [-keys K] [-pub KEY]... <file>
//
//	-min N    every public key in the file has at least N records (default 1000)
//	-keys K   the file has at least K different public keys (default 1)
//	-pub KEY  pin: every record is from a pinned key and every pinned key is in the file (so it has N records too).
//	          KEY is the public key (130 hex digits) or its fingerprint, SHA-256 of those 65 bytes (64 hex digits).
//	          Repeat the flag for more keys. Without it the file itself says whose signatures these are.
//
// The file the phone-side exporter writes: UTF-8 text, one record per line, three lowercase-or-uppercase hex fields
// separated by one space:
//
//	<public key> <message> <signature>
//
//	public key  65 bytes: SEC1 uncompressed P-256 point (04 ‖ X ‖ Y)
//	message     the bytes that were signed (not their hash), 1 byte or more
//	signature   64 bytes: r ‖ s, each 32 bytes big-endian, low-s — what the app puts on the wire, not the Keystore's DER
//
// Lines that are empty or start with '#' are skipped. Anything else that is not such a record is an error.
//
// Exit 0 and "PASS sigverify: ..." only when the file has at least K keys, every key has at least N records, no record
// repeats, every key is a pinned one (with -pub) and every signature verifies. An empty file, a key with fewer than N
// records, too few keys, a key that is not pinned, a pinned key that is absent, a malformed line, a repeated record or
// one bad signature: "FAIL ..." and exit 1. Wrong usage: exit 2.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"batman-prov/proto"
)

// fpr is a public key's fingerprint as -pub takes it: SHA-256 of the 65 bytes, lowercase hex.
func fpr(pub []byte) string {
	h := sha256.Sum256(pub)
	return hex.EncodeToString(h[:])
}

// pins collects -pub: lowercase hex of a public key (130 digits) or of a fingerprint (64 digits).
type pins []string

func (p *pins) String() string { return strings.Join(*p, ",") }
func (p *pins) Set(s string) error {
	if b, err := hex.DecodeString(s); err != nil || (len(b) != 65 && len(b) != 32) {
		return fmt.Errorf("want 130 hex digits (a public key) or 64 (its fingerprint)")
	}
	*p = append(*p, strings.ToLower(s))
	return nil
}

// check reads records from r; it returns the number of records and of distinct keys, or the first reasons it failed.
// min: the least number of records per key; keys: the least number of distinct keys; pinned (may be empty): the only
// keys allowed, each of which must be there.
func check(r io.Reader, min, keys int, pinned pins) (n, nkeys int, fails []string) {
	seen, pubs := map[string]bool{}, map[string]int{} // records; fingerprint -> its number of records
	fail := func(f string, a ...any) {
		if len(fails) < 10 {
			fails = append(fails, fmt.Sprintf(f, a...))
		}
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for ln := 1; sc.Scan(); ln++ {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, " ")
		if len(f) != 3 {
			fail("line %d: %d fields, want 3", ln, len(f))
			continue
		}
		pub, e1 := hex.DecodeString(f[0])
		msg, e2 := hex.DecodeString(f[1])
		sig, e3 := hex.DecodeString(f[2])
		if e1 != nil || e2 != nil || e3 != nil || len(pub) != 65 || len(msg) == 0 || len(sig) != 64 {
			fail("line %d: not hex, or sizes %d/%d/%d (want 65 / >=1 / 64)", ln, len(pub), len(msg), len(sig))
			continue
		}
		n++
		if seen[strings.ToLower(line)] {
			fail("line %d: the same record again", ln)
			continue
		}
		seen[strings.ToLower(line)] = true
		fp := fpr(pub)
		pubs[fp]++
		if len(pinned) > 0 && !pinnedKey(pinned, pub, fp) {
			fail("line %d: key %s is not a pinned one (-pub)", ln, fp)
		}
		if !proto.VerifyES256(pub, msg, sig) {
			fail("line %d: signature rejected by proto.VerifyES256", ln)
		}
	}
	if err := sc.Err(); err != nil {
		fail("read: %v", err)
	}
	if n == 0 {
		fail("0 records, want at least %d", min)
	}
	fps := make([]string, 0, len(pubs))
	for fp := range pubs {
		fps = append(fps, fp)
	}
	sort.Strings(fps)
	for _, fp := range fps {
		if pubs[fp] < min {
			fail("key %s: %d records, want at least %d", fp, pubs[fp], min)
		}
	}
	if n > 0 && len(pubs) < keys {
		fail("%d key(s), want at least %d", len(pubs), keys)
	}
	for _, p := range pinned {
		there := pubs[p] > 0 // a fingerprint
		if len(p) == 130 {
			b, _ := hex.DecodeString(p)
			there = pubs[fpr(b)] > 0
		}
		if !there {
			fail("pinned key %s: no record", p)
		}
	}
	return n, len(pubs), fails
}

func pinnedKey(pinned pins, pub []byte, fp string) bool {
	for _, p := range pinned {
		if p == fp || p == hex.EncodeToString(pub) {
			return true
		}
	}
	return false
}

func main() {
	var pinned pins
	min := flag.Int("min", 1000, "the least number of records of every key")
	keys := flag.Int("keys", 1, "the least number of different public keys")
	flag.Var(&pinned, "pub", "a pinned public key (130 hex digits) or its SHA-256 fingerprint (64); may repeat")
	flag.Parse()
	if flag.NArg() != 1 || *min < 1 || *keys < 1 {
		fmt.Fprintln(os.Stderr, "usage: sigverify [-min N] [-keys K] [-pub KEY]... <file>   (N, K >= 1)")
		os.Exit(2)
	}
	fh, err := os.Open(flag.Arg(0))
	if err != nil {
		fmt.Println("FAIL sigverify:", err)
		os.Exit(1)
	}
	defer fh.Close()
	n, nkeys, fails := check(fh, *min, *keys, pinned)
	if len(fails) > 0 {
		for _, s := range fails {
			fmt.Println("FAIL sigverify:", s)
		}
		os.Exit(1)
	}
	fmt.Printf("PASS sigverify: %d signatures from %d key(s), all accepted by proto.VerifyES256\n", n, nkeys)
}
