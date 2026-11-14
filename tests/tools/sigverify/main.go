// sigverify — the host half of docs/design/254-app-s1.md §8 item 4: signatures made by the phone Keystore (and brought
// to raw r‖s low-s by the app's Rust core, as they go on the wire) are verified here with the NODE's own function,
// batman-prov/proto.VerifyES256 (rejects high-s) — an implementation the app does not share.
//
//	sigverify [-min N] <file>        N defaults to 1000
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
// Exit 0 and "PASS sigverify: ..." only when the file has at least N records, no record repeats, and every signature
// verifies. An empty file, a short file, a malformed line, a repeated record or one bad signature: "FAIL ..." and exit 1.
package main

import (
	"bufio"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"batman-prov/proto"
)

// check reads records from r; it returns the number of records and of distinct keys, or the first reasons it failed.
func check(r io.Reader, min int) (n, keys int, fails []string) {
	seen, pubs := map[string]bool{}, map[string]bool{}
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
		pubs[strings.ToLower(f[0])] = true
		if !proto.VerifyES256(pub, msg, sig) {
			fail("line %d: signature rejected by proto.VerifyES256", ln)
		}
	}
	if err := sc.Err(); err != nil {
		fail("read: %v", err)
	}
	if n < min {
		fail("%d records, want at least %d", n, min)
	}
	return n, len(pubs), fails
}

func main() {
	min := flag.Int("min", 1000, "the least number of records")
	flag.Parse()
	if flag.NArg() != 1 || *min < 1 {
		fmt.Fprintln(os.Stderr, "usage: sigverify [-min N] <file>   (N >= 1)")
		os.Exit(2)
	}
	fh, err := os.Open(flag.Arg(0))
	if err != nil {
		fmt.Println("FAIL sigverify:", err)
		os.Exit(1)
	}
	defer fh.Close()
	n, keys, fails := check(fh, *min)
	if len(fails) > 0 {
		for _, s := range fails {
			fmt.Println("FAIL sigverify:", s)
		}
		os.Exit(1)
	}
	fmt.Printf("PASS sigverify: %d signatures from %d key(s), all accepted by proto.VerifyES256\n", n, keys)
}
