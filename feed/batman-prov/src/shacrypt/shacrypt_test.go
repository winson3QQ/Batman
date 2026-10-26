package shacrypt

import (
	"bytes"
	"crypto/rand"
	"math/big"
	"os/exec"
	"strings"
	"testing"
)

// Drepper's specification test vectors for SHA-512 crypt, plus musl's own self-test (crypt_sha512.c:370-372).
var vectors = []struct{ setting, key, want string }{
	{"$6$saltstring", "Hello world!", "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"},
	{"$6$rounds=10000$saltstringsaltstring", "Hello world!", "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."},
	{"$6$rounds=5000$toolongsaltstring", "This is just a test", "$6$rounds=5000$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0"},
	{"$6$rounds=1400$anotherlongsaltstring", "a very much longer text to encrypt.  This one even stretches over morethan one line.", "$6$rounds=1400$anotherlongsalts$POfYwTEok97VWcjxIiSOjiykti.o/pQs.wPvMxQ6Fm7I6IoYN3CmLs66x9t0oSwbtEW7o7UmJEiDwGqd8p4ur1"},
	{"$6$rounds=77777$short", "we have a short salt string but not a short password", "$6$rounds=77777$short$WuQyW2YR.hBNpjjRhpYD/ifIw05xdfeEyQoMxIXbkvr0gge1a1x3yRULJ5CCaUeOxFmtlcGZelFl5CxtgfiAc0"},
	{"$6$rounds=123456$asaltof16chars..", "a short string", "$6$rounds=123456$asaltof16chars..$BtCwjqMJGx5hrJhZywWvt0RLE8uZ4oPwcelCjmw2kSYu.Ec6ycULevoBK25fs2xXgMNrCzIMVcgEJAstJeonj1"},
	{"$6$rounds=10$roundstoolow", "the minimum number is still observed", "$6$rounds=1000$roundstoolow$kUMsbe306n21p9R.FRkW3IGn.S9NPN0x50YhH1xhLsPuWGsUSklZt58jaTfF4ZEQpyUNGc0dqbpBYYBaHHrsX."},
	{"$6$rounds=1234$abc0123456789$", "Xy01@#\x01\x02\x80\x7f\xff\r\n\x81\t !", "$6$rounds=1234$abc0123456789$BCpt8zLrc/RcyuXmCDOE1ALqMXB2MH6n1g891HhFj8.w7LxGv.FTkqq6Vxc/km3Y0jE0j24jY5PIv/oOu6reg1"},
}

func TestVectors(t *testing.T) {
	for _, v := range vectors {
		got, err := Hash512([]byte(v.key), v.setting)
		if err != nil || got != v.want {
			t.Errorf("Hash512(%q, %q) = %q, %v; want %q", v.key, v.setting, got, err, v.want)
		}
	}
}

// Mutation negative control: the same vectors must FAIL with a wrong permutation table, so TestVectors is shown to
// depend on the transposition step (a test that passes for any implementation would prove nothing).
func TestVectorsRejectMutant(t *testing.T) {
	bad := perm
	bad[3], bad[4] = bad[4], bad[3]
	for _, v := range vectors {
		got, err := hash512([]byte(v.key), v.setting, &bad)
		if err == nil && got == v.want {
			t.Fatalf("mutant permutation still matched vector %q", v.setting)
		}
	}
}

func TestMuslLimits(t *testing.T) {
	if _, err := Hash512([]byte("x"), "$6$rounds=10000000$abc"); err == nil {
		t.Error("rounds above 9999999 accepted (musl rejects them)")
	}
	if _, err := Hash512(bytes.Repeat([]byte("k"), 257), "$6$abc"); err == nil {
		t.Error("257-byte key accepted (musl KEY_MAX 256)")
	}
	if _, err := Hash512([]byte("x"), "$6$ab:cd"); err == nil {
		t.Error("':' in the salt accepted")
	}
	if _, err := Hash512([]byte("x"), "$1$abc"); err == nil {
		t.Error("non-$6$ setting accepted")
	}
}

func TestNew512(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		h, err := New512([]byte("pw"))
		if err != nil || !ValidNew(h) {
			t.Fatalf("New512 = %q, %v", h, err)
		}
		salt := h[3:19]
		if seen[salt] {
			t.Fatalf("repeated salt %q", salt)
		}
		seen[salt] = true
		// the hash verifies with its own setting
		if again, _ := Hash512([]byte("pw"), h); again != h {
			t.Fatalf("re-hash with the stored setting differs: %q vs %q", again, h)
		}
	}
}

func randomPrintable(t *testing.T, max int) string {
	n, _ := rand.Int(rand.Reader, big.NewInt(int64(max)))
	b := make([]byte, n.Int64()+1)
	for i := range b {
		c, _ := rand.Int(rand.Reader, big.NewInt(95))
		b[i] = byte(32 + c.Int64()) // printable ASCII, no newline
	}
	return string(b)
}

func randomSalt(t *testing.T) string {
	n, _ := rand.Int(rand.Reader, big.NewInt(saltMax))
	b := make([]byte, n.Int64()+1)
	for i := range b {
		c, _ := rand.Int(rand.Reader, big.NewInt(64))
		b[i] = alphabet[c.Int64()]
	}
	return string(b)
}

// Independent implementations. A missing tool is a FAIL, never a skip (an empty cross-check proves nothing).
// openssl 3 `passwd -6 -salt` covers the default rounds only (it does not take a rounds= prefix).
func TestCrossOpenSSL(t *testing.T) {
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Fatal("openssl not found: the cross-check cannot run")
	}
	for i := 0; i < 200; i++ {
		pw, salt := randomPrintable(t, 60), randomSalt(t)
		cmd := exec.Command("openssl", "passwd", "-6", "-salt", salt, "-stdin")
		cmd.Stdin = strings.NewReader(pw + "\n")
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("openssl: %v", err)
		}
		want := strings.TrimSpace(string(out))
		got, err := Hash512([]byte(pw), "$6$"+salt)
		if err != nil || got != want {
			t.Fatalf("pw %q salt %q: go %q, openssl %q (%v)", pw, salt, got, want, err)
		}
	}
}

// busybox mkpasswd (the CI job installs busybox): a third implementation, with rounds= too
func TestCrossBusybox(t *testing.T) {
	if _, err := exec.LookPath("busybox"); err != nil {
		t.Fatal("busybox not found: the cross-check cannot run")
	}
	for i := 0; i < 50; i++ {
		pw, salt := randomPrintable(t, 40), randomSalt(t)
		// password on fd 0 (-P 0): a random password may start with '-' and must not be parsed as an option
		cmd := exec.Command("busybox", "mkpasswd", "-P", "0", "-m", "sha512", "-S", salt)
		cmd.Stdin = strings.NewReader(pw + "\n")
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("busybox mkpasswd: %v (is the applet built?)", err)
		}
		want := strings.TrimSpace(string(out))
		got, err := Hash512([]byte(pw), "$6$"+salt)
		if err != nil || got != want {
			t.Fatalf("pw %q salt %q: go %q, busybox %q (%v)", pw, salt, got, want, err)
		}
	}
}
