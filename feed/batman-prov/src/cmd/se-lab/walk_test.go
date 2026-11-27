//go:build linux

package main

import (
	"bytes"
	"encoding/hex"
	"regexp"
	"runtime/debug"
	"sort"
	"strings"
	"testing"
	"time"

	"batman-prov/se608"
	"batman-prov/se608/fakechip"
)

// walker runs se-lab commands on one fake chip and fails the test with the output on a surprise.
type walker struct {
	t     *testing.T
	r     *rig
	allow string
	sn    string
}

func newWalker(t *testing.T) *walker {
	r := newRig(t)
	sn := r.serial()
	return &walker{t: t, r: r, allow: r.allowFile(t, sn), sn: hex.EncodeToString(sn[:])}
}

// run executes `se-lab -allow LIST <args>` and checks the exit code and that every want is in stdout.
func (w *walker) run(rc int, args []string, want ...string) string {
	w.t.Helper()
	got, out, errOut := w.r.run(w.t, append([]string{"-allow", w.allow}, args...)...)
	if got != rc {
		w.t.Fatalf("se-lab %v: rc %d, want %d\n%s%s", args, got, rc, out, errOut)
	}
	for _, s := range want {
		if !strings.Contains(out, s) {
			w.t.Fatalf("se-lab %v: output lacks %q\n%s%s", args, s, out, errOut)
		}
	}
	return out
}

func (w *walker) forGood(rc int, args []string, want ...string) string {
	w.t.Helper()
	return w.run(rc, append([]string{"-serial", w.sn}, args...), want...)
}

func field(t *testing.T, out, key string) string {
	t.Helper()
	m := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(key) + `=(.*)$`).FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("no %s= line in\n%s", key, out)
	}
	return m[1]
}

// forGoodPkts picks the packets that change a chip for good out of pkts (count, opcode, param1, ...).
func forGoodPkts(pkts [][]byte) [][]byte {
	var out [][]byte
	for _, p := range pkts {
		if p[1] == se608.OpLock || p[1] == se608.OpUpdateExtra || (p[1] == se608.OpCounter && p[2]&1 != 0) {
			out = append(out, p)
		}
	}
	return out
}

// sentAs checks that the packet a command printed (word address .. CRC) is the last for-good packet the chip got.
func (w *walker) sentAs(out, key string) {
	w.t.Helper()
	printed := strings.ReplaceAll(field(w.t, out, key), " ", "")
	fg := forGoodPkts(w.r.chip.Pkts)
	if len(fg) == 0 {
		w.t.Fatalf("no for-good packet reached the chip\n%s", out)
	}
	if got := "03" + hex.EncodeToString(fg[len(fg)-1]); got != printed {
		w.t.Fatalf("printed %s=%s but the chip received %s", key, printed, got)
	}
}

// crcOf is the CRC lock-config computes for the walker's chip right now (from a dry run with a wrong expectation).
func crcOf(w *walker) string {
	_, out, _ := w.r.run(w.t, "-allow", w.allow, "-byte17", w.r.b17(), "-expect-crc", "0000", "-dry-run", "lock-config")
	m := regexp.MustCompile(`(?m)^config_crc=(.*)$`).FindStringSubmatch(out)
	if m == nil {
		return "0000" // the chip does not hold the image: lock-config stops before it prints a CRC
	}
	return m[1]
}

// Chip states the experiments pass through.
func (w *walker) image() {
	w.t.Helper()
	w.run(exitOK, []string{"-byte17", w.r.b17(), "write-image"}, "compare=EQUAL")
}

func (w *walker) configLocked() {
	w.t.Helper()
	w.image()
	w.forGood(exitOK, []string{"-byte17", w.r.b17(), "-expect-crc", crcOf(w), "lock-config"}, "lock_config_result=locked")
}

func (w *walker) bothLocked() {
	w.t.Helper()
	w.configLocked()
	w.run(exitOK, []string{"fill-data"}, "fill_data_failed_slots=0")
	w.forGood(exitOK, []string{"lock-data"}, "lock_data_result=locked")
}

// TestExperimentWalk runs the rig sequence of 255-608b-config.md §8.1 on a fake chip, each "must fail" next to its
// control: E3 → E4 → E5 → E6 → E8 → E11 → E17 → E9 / E10 → E13 → E15 → E12. What the fake answers is the design's
// expectation, not a measurement (fakechip's package comment); what this test proves is that se-lab sends each
// experiment correctly, reads the answer correctly, and cannot be made to lock the wrong thing.
func TestExperimentWalk(t *testing.T) {
	w := newWalker(t)
	b17 := w.r.b17()
	chip := w.r.chip

	// E3
	w.image()

	// E4: the dry run prints the CRC and the packet and sends nothing
	crc := crcOf(w) // a dry run with a wrong expectation: refused, but the computed CRC is printed
	out := w.run(exitOK, []string{"-byte17", b17, "-expect-crc", crc, "-dry-run", "lock-config"}, "dry_run=nothing sent", "lock_packet=03 07 17 00 ")
	if len(forGoodPkts(chip.Pkts)) != 0 || chip.Config[se608.LockConfigByte] != 0x55 {
		t.Fatal("a refused or dry lock-config sent a Lock")
	}
	dryPkt := field(t, out, "lock_packet")
	out = w.forGood(exitOK, []string{"-byte17", b17, "-expect-crc", crc, "lock-config"}, "lock_config_result=locked", "lock_config_after=00", "lock_data_after=55")
	w.sentAs(out, "lock_packet")
	if field(t, out, "lock_packet") != dryPkt {
		t.Fatal("the dry run printed another packet than the real run sent")
	}
	// after the lock: the config zone takes no write, Random is no longer the pattern, write-image refuses
	w.run(exitOK, []string{"config-write", "17", "00000000"}, "config_write_word17=status_0f")
	if out = w.run(exitOK, []string{"random"}); strings.Contains(out, "random=ffff0000ffff0000") {
		t.Fatalf("Random after the config lock is still the test pattern\n%s", out)
	}
	w.run(exitRefused, []string{"-byte17", b17, "write-image"})

	// E6 (before the data lock): clear PrivWrite into the private control slot works; E5: OTP takes a write
	pw := w.run(exitOK, []string{"priv-write", "4"}, "priv_write_slot4=status_00")
	w.run(exitOK, []string{"pubkey", "4"}, "pubkey_slot4="+field(t, pw, "expected_pub_slot4"))
	w.run(exitOK, []string{"fill-data"}, "slot5=written_36_bytes", "slot8=written_416_bytes", "slot15=written_72_bytes",
		"slot4=private_key_slot_skipped", "otp_write_block0=status_00", "otp_write_block1=status_00", "fill_data_failed_slots=0")
	w.run(exitOK, []string{"checkmac", "5"}, "checkmac_slot5=status_0f") // not before the data lock
	// no slot lock and no UpdateExtra before the data lock: E6's control and E17 depend on slot 4 staying open
	w.forGood(exitRefused, []string{"lock-slot", "4"})
	w.forGood(exitRefused, []string{"update-extra", "1", "a0"})
	dry := w.run(exitOK, []string{"-dry-run", "lock-data"}, "dry_run=nothing sent")
	out = w.forGood(exitOK, []string{"-expect-crc", field(t, dry, "data_crc"), "lock-data"}, "lock_data_result=locked", "lock_data_after=00", "lock_packet=03 07 17 01 ")
	w.sentAs(out, "lock_packet")

	// E6 (after): the claim check works with the product's hash; PrivWrite and the never-writable slots refuse;
	// the always-writable control slot still takes a write
	w.run(exitOK, []string{"checkmac", "5"}, "checkmac_slot5=status_00")
	w.run(exitOK, []string{"checkmac", "5", "wrong"}, "checkmac_slot5_wrong=status_01")
	w.run(exitOK, []string{"priv-write", "4"}, "priv_write_slot4=status_0f")
	w.run(exitOK, []string{"data-write", "5"}, "data_write_slot5=status_0f")
	w.run(exitOK, []string{"data-write", "7"}, "data_write_slot7=status_0f")
	w.run(exitOK, []string{"data-write", "6"}, "data_write_slot6=accepted")

	// E8: the claim slot gives nothing to the MAC-class commands or to Read; the control slot does
	w.run(exitOK, []string{"mac", "5"}, "mac_slot5=status_0f")
	w.run(exitOK, []string{"mac", "3"}, "mac_matches_host=yes")
	w.run(exitOK, []string{"gendig-mac", "5"}, "gendig_slot5=status_00", "mac_tempkey=status_0f")
	w.run(exitOK, []string{"gendig-mac", "3"}, "gendig_slot3=status_00", "mac_matches_host=yes")
	w.run(exitOK, []string{"slot-read", "5"}, "slot5=status_0f")
	w.run(exitOK, []string{"read", "data", "0028", "32"}, "read_data_0028=status_0f")
	w.run(exitOK, []string{"slot-read", "8"}, "slot8="+strings.Repeat("00", 416))

	// E11: Counter[1] moves by one, for good; Counter[0] is never touched
	w.run(exitOK, []string{"counter-read", "1"}, "counter1_le=0")
	w.forGood(exitOK, []string{"-dry-run", "counter-inc", "1"}, "dry_run=nothing sent", "packet=03 07 24 01 01 00 ", "counter1_before_le=0")
	if chip.Counters != [2]uint32{0, 0} {
		t.Fatalf("counters %v after a dry run", chip.Counters)
	}
	out = w.forGood(exitOK, []string{"counter-inc", "1"}, "counter1_before_le=0", "counter1_after_inc_le=1", "counter1_inc_result=incremented")
	w.sentAs(out, "packet")
	if chip.Counters != [2]uint32{0, 1} {
		t.Fatalf("counters %v, want [0 1]", chip.Counters)
	}
	w.run(exitOK, []string{"counter-read", "1"}, "counter1_le=1")
	w.run(exitOK, []string{"counter-read", "0"}, "counter0_le=0")
	w.forGood(exitRefused, []string{"counter-inc", "0"})
	w.run(exitOK, []string{"config-write", "15", "ffffffff"}, "config_write_word15=status_0f")
	w.forGood(exitOK, []string{"update-extra", "2", "00"}, "update_extra_mode2=status_0f")
	if chip.Counters != [2]uint32{0, 1} {
		t.Fatalf("counters %v, want [0 1]", chip.Counters)
	}

	// E17: GenKey, the product's sign sequence, the slot lock, then no new key but the old one still works
	w.run(exitOK, []string{"genkey", "4"}, "genkey_slot4=")
	w.run(exitOK, []string{"sign", "4"}, "signature_valid=yes")
	w.run(exitOK, []string{"-dry-run", "lock-slot", "4"}, "dry_run=nothing sent", "lockable=yes", "slot_already_locked=no", "slot_config=2083", "key_config=0073")
	out = w.forGood(exitOK, []string{"lock-slot", "4"}, "lock_slot4_result=locked", "slot_locked_after=ffef")
	w.sentAs(out, "lock_packet")
	w.run(exitOK, []string{"genkey", "4"}, "genkey_slot4=status_0f")
	w.run(exitOK, []string{"sign", "4"}, "signature_valid=yes")
	w.run(exitOK, []string{"sign-internal", "4"}, "sign_internal_slot4=")

	// E9 / E10: slot 0 stays empty; slots 1 and 2 get keys; ECDH only from slot 2, only in clear
	w.run(exitOK, []string{"sign", "0"}, "sign_slot0=status_0f")
	w.run(exitOK, []string{"genkey", "1"})
	w.run(exitOK, []string{"genkey", "2"})
	w.run(exitOK, []string{"ecdh", "2", "clear"}, "ecdh_matches_host=yes")
	w.run(exitOK, []string{"ecdh", "2", "tempkey"}, "ecdh_tempkey_slot2=status_00")
	w.run(exitOK, []string{"ecdh", "2", "enc"}, "ecdh_enc_slot2=status_0f")
	w.run(exitOK, []string{"ecdh", "2", "slot"}, "ecdh_slot_slot2=status_0f")
	w.run(exitOK, []string{"ecdh", "1", "clear"}, "ecdh_clear_slot1=status_0f")
	w.run(exitOK, []string{"sign", "1"}, "sign_slot1=status_0f") // internal-only key: no external signature

	// E13: slot 6 locks and then refuses the write it took before; slot 5 is not lockable; slot 8 is never sent
	out = w.forGood(exitOK, []string{"lock-slot", "6"}, "lock_slot6_result=locked")
	w.sentAs(out, "lock_packet")
	w.run(exitOK, []string{"data-write", "6"}, "data_write_slot6=status_0f")
	w.run(exitOK, []string{"-dry-run", "lock-slot", "5"}, "lockable=no")
	out = w.forGood(exitFail, []string{"lock-slot", "5"})
	if got := field(t, out, "lock_slot5_result"); got != "status_0f" { // exactly: not status_0f_but_LOCKED
		t.Fatalf("lock-slot 5 after slot 6 is locked: %q, want status_0f", got)
	}
	w.sentAs(out, "lock_packet")
	if rc, _, _ := w.r.run(t, "-allow", w.allow, "-serial", w.sn, "update-extra", "3", "00"); rc != exitUsage {
		t.Fatalf("update-extra mode 3: rc %d, want usage", rc)
	}
	n := len(forGoodPkts(chip.Pkts))
	for _, slot := range []string{"8", "0", "3", "15"} {
		w.forGood(exitRefused, []string{"lock-slot", slot})
	}
	if len(forGoodPkts(chip.Pkts)) != n {
		t.Fatal("a Lock was sent for a slot outside 4, 5, 6")
	}

	// E15: a certificate-sized blob in slot 8
	blob := strings.Repeat("a55a", 195) // 390 bytes
	w.run(exitOK, []string{"slot-write", "8", blob}, "slot_write_slot8=written_416_bytes")
	w.run(exitOK, []string{"slot-read", "8"}, "slot8="+blob+strings.Repeat("00", 26))

	// E12 (last: if it moved the chip off 0x60, nothing after it could run): byte 85 takes one write from anyone
	w.run(exitOK, []string{"-dry-run", "update-extra", "1", "a0"}, "dry_run=nothing sent", "packet=03 07 20 01 a0 00 ")
	if chip.Config[85] != 0 {
		t.Fatal("the dry run wrote byte 85")
	}
	out = w.forGood(exitOK, []string{"update-extra", "1", "a0"}, "update_extra_mode1=status_00", "byte85_before=00", "byte85_after=a0")
	w.sentAs(out, "packet")

	w.run(exitOK, []string{"soak", "5"}, "soak_rounds=5", "soak_errors=0", "soak_differ=0")

	// the whole walk sent exactly the for-good packets the design's list has: 2 zone locks, 3 slot locks (one
	// refused by the chip), 1 counter increment, 2 UpdateExtra (one refused)
	if fg := forGoodPkts(chip.Pkts); len(fg) != 8 {
		t.Fatalf("%d for-good packets reached the chip, want 8", len(fg))
	}
}

// Every command, with arguments it accepts and the chip state it needs ("" blank, "img" image written, "cfg" config
// locked, "filled" config locked and the data content written, "both" both zones locked). A command added to the table without an entry here fails the tests below.
var samples = map[string]struct {
	args  []string
	state string
}{
	"info": {nil, ""}, "dump": {nil, ""}, "compare": {nil, "img"}, "soak": {[]string{"2"}, ""},
	"pubkey": {[]string{"4"}, "both"}, "counter-read": {[]string{"1"}, "both"}, "read": {[]string{"config", "0000", "32"}, ""},
	"slot-read": {[]string{"8"}, "both"},
	"random":    {nil, ""}, "data-write": {[]string{"6"}, "both"}, "write-image": {nil, ""},
	"config-write": {[]string{"17", "00000000"}, "img"}, "write": {[]string{"otp", "0000", strings.Repeat("00", 32)}, "cfg"},
	"priv-write": {[]string{"4"}, "cfg"}, "fill-data": {nil, "cfg"}, "checkmac": {[]string{"5"}, "both"},
	"genkey": {[]string{"4"}, "both"}, "sign": {[]string{"4"}, "both"}, "sign-internal": {[]string{"4"}, "both"},
	"mac": {[]string{"3"}, "both"}, "gendig-mac": {[]string{"3"}, "both"}, "hmac": {[]string{"3"}, "both"},
	"kdf": {[]string{"hkdf", "3"}, "both"}, "aes": {[]string{"3"}, "both"}, "ecdh": {[]string{"2", "clear"}, "both"},
	"slot-write": {[]string{"8", "a55a"}, "both"}, "raw": {[]string{"1b", "00", "0000"}, "both"},
	"lock-config": {nil, "img"}, "lock-data": {nil, "filled"}, "lock-slot": {[]string{"6"}, "both"},
	"counter-inc": {[]string{"1"}, "both"}, "update-extra": {[]string{"1", "a0"}, "both"},
}

func (w *walker) enter(state string) {
	w.t.Helper()
	switch state {
	case "img":
		w.image()
	case "cfg":
		w.configLocked()
	case "filled":
		w.configLocked()
		w.run(exitOK, []string{"fill-data"}, "fill_data_failed_slots=0")
	case "both":
		w.bothLocked()
	}
}

func commandNamesSorted() []string {
	var n []string
	for k := range commands {
		n = append(n, k)
	}
	sort.Strings(n)
	return n
}

// invocation builds the arguments of one command: the flags it needs (never -allow, never -serial) and its sample.
func (w *walker) invocation(name string, extra ...string) []string {
	args := append([]string{}, extra...)
	if commands[name].image {
		args = append(args, "-byte17", w.r.b17())
	}
	if name == "lock-config" {
		args = append(args, "-expect-crc", crcOf(w))
	}
	return append(append(args, name), samples[name].args...)
}

type snapshot struct {
	cfg      [se608.ConfigLen]byte
	counters [2]uint32
	data     [16][]byte
	pkts     int
	opens    int
}

func (w *walker) snap() snapshot {
	s := snapshot{cfg: w.r.chip.Config, counters: w.r.chip.Counters, pkts: len(w.r.chip.Pkts), opens: w.r.opens}
	for i := range s.data {
		s.data[i] = append([]byte(nil), w.r.chip.Data[i]...)
	}
	return s
}

func (w *walker) unchanged(s snapshot) bool {
	if w.r.chip.Config != s.cfg || w.r.chip.Counters != s.counters {
		return false
	}
	for i := range s.data {
		if !bytes.Equal(s.data[i], w.r.chip.Data[i]) {
			return false
		}
	}
	return true
}

// onlyReads reports whether every packet since the snapshot was Info or a plain Read.
func (w *walker) onlyReads(s snapshot) bool {
	for _, p := range w.r.chip.Pkts[s.pkts:] {
		if p[1] != se608.OpInfo && p[1] != se608.OpRead {
			return false
		}
	}
	return true
}

func TestEveryCommandHasASample(t *testing.T) {
	for _, n := range commandNamesSorted() {
		if _, ok := samples[n]; !ok {
			t.Errorf("command %q has no entry in samples: the gate tests below do not cover it", n)
		}
	}
	// The commands that act on a chip that is NOT on the sacrificial list. Adding one is a decision, not a default.
	var open []string
	for _, n := range commandNamesSorted() {
		if !commands[n].gated {
			open = append(open, n)
		}
	}
	if got, want := strings.Join(open, " "), "compare counter-read dump info pubkey read slot-read soak"; got != want {
		t.Fatalf("commands without the allow-list gate: %s\nwant: %s", got, want)
	}
	var forGood []string
	for _, n := range commandNamesSorted() {
		if commands[n].forGood {
			forGood = append(forGood, n)
		}
	}
	if got, want := strings.Join(forGood, " "), "counter-inc lock-config lock-data lock-slot update-extra"; got != want {
		t.Fatalf("for-good commands: %s\nwant: %s", got, want)
	}
}

// The sacrificial list binds every command that can change a chip (255-608b-config.md §8.0, and an E4 precondition
// in §8.3): without -allow the bus is not even opened; with a list that does not name the chip nothing but Info and
// Read is sent — also when the right serial is typed in -serial, also in a dry run.
func TestAllowListBindsEveryChangingCommand(t *testing.T) {
	for _, name := range commandNamesSorted() {
		if !commands[name].gated {
			continue
		}
		t.Run(name, func(t *testing.T) {
			w := newWalker(t)
			w.enter(samples[name].state)
			other := w.r.allowFile(t, [9]byte{9, 9, 9, 9, 9, 9, 9, 9, 9})
			inv := w.invocation(name)

			s := w.snap()
			rc, out, errOut := w.r.run(t, append([]string{"-serial", w.sn}, inv...)...)
			if rc != exitRefused || !strings.Contains(errOut, "needs -allow") || w.r.opens != s.opens {
				t.Fatalf("without -allow: rc %d, bus opened %v\n%s%s", rc, w.r.opens != s.opens, out, errOut)
			}
			for _, extra := range [][]string{{"-serial", w.sn}, {"-dry-run"}} {
				s = w.snap()
				rc, out, errOut = w.r.run(t, append(append([]string{"-allow", other}, extra...), inv...)...)
				if rc != exitRefused || !strings.Contains(errOut, "not on the sacrificial list") {
					t.Fatalf("%v, chip not listed: rc %d\n%s%s", extra, rc, out, errOut)
				}
				if !w.onlyReads(s) || !w.unchanged(s) {
					t.Fatalf("%v, chip not listed: something other than Info / Read was sent, or the chip changed", extra)
				}
			}
		})
	}
}

// A dry run of a for-good command — which the runbook runs WITHOUT -serial, before consent — prints what it would
// send and sends nothing that cannot be undone. The same invocation with -serial and without -dry-run does send
// (the control: the sample and the state are ones where the command really goes out).
func TestDryRunSendsNothingForGood(t *testing.T) {
	for _, name := range commandNamesSorted() {
		if !commands[name].forGood {
			continue
		}
		t.Run(name, func(t *testing.T) {
			w := newWalker(t)
			w.enter(samples[name].state)
			inv := w.invocation(name)
			s := w.snap()
			out := w.run(exitOK, append([]string{"-dry-run"}, inv...), "dry_run=nothing sent")
			if n := len(forGoodPkts(w.r.chip.Pkts[s.pkts:])); n != 0 || !w.unchanged(s) {
				t.Fatalf("the dry run sent %d for-good packets, chip unchanged = %v\n%s", n, w.unchanged(s), out)
			}
			// without -serial and without -dry-run: refused before the bus
			s = w.snap()
			if rc, _, _ := w.r.run(t, append([]string{"-allow", w.allow}, inv...)...); rc != exitRefused || w.r.opens != s.opens {
				t.Fatalf("no -serial, no -dry-run: rc %d, bus opened %v", rc, w.r.opens != s.opens)
			}
			// control
			s = w.snap()
			w.forGood(exitOK, inv)
			if n := len(forGoodPkts(w.r.chip.Pkts[s.pkts:])); n != 1 || w.unchanged(s) {
				t.Fatalf("control: the real run sent %d for-good packets, chip unchanged = %v", n, w.unchanged(s))
			}
		})
	}
}

// The commands that need no allow list send only Info, Read, GenKey in public-key mode and Counter in read mode.
func TestOpenCommandsOnlyRead(t *testing.T) {
	for _, name := range commandNamesSorted() {
		if commands[name].gated {
			continue
		}
		w := newWalker(t)
		w.enter(samples[name].state)
		s := w.snap()
		rc, out, errOut := w.r.run(t, w.invocation(name)...)
		if rc != exitOK {
			t.Fatalf("%s: rc %d\n%s%s", name, rc, out, errOut)
		}
		for _, p := range w.r.chip.Pkts[s.pkts:] {
			ok := p[1] == se608.OpInfo || p[1] == se608.OpRead || (p[1] == se608.OpGenKey && p[2] == 0) || (p[1] == se608.OpCounter && p[2] == 0)
			if !ok {
				t.Fatalf("%s sent % x", name, p)
			}
		}
		if !w.unchanged(s) {
			t.Fatalf("%s changed the chip", name)
		}
	}
}

// The policy of an invocation is the barrier, not each command's own code: a rewritable command cannot put a Lock,
// an UpdateExtra, a Counter increment or a Write to the lock bytes on the bus, whatever it is asked.
func TestRewritableCommandsCannotSendForGood(t *testing.T) {
	cases := [][]string{
		{"raw", "17", "00", "0000"}, {"raw", "17", "80", "0000"}, {"raw", "17", "1a", "0000"},
		{"raw", "20", "01", "00a0"}, {"raw", "24", "01", "0001"},
		{"raw", "12", "00", "0015", "00000000"},               // Write config word 21: bytes 84-87
		{"raw", "12", "80", "0010", strings.Repeat("00", 32)}, // Write config block 2 (holds word 21)
		{"raw", "12", "00", "0000", "00000000"},               // Write config word 0: the serial
		{"config-write", "21", "00000000"}, {"config-write", "0", "00000000"},
		{"write", "config", "0015", "00000000"}, {"write", "config", "0010", strings.Repeat("00", 32)},
	}
	for _, state := range []string{"img", "both"} {
		for _, c := range cases {
			w := newWalker(t)
			w.enter(state)
			s := w.snap()
			rc, out, errOut := w.r.run(t, append([]string{"-allow", w.allow, "-serial", w.sn}, c...)...)
			if rc == exitOK {
				t.Fatalf("%s %v: rc 0\n%s%s", state, c, out, errOut)
			}
			if !w.onlyReads(s) || !w.unchanged(s) {
				t.Fatalf("%s %v: reached the chip: % x", state, c, w.r.chip.Pkts[s.pkts:])
			}
		}
	}
	// control: the same raw path does send an opcode that is allowed (Random)
	w := newWalker(t)
	s := w.snap()
	w.run(exitOK, []string{"raw", "1b", "00", "0000"}, "raw_1b=ffff0000")
	if w.onlyReads(s) {
		t.Fatal("control: raw Random did not reach the chip")
	}
}

// Every for-good command is refused — and sends nothing — with a wrong or truncated serial, and (lock-config) when
// the chip does not hold the image or the operator's CRC does not match; the experiments' order is enforced where
// getting it wrong would lose an experiment on the one chip 1.
func TestForGoodRefusals(t *testing.T) {
	type tc struct {
		name  string
		state string
		setup func(*walker)
		args  func(*walker) []string
	}
	lockCfg := func(w *walker, extra ...string) []string {
		return append(extra, "-byte17", w.r.b17(), "-expect-crc", crcOf(w), "lock-config")
	}
	cases := []tc{
		{"lock-config with another serial", "img", nil, func(w *walker) []string { return lockCfg(w, "-serial", "010203040506070809") }},
		{"lock-config with a truncated serial", "img", nil, func(w *walker) []string { return lockCfg(w, "-serial", w.sn[:16]) }},
		{"lock-config with a wrong expected CRC", "img", nil, func(w *walker) []string {
			return []string{"-serial", w.sn, "-byte17", w.r.b17(), "-expect-crc", "0001", "lock-config"}
		}},
		{"lock-config on a chip that does not hold the image", "", nil, func(w *walker) []string { return lockCfg(w, "-serial", w.sn) }},
		{"lock-config with one image byte off", "img", func(w *walker) { w.r.chip.Config[100] ^= 0x40 }, func(w *walker) []string { return lockCfg(w, "-serial", w.sn) }},
		{"lock-config on a locked chip", "cfg", nil, func(w *walker) []string {
			return []string{"-serial", w.sn, "-byte17", w.r.b17(), "-expect-crc", "0000", "lock-config"}
		}},
		{"lock-data before the config lock", "img", nil, func(w *walker) []string { return []string{"-serial", w.sn, "lock-data"} }},
		{"lock-data with a wrong expected CRC", "cfg", nil, func(w *walker) []string { return []string{"-serial", w.sn, "-expect-crc", "0001", "lock-data"} }},
		{"lock-data on a locked chip", "both", nil, func(w *walker) []string { return []string{"-serial", w.sn, "lock-data"} }},
		{"lock-slot before the config lock", "img", nil, func(w *walker) []string { return []string{"-serial", w.sn, "lock-slot", "4"} }},
		{"lock-slot before the data lock", "cfg", nil, func(w *walker) []string { return []string{"-serial", w.sn, "lock-slot", "4"} }},
		{"lock-slot 8", "both", nil, func(w *walker) []string { return []string{"-serial", w.sn, "lock-slot", "8"} }},
		{"lock-slot with another serial", "both", nil, func(w *walker) []string { return []string{"-serial", "010203040506070809", "lock-slot", "6"} }},
		{"update-extra before the config lock", "img", nil, func(w *walker) []string { return []string{"-serial", w.sn, "update-extra", "1", "a0"} }},
		{"update-extra before the data lock", "cfg", nil, func(w *walker) []string { return []string{"-serial", w.sn, "update-extra", "0", "01"} }},
		{"counter-inc 0", "both", nil, func(w *walker) []string { return []string{"-serial", w.sn, "counter-inc", "0"} }},
		{"counter-inc before the config lock", "img", nil, func(w *walker) []string { return []string{"-serial", w.sn, "counter-inc", "1"} }},
		{"fill-data before the config lock", "img", nil, func(w *walker) []string { return []string{"fill-data"} }},
		{"fill-data after the data lock", "both", nil, func(w *walker) []string { return []string{"fill-data"} }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWalker(t)
			w.enter(c.state)
			if c.setup != nil {
				c.setup(w)
			}
			args := c.args(w)
			s := w.snap()
			rc, out, errOut := w.r.run(t, append([]string{"-allow", w.allow}, args...)...)
			if rc != exitRefused || !strings.Contains(errOut, "refused") {
				t.Fatalf("rc %d, want refused\n%s%s", rc, out, errOut)
			}
			if !w.onlyReads(s) || !w.unchanged(s) {
				t.Fatalf("something was sent or changed: % x", w.r.chip.Pkts[s.pkts:])
			}
		})
	}
	// lock-config without -expect-crc is a usage error before the bus
	w := newWalker(t)
	w.image()
	s := w.snap()
	if rc, _, _ := w.r.run(t, "-allow", w.allow, "-serial", w.sn, "-byte17", w.r.b17(), "lock-config"); rc != exitUsage || w.r.opens != s.opens {
		t.Fatalf("lock-config without -expect-crc: rc %d", rc)
	}
}

// The config zone changing between se-lab's read and its Lock is caught twice: by the re-read in the same sequence
// and, if that were missing, by the chip's CRC check. Any of the four blocks.
func TestLockConfigCatchesAChangeInBetween(t *testing.T) {
	for _, off := range []int{17, 60, 84, 127} {
		w := newWalker(t)
		w.image()
		crc := crcOf(w)
		// after the tool has read the zone the first time (Info + 4 config blocks), another bus master changes a
		// byte (UpdateExtra needs no authorisation; before the lock so does a plain Write)
		w.r.mutateAfter = 5
		w.r.mutate = func(c *fakechip.Chip) { c.Config[off] ^= 0x01 }
		rc, out, errOut := w.r.run(t, "-allow", w.allow, "-serial", w.sn, "-byte17", w.r.b17(), "-expect-crc", crc, "lock-config")
		if rc != exitRefused || !strings.Contains(errOut, "changed since it was read") {
			t.Fatalf("byte %d: rc %d\n%s%s", off, rc, out, errOut)
		}
		if len(forGoodPkts(w.r.chip.Pkts)) != 0 || w.r.chip.Config[se608.LockConfigByte] != 0x55 {
			t.Fatalf("byte %d: the Lock was sent although the zone had changed", off)
		}
	}
}

// lockCases are the three Lock commands, each from the state where it goes out.
var lockCases = []struct {
	name, key, state string
	nth              int // the Lock is command packet number nth of the invocation
}{
	{"lock-config", "lock_config", "img", 10}, // Info, 4 reads, 4 re-reads, Lock
	{"lock-data", "lock_data", "filled", 6},   // Info, 4 reads, Lock
	{"lock-slot", "lock_slot6", "both", 6},
}

// The result of a Lock is what the chip's own bytes say afterwards, for all three Locks and in every way the
// command itself can go wrong (code review PR D2 A-m3, A-m4, B-M3).
func TestLockResultComesFromTheChipsBytes(t *testing.T) {
	for _, lc := range lockCases {
		run := func(prep func(*walker)) (int, string, *walker) {
			w := newWalker(t)
			w.enter(lc.state)
			inv := w.invocation(lc.name, "-serial", w.sn)
			prep(w)
			rc, out, _ := w.r.run(t, append([]string{"-allow", w.allow}, inv...)...)
			return rc, out, w
		}
		res := func(out string) string { return field(t, out, lc.key+"_result") }

		// success status, but nothing locked
		rc, out, _ := run(func(w *walker) { w.r.chip.LockLies = true })
		if rc != exitFail || res(out) != "NOT_LOCKED_after_success_status" {
			t.Fatalf("%s, a chip that answers success without locking: rc %d\n%s", lc.name, rc, out)
		}
		// the chip locked, the answer was garbled
		rc, out, w := run(func(w *walker) {
			w.r.mutateAfter = lc.nth - 1
			w.r.mutate = func(c *fakechip.Chip) { c.CorruptNext = true }
		})
		if rc != exitFail || res(out) != "LOCKED_answer_lost" {
			t.Fatalf("%s, answer lost: rc %d\n%s", lc.name, rc, out)
		}
		if n := len(forGoodPkts(w.r.chip.Pkts)); n == 0 {
			t.Fatalf("%s: control: no Lock reached the chip", lc.name)
		}
		// the chip locked, and then cannot be read
		rc, out, _ = run(func(w *walker) {
			w.r.mutateAfter = lc.nth - 1
			w.r.mutate = func(c *fakechip.Chip) { c.DropWakes = 1000 }
		})
		if rc != exitFail || res(out) != "UNKNOWN_read_back_failed" {
			t.Fatalf("%s, no read-back: rc %d\n%s", lc.name, rc, out)
		}
		// the chip takes longer than the vendor table's 35 ms to answer a Lock (the 608B's Lock timing is not the
		// table's): the answer is still read, and the result is a plain "locked"
		rc, out, _ = run(func(w *walker) { w.r.chip.SlowLockPolls = 150 })
		if rc != exitOK || res(out) != "locked" {
			t.Fatalf("%s, a Lock that answers after 150 polls: rc %d\n%s", lc.name, rc, out)
		}
		// the read-back is retried: one failed wake after the Lock does not hide the result
		rc, out, _ = run(func(w *walker) {
			w.r.mutateAfter = lc.nth - 1
			w.r.mutate = func(c *fakechip.Chip) { c.DropWakes = 3 }
		})
		if rc != exitOK || res(out) != "locked" {
			t.Fatalf("%s, a read-back that needs a second try: rc %d\n%s", lc.name, rc, out)
		}
	}
}

// A failure of the re-read before the Lock is reported as that, not as the Lock's status, and nothing is sent.
func TestLockConfigReReadFailure(t *testing.T) {
	w := newWalker(t)
	w.image()
	crc := crcOf(w)
	w.r.mutateAfter = 6 // the second block of the re-read
	w.r.mutate = func(c *fakechip.Chip) { c.CorruptNext = true }
	rc, out, errOut := w.r.run(t, "-allow", w.allow, "-serial", w.sn, "-byte17", w.r.b17(), "-expect-crc", crc, "lock-config")
	if rc != exitRefused || !strings.Contains(errOut, "could not be read again") || strings.Contains(out, "_result=") {
		t.Fatalf("rc %d\n%s%s", rc, out, errOut)
	}
	if len(forGoodPkts(w.r.chip.Pkts)) != 0 {
		t.Fatal("the Lock was sent after a failed re-read")
	}
}

// A marginal bus shows in soak before anything irreversible is attempted.
func TestSoakCountsErrors(t *testing.T) {
	w := newWalker(t)
	w.r.mutateAfter = 5
	w.r.mutate = func(c *fakechip.Chip) { c.DropWakes = 2 } // one round finds the chip silent
	rc, out, _ := w.r.run(t, "soak", "4")
	if rc != exitFail || !strings.Contains(out, "soak_rounds=4") || !strings.Contains(out, "soak_errors=1") {
		t.Fatalf("rc %d\n%s", rc, out)
	}
	w = newWalker(t)
	w.r.mutateAfter = 5
	w.r.mutate = func(c *fakechip.Chip) { c.Config[40] ^= 1 } // a read that differs from the first
	if rc, out, _ = w.r.run(t, "soak", "3"); rc != exitFail || !strings.Contains(out, "soak_differ=3") {
		t.Fatalf("rc %d\n%s", rc, out)
	}
}

// E5's two possible answers: the OTP zone takes a write before the data lock, or it does not. Either way the tool
// reports it, and a data lock prepared with the wrong idea of the OTP content is refused by the chip.
func TestOTPReadOnlyIsReportedNotFatal(t *testing.T) {
	w := newWalker(t)
	w.configLocked()
	w.r.chip.OTPReadOnly = true
	for i := range w.r.chip.OTP {
		w.r.chip.OTP[i] = 0xFF // what a chip whose OTP cannot be written in this window might hold
	}
	w.run(exitOK, []string{"fill-data"}, "otp_write_block0=status_0f", "fill_data_failed_slots=0")
	// with the wrong idea of the OTP content the chip refuses the lock and nothing is locked ...
	w.forGood(exitFail, []string{"lock-data"}, "lock_data_result=status_0f", "lock_data_after=55")
	// ... and with the right one it locks
	w.forGood(exitOK, []string{"-otp-fill", "ff", "lock-data"}, "lock_data_result=locked")
}

// E6's "不通過時": a chip that refuses the 4-byte tail write of a secret slot (the reading of facts §2.1 that the
// default fake does NOT model). fill-data must say which slots failed and exit non-zero, and the data lock prepared
// for the full content is then refused by the chip.
func TestSecretTailWriteRefusedIsReported(t *testing.T) {
	w := newWalker(t)
	w.configLocked()
	w.r.chip.SecretTailReadOnly = true
	out := w.run(exitFail, []string{"fill-data"}, "slot5=FAILED", "slot3=FAILED", "slot8=written_416_bytes", "slot6=written_36_bytes")
	if field(t, out, "fill_data_failed_slots") == "0" {
		t.Fatalf("fill-data reported no failed slot\n%s", out)
	}
}

// Which policy an invocation runs under is decided in one place, from the command table and the flags: read-only
// commands get the read-only policy; every allow-listed command the rewritable one — a for-good command in a dry
// run included; only a for-good command, not dry, with the serial typed, gets the for-good policy.
func TestInvocationPolicyTier(t *testing.T) {
	for _, name := range commandNamesSorted() {
		w := newWalker(t)
		w.enter(samples[name].state)
		inv := w.invocation(name)
		want := "read-only"
		if commands[name].gated {
			want = "rewritable"
		}
		w.r.run(t, append([]string{"-allow", w.allow}, inv...)...)
		if commands[name].forGood {
			if w.r.tier != "" {
				t.Fatalf("%s without -serial ran its command (tier %q)", name, w.r.tier)
			}
			w.r.run(t, append([]string{"-allow", w.allow, "-dry-run"}, inv...)...)
			if w.r.tier != "rewritable" {
				t.Fatalf("%s -dry-run: tier %q, want rewritable", name, w.r.tier)
			}
			w.r.run(t, append([]string{"-allow", w.allow, "-dry-run", "-serial", w.sn}, inv...)...)
			if w.r.tier != "rewritable" {
				t.Fatalf("%s -dry-run -serial: tier %q, want rewritable", name, w.r.tier)
			}
			w.r.run(t, append([]string{"-allow", w.allow, "-serial", w.sn}, inv...)...)
			if w.r.tier != "for-good" {
				t.Fatalf("%s -serial: tier %q, want for-good", name, w.r.tier)
			}
			continue
		}
		if w.r.tier != want {
			t.Fatalf("%s: tier %q, want %q", name, w.r.tier, want)
		}
		// -serial on a command that is not for-good changes nothing
		w.r.run(t, append([]string{"-allow", w.allow, "-serial", w.sn}, inv...)...)
		if w.r.tier != want {
			t.Fatalf("%s -serial: tier %q, want %q", name, w.r.tier, want)
		}
	}
}

// The three policies themselves, command by command.
func TestInvocationPolicies(t *testing.T) {
	c := func(op, p1 byte, p2 uint16, n int) se608.Cmd {
		return se608.Cmd{Op: op, P1: p1, P2: p2, Data: make([]byte, n)}
	}
	cases := []struct {
		name              string
		cmd               se608.Cmd
		ro, rewr, forGood bool
	}{
		{"Info", c(se608.OpInfo, 0, 0, 0), true, true, true},
		{"Read config", c(se608.OpRead, 0x80, 0, 0), true, true, true},
		{"Read data", c(se608.OpRead, 0x82, 0x40, 0), true, true, true},
		{"GenKey public", c(se608.OpGenKey, 0x00, 4, 0), true, true, true},
		{"GenKey create", c(se608.OpGenKey, 0x04, 4, 0), false, true, true},
		{"Counter read", c(se608.OpCounter, 0x00, 1, 0), true, true, true},
		{"Counter increment", c(se608.OpCounter, 0x01, 1, 0), false, false, true},
		{"Lock config", c(se608.OpLock, 0x00, 0x9022, 0), false, false, true},
		{"Lock data", c(se608.OpLock, 0x01, 0xbe96, 0), false, false, true},
		{"Lock slot 6", c(se608.OpLock, 0x1a, 0, 0), false, false, true},
		{"UpdateExtra byte 85", c(se608.OpUpdateExtra, 0x01, 0xa0, 0), false, false, true},
		{"UpdateExtra decrement", c(se608.OpUpdateExtra, 0x02, 0, 0), false, false, true},
		{"Random", c(se608.OpRandom, 0, 0, 0), false, true, true},
		{"Write data", c(se608.OpWrite, 0x82, 0x40, 32), false, true, true},
		{"Write OTP", c(se608.OpWrite, 0x81, 0, 32), false, true, true},
		{"Write config word 17", c(se608.OpWrite, 0x00, 17, 4), false, true, true},
		{"Write config word 15 (a counter word)", c(se608.OpWrite, 0x00, 15, 4), false, true, true},
		{"Write config word 4", c(se608.OpWrite, 0x00, 4, 4), false, true, true},
		{"Write config word 3", c(se608.OpWrite, 0x00, 3, 4), false, false, false},
		{"Write config word 0", c(se608.OpWrite, 0x00, 0, 4), false, false, false},
		{"Write config word 21 (lock bytes)", c(se608.OpWrite, 0x00, 21, 4), false, false, false},
		{"Write config word 20", c(se608.OpWrite, 0x00, 20, 4), false, true, true},
		{"Write config word 22", c(se608.OpWrite, 0x00, 22, 4), false, true, true},
		{"Write config block 0", c(se608.OpWrite, 0x80, 0x00, 32), false, false, false},
		{"Write config block 2 (holds the lock bytes)", c(se608.OpWrite, 0x80, 0x10, 32), false, false, false},
		{"Write config block 1", c(se608.OpWrite, 0x80, 0x08, 32), false, true, true},
		{"Write config block 3", c(se608.OpWrite, 0x80, 0x18, 32), false, true, true},
		{"MAC", c(se608.OpMAC, 0, 3, 32), false, true, true},
		{"PrivWrite", c(se608.OpPrivWrite, 0, 4, 68), false, true, true},
		{"DeriveKey (on no list)", c(se608.OpDeriveKey, 0, 3, 0), false, false, false},
	}
	for _, k := range cases {
		for name, got := range map[string]bool{"read-only": policies["read-only"](k.cmd) == nil, "rewritable": policies["rewritable"](k.cmd) == nil, "for-good": policies["for-good"](k.cmd) == nil} {
			want := map[string]bool{"read-only": k.ro, "rewritable": k.rewr, "for-good": k.forGood}[name]
			if got != want {
				t.Errorf("%s under the %s policy: allowed = %v, want %v", k.name, name, got, want)
			}
		}
	}
}

// The policy installed for the command — not only its name — is the one the tier says: a Lock is refused under
// anything but the for-good tier (round 2, B's A01: the first Dev built with the for-good policy while the name
// stayed "rewritable" went unnoticed).
func TestInstalledPolicyMatchesTier(t *testing.T) {
	lock := se608.LockConfigCmd(0x9022)
	for _, name := range commandNamesSorted() {
		w := newWalker(t)
		w.enter(samples[name].state)
		inv := w.invocation(name)
		runs := [][]string{{"-allow", w.allow}, {"-allow", w.allow, "-dry-run"}, {"-allow", w.allow, "-serial", w.sn}}
		for _, pre := range runs {
			w.r.run(t, append(append([]string{}, pre...), inv...)...)
			if w.r.tier == "" {
				continue
			}
			if w.r.installed == nil {
				t.Fatalf("%s %v: no policy reported", name, pre)
			}
			sendsLock := w.r.installed(lock) == nil
			if sendsLock != (w.r.tier == "for-good") {
				t.Fatalf("%s %v: tier %q but the installed policy lets a Lock through = %v", name, pre, w.r.tier, sendsLock)
			}
		}
	}
}

func TestToolRevReportsADirtyTree(t *testing.T) {
	set := func(kv ...string) []debug.BuildSetting {
		var s []debug.BuildSetting
		for i := 0; i < len(kv); i += 2 {
			s = append(s, debug.BuildSetting{Key: kv[i], Value: kv[i+1]})
		}
		return s
	}
	for _, c := range []struct {
		in   []debug.BuildSetting
		want string
	}{
		{set("vcs.revision", "7aea4be0", "vcs.modified", "false"), "7aea4be0"},
		{set("vcs.revision", "7aea4be0", "vcs.modified", "true"), "7aea4be0+modified"},
		{set("GOARCH", "arm64"), "unknown"},
		{nil, "unknown"},
	} {
		if got := toolRevFrom(c.in); got != c.want {
			t.Errorf("toolRevFrom(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

// afterLock's two branches the walk does not reach (round 2, B's B01, B04).
func TestAfterLockRemainingBranches(t *testing.T) {
	// the chip locks and still answers an error status: reported as both, exit 1
	for _, lc := range lockCases {
		w := newWalker(t)
		w.enter(lc.state)
		inv := w.invocation(lc.name, "-serial", w.sn)
		w.r.chip.LockThenRefuse = true
		rc, out, _ := w.r.run(t, append([]string{"-allow", w.allow}, inv...)...)
		if rc != exitFail || field(t, out, lc.key+"_result") != "status_0f_but_LOCKED" {
			t.Fatalf("%s, a chip that locks and answers 0x0F: rc %d\n%s", lc.name, rc, out)
		}
	}
	// se-lab's own policy refusing the Lock: refused (exit 3), no result line, nothing sent
	w := newWalker(t)
	w.bothLocked()
	var out, errOut bytes.Buffer
	b, _, _ := env{}.openBusFor(w.r)
	c := &ctx{e: env{out: &out, errOut: &errOut, sleep: func(time.Duration) {}}, d: se608.NewPolicy(b, policies[tierRewritable])}
	s := w.snap()
	err := c.d.Do(func(s *se608.Session) error { _, err := s.Exec(se608.LockSlotCmd(6)); return err })
	if rc := c.afterLock("lock_slot6", err, func(cfg [se608.ConfigLen]byte) bool { return se608.SlotLocked(cfg, 6) }); rc != exitRefused {
		t.Fatalf("afterLock on a policy refusal: rc %d, want %d\n%s%s", rc, exitRefused, out.String(), errOut.String())
	}
	if strings.Contains(out.String(), "_result=") || len(forGoodPkts(w.r.chip.Pkts[s.pkts:])) != 0 {
		t.Fatalf("a policy refusal printed a result or sent a Lock\n%s", out.String())
	}
}

// Counter increment and UpdateExtra wait as long as a Lock, and after a lost answer they read the state back and
// say what happened instead of leaving the operator to guess (round 2 B-m1). Nothing is resent.
func TestForGoodAnswersAreNotGivenUpEarly(t *testing.T) {
	// slow: still read, plain result
	w := newWalker(t)
	w.bothLocked()
	w.r.chip.SlowLockPolls = 300
	w.forGood(exitOK, []string{"counter-inc", "1"}, "counter1_inc_result=incremented", "counter1_after_inc_le=1")
	w.forGood(exitOK, []string{"update-extra", "1", "a0"}, "update_extra_mode1=status_00", "byte85_after=a0")

	// lost answer to the increment: the counter is read back, and the result says it moved
	w = newWalker(t)
	w.bothLocked()
	w.r.mutateAfter = 6 // Info, 4 config reads, the "before" read, then the increment
	w.r.mutate = func(c *fakechip.Chip) { c.CorruptNext = true }
	out := w.forGood(exitFail, []string{"counter-inc", "1"}, "counter1_inc_result=INCREMENTED_answer_lost", "counter1_read_back_le=1")
	if w.r.chip.Counters != [2]uint32{0, 1} || strings.Count(strings.Join(func() []string {
		var s []string
		for _, p := range forGoodPkts(w.r.chip.Pkts) {
			s = append(s, hex.EncodeToString(p))
		}
		return s
	}(), " "), "2401") != 1 {
		t.Fatalf("counters %v, or the increment was sent more than once\n%s", w.r.chip.Counters, out)
	}

	// lost answer to UpdateExtra: the bytes say it was written
	w = newWalker(t)
	w.bothLocked()
	w.r.mutateAfter = 5 // Info, 4 config reads, then UpdateExtra
	w.r.mutate = func(c *fakechip.Chip) { c.CorruptNext = true }
	w.forGood(exitFail, []string{"update-extra", "1", "a0"}, "update_extra_result=WRITTEN_answer_lost", "byte85_after=a0")
}
