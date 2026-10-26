// Package shacrypt implements the SHA-512 based Unix crypt ("$6$", Ulrich Drepper, "Unix crypt using SHA-256 and
// SHA-512") for the root password hash the helper writes to /etc/shadow (#254, docs/design/254-claim-lock-fix.md §5.1).
// It exists so the helper does not depend on an external command that the image may not carry (the 1.5.13 claim
// never locked because busybox `cryptpw` is not built). Verification is musl's crypt() on the node (login, dropbear).
//
// Hash512 follows the specification exactly (salt truncated to 16, rounds clamped up to 1000, "rounds=" echoed when
// given) except where musl would REFUSE the setting (rounds > 9 999 999, key > 256 bytes, ':' or '\n' in the salt):
// those are errors, so this package never produces a hash the node cannot verify
// (musl-1.2.5 src/crypt/crypt_sha512.c:203-207, 265, 273).
package shacrypt

import (
	"crypto/rand"
	"crypto/sha512"
	"errors"
	"regexp"
	"strconv"
	"strings"
)

const (
	alphabet      = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	saltMax       = 16
	roundsDefault = 5000
	roundsMin     = 1000
	roundsMax     = 9999999 // musl ROUNDS_MAX: above it musl rejects the setting
	keyMax        = 256     // musl KEY_MAX
)

// permutation of the 64 digest bytes into 21 groups of three (spec step 22), then byte 63 alone
var perm = [21][3]int{{0, 21, 42}, {22, 43, 1}, {44, 2, 23}, {3, 24, 45}, {25, 46, 4}, {47, 5, 26}, {6, 27, 48},
	{28, 49, 7}, {50, 8, 29}, {9, 30, 51}, {31, 52, 10}, {53, 11, 32}, {12, 33, 54}, {34, 55, 13}, {56, 14, 35},
	{15, 36, 57}, {37, 58, 16}, {59, 17, 38}, {18, 39, 60}, {40, 61, 19}, {62, 20, 41}}

var newHashRE = regexp.MustCompile(`^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$`)

// Hash512 computes crypt(key, setting) for a "$6$" setting ("$6$salt", "$6$salt$…", "$6$rounds=N$salt…").
func Hash512(key []byte, setting string) (string, error) {
	return hash512(key, setting, &perm)
}

func hash512(key []byte, setting string, p *[21][3]int) (string, error) {
	if len(key) > keyMax {
		return "", errors.New("shacrypt: key longer than 256 bytes")
	}
	s, ok := strings.CutPrefix(setting, "$6$")
	if !ok {
		return "", errors.New("shacrypt: not a $6$ setting")
	}
	rounds, custom := roundsDefault, false
	if r, rest, found := strings.Cut(s, "$"); found && strings.HasPrefix(r, "rounds=") {
		n, err := strconv.ParseUint(r[len("rounds="):], 10, 64)
		if err != nil {
			return "", errors.New("shacrypt: bad rounds=")
		}
		if n > roundsMax {
			return "", errors.New("shacrypt: rounds above 9999999 (musl rejects them)")
		}
		rounds, custom, s = int(n), true, rest
		if rounds < roundsMin {
			rounds = roundsMin
		}
	}
	if i := strings.IndexByte(s, '$'); i >= 0 {
		s = s[:i]
	}
	if len(s) > saltMax {
		s = s[:saltMax]
	}
	if strings.ContainsAny(s, ":\n") {
		return "", errors.New("shacrypt: ':' or newline in the salt")
	}
	salt := []byte(s)

	// steps 4-8: digest B = SHA512(key salt key)
	h := sha512.New()
	h.Write(key)
	h.Write(salt)
	h.Write(key)
	b := h.Sum(nil)
	// steps 1-3, 9-12: digest A
	h.Reset()
	h.Write(key)
	h.Write(salt)
	n := len(key)
	for ; n > 64; n -= 64 {
		h.Write(b)
	}
	h.Write(b[:n])
	for n = len(key); n > 0; n >>= 1 {
		if n&1 != 0 {
			h.Write(b)
		} else {
			h.Write(key)
		}
	}
	a := h.Sum(nil)
	// steps 13-16: P sequence
	h.Reset()
	for i := 0; i < len(key); i++ {
		h.Write(key)
	}
	dp := h.Sum(nil)
	pseq := make([]byte, 0, len(key))
	for n = len(key); n > 64; n -= 64 {
		pseq = append(pseq, dp...)
	}
	pseq = append(pseq, dp[:n]...)
	// steps 17-20: S sequence
	h.Reset()
	for i := 0; i < 16+int(a[0]); i++ {
		h.Write(salt)
	}
	sseq := h.Sum(nil)[:len(salt)]
	// step 21: the rounds
	c := a
	for i := 0; i < rounds; i++ {
		h.Reset()
		if i&1 != 0 {
			h.Write(pseq)
		} else {
			h.Write(c)
		}
		if i%3 != 0 {
			h.Write(sseq)
		}
		if i%7 != 0 {
			h.Write(pseq)
		}
		if i&1 != 0 {
			h.Write(c)
		} else {
			h.Write(pseq)
		}
		c = h.Sum(nil)
	}
	// step 22: output
	var out strings.Builder
	out.WriteString("$6$")
	if custom {
		out.WriteString("rounds=" + strconv.Itoa(rounds) + "$")
	}
	out.Write(salt)
	out.WriteByte('$')
	enc := func(b2, b1, b0 byte, n int) {
		w := uint(b2)<<16 | uint(b1)<<8 | uint(b0)
		for ; n > 0; n-- {
			out.WriteByte(alphabet[w&0x3f])
			w >>= 6
		}
	}
	for _, t := range p {
		enc(c[t[0]], c[t[1]], c[t[2]], 4)
	}
	enc(0, 0, c[63], 2)
	return out.String(), nil
}

// New512 hashes password with a fresh 16-character salt from crypto/rand and the default 5000 rounds. The alphabet
// has 64 characters, which divides 256, so a byte mod 64 is unbiased. The result is checked against the exact format
// the helper and prov_apply_lock accept.
func New512(password []byte) (string, error) {
	var r [saltMax]byte
	if _, err := rand.Read(r[:]); err != nil {
		return "", err
	}
	salt := make([]byte, saltMax)
	for i, v := range r {
		salt[i] = alphabet[v&0x3f]
	}
	hash, err := Hash512(password, "$6$"+string(salt))
	if err != nil {
		return "", err
	}
	if !newHashRE.MatchString(hash) {
		return "", errors.New("shacrypt: produced hash fails the $6$ format check")
	}
	return hash, nil
}

// ValidNew reports whether s has the exact shape New512 produces.
func ValidNew(s string) bool { return newHashRE.MatchString(s) }
