//go:build linux

// se-lab — the rig tool for the ATECC608B experiments (docs/design/255-608b-config.md §8; 255-608b-impl.md §5).
// A developer tool: it is not built into any image (feed/batman-prov/Makefile builds only batman-provhelper and
// batman-provd, and cmd/deps_test.go keeps se608/lab out of both); it runs from tmpfs on the rig. Build it static:
//
//	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o se-lab ./cmd/se-lab
//
// ⚠️ This build CAN lock: lock-config, lock-data and lock-slot change a chip for good, and so do counter-inc and
// update-extra. Each of them needs the chip on the -allow list AND its full serial typed again in -serial, prints
// the exact packet first, and stops there with -dry-run. A Lock that skips the chip's CRC check cannot be sent by
// any command (se608 refuses it). Only sacrificial chips on the rig (§8.0): never a chip that is to become a node.
//
// No chip:
//
//	se-lab -byte17 HH image                 the variant image (bytes 16-127) and its SHA-256
//
// Read-only:
//
//	info | dump | -byte17 HH compare        revision, serial, lock bytes | config zone | compare with the image
//	soak N                                  N x (wake, Info, read the config zone, compare with the first read)
//	pubkey SLOT                             GenKey mode 0: the public key of a private-key slot
//	counter-read N                          Counter N (0 or 1)
//	read ZONE P2 LEN                        Read; ZONE config|otp|data, P2 the address in hex, LEN 4 or 32
//	slot-read SLOT                          a whole data slot (where its configuration allows a clear read)
//
// On an -allow listed chip (rewritable until a lock makes it permanent):
//
//	random                                  Random mode 0                                           (E2, E4)
//	data-write SLOT                         32 bytes of A5 to SLOT block 0; prints the status       (E2, E6, E13)
//	-byte17 HH write-image                  write the differing config words, read back, compare    (E3)
//	config-write WORD HEX8                  one 4-byte config word                                  (E4, E11)
//	write ZONE P2 HEX                       Write, 4 or 32 bytes                                    (E5)
//	priv-write SLOT                         clear PrivWrite of a test key                           (E6)
//	fill-data                               the test content into every non-private slot, zeros into OTP (E5, E6)
//	checkmac SLOT [wrong]                   CheckMac mode 0 with the product's OtherData            (E6, E8)
//	genkey SLOT                             GenKey mode 4: a new private key                        (E17, E10)
//	sign SLOT | sign-internal SLOT          pass-through Nonce + external Sign, verified | random Nonce + internal
//	mac SLOT | gendig-mac SLOT | hmac SLOT  the MAC-class commands on a slot                        (E8)
//	kdf prf|hkdf SLOT [TARGET] | aes SLOT   KDF from a slot (to the output, or to slot TARGET) | AES (E8, E9)
//	ecdh SLOT clear|compat|tempkey|enc|slot ECDH with a fresh host key; a clear result is checked   (E9, E10)
//	slot-write SLOT HEX                     HEX, zero-padded to the slot size                       (E15)
//	raw OP P1 P2 [HEX]                      any listed opcode (not Lock, Counter, UpdateExtra)
//
// For good (-allow AND -serial; -dry-run prints and stops):
//
//	-byte17 HH -expect-crc HHHH lock-config  Lock(config) with the CRC; refuses unless the chip holds the image and
//	                                         the CRC equals the one computed independently beforehand   (E4)
//	[-otp-fill HH] lock-data                 Lock(data + OTP) with the CRC of what fill-data wrote      (E6)
//	lock-slot SLOT                           Lock one slot: 4, 5 or 6 only, both zones locked           (E17, E13)
//	counter-inc 1                            Counter[1] + 1 (Counter[0] is never touched)               (E11)
//	update-extra MODE VAL                    UpdateExtra: MODE 0 byte 84, 1 byte 85, 2 decrement; both
//	                                         zones locked                                               (E12, E11)
//
// -bus /dev/i2c-1. The chip lock is an exclusive flock on the bus device itself (se608.OpenI2C). -allow FILE is the
// sacrificial chip list, one 18-hex-digit serial per line. -byte17 is the blank byte 17 E1 recorded (§4 keeps it).
// Every command that reads the chip stops (exit 3) when the revision is not 00 00 60 03 (§8.0). The test content
// of fill-data is derived from the chip's serial and is not a secret: no real claim secret ever goes through
// se-lab.
//
// Every invocation prints tool_rev (the commit the binary was built from), then revision, serial and the two lock
// bytes. The outcome of a Lock is the line <command>_result=: "locked" only when the chip's own bytes say so.
//
// Exit: 0 done (compare: equal); 1 chip or bus failure, or a chip status where the command needed success; 2 usage;
// 3 refused before anything was sent; 4 compare found differences. A command whose point is to see what the chip
// answers (data-write, checkmac, mac, ...) prints the status and exits 0: the runbook judges it.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"time"

	"batman-prov/se608"
	"batman-prov/se608/lab"
)

const (
	exitOK      = 0
	exitFail    = 1
	exitUsage   = 2
	exitRefused = 3
	exitDiffers = 4
)

// env is what main wires to the real system; tests give a fake chip.
type env struct {
	openBus func(path string) (se608.Bus, func(), error)
	out     io.Writer
	errOut  io.Writer
	sleep   func(time.Duration)        // nil = time.Sleep; the wait between read-back attempts after a Lock
	tier    func(string, se608.Policy) // nil in the tool; tests see the tier name AND the policy installed
	clock   func(*se608.Dev)           // nil in the tool; tests give every Dev a fake clock
}

func main() {
	e := env{
		openBus: func(path string) (se608.Bus, func(), error) {
			b, err := se608.OpenI2C(path)
			if err != nil {
				return nil, nil, err
			}
			return b, func() { _ = b.Close() }, nil
		},
		out:    os.Stdout,
		errOut: os.Stderr,
	}
	os.Exit(run(os.Args[1:], e))
}

// ctx is one invocation after the chip was opened and identified.
type ctx struct {
	e       env
	d       *se608.Dev
	cfg     [se608.ConfigLen]byte
	sn      [9]byte
	args    []string
	img     [se608.ConfigLen]byte
	byte17  byte
	dry     bool
	expect  *uint16
	otpFill byte
}

func (c *ctx) outf(f string, a ...any) { fmt.Fprintf(c.e.out, f, a...) }
func (c *ctx) errf(f string, a ...any) { fmt.Fprintf(c.e.errOut, "se-lab: "+f+"\n", a...) }
func (c *ctx) refuse(f string, a ...any) int {
	c.errf("refused: "+f, a...)
	return exitRefused
}

// command describes one sub-command. args is the number of arguments it takes (min, max). image: needs -byte17.
// slots: the arguments that must be 0-15.
// gated: acts only on a chip on the -allow list. forGood: changes the chip permanently, so it also needs -serial.
type command struct {
	args    [2]int
	slots   []int // which arguments are slot numbers: checked before the bus is opened
	image   bool
	gated   bool
	forGood bool
	run     func(*ctx) int
}

var commands map[string]command

func init() {
	commands = map[string]command{
		"info":          {run: func(*ctx) int { return exitOK }},
		"dump":          {run: cmdDump},
		"compare":       {image: true, run: cmdCompare},
		"soak":          {args: [2]int{1, 1}, run: cmdSoak},
		"pubkey":        {args: [2]int{1, 1}, slots: []int{0}, run: cmdPubKey},
		"counter-read":  {args: [2]int{1, 1}, run: cmdCounterRead},
		"read":          {args: [2]int{3, 3}, run: cmdRead},
		"slot-read":     {args: [2]int{1, 1}, slots: []int{0}, run: cmdSlotRead},
		"random":        {gated: true, run: cmdRandom},
		"data-write":    {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdDataWrite},
		"write-image":   {image: true, gated: true, run: cmdWriteImage},
		"config-write":  {args: [2]int{2, 2}, gated: true, run: cmdConfigWrite},
		"write":         {args: [2]int{3, 3}, gated: true, run: cmdWrite},
		"priv-write":    {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdPrivWrite},
		"fill-data":     {gated: true, run: cmdFillData},
		"checkmac":      {args: [2]int{1, 2}, slots: []int{0}, gated: true, run: cmdCheckMac},
		"genkey":        {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdGenKey},
		"sign":          {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdSign},
		"sign-internal": {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdSignInternal},
		"mac":           {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdMAC},
		"gendig-mac":    {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdGenDigMAC},
		"hmac":          {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdHMAC},
		"kdf":           {args: [2]int{2, 3}, slots: []int{1, 2}, gated: true, run: cmdKDF},
		"aes":           {args: [2]int{1, 1}, slots: []int{0}, gated: true, run: cmdAES},
		"ecdh":          {args: [2]int{2, 2}, slots: []int{0}, gated: true, run: cmdECDH},
		"slot-write":    {args: [2]int{2, 2}, slots: []int{0}, gated: true, run: cmdSlotWrite},
		"raw":           {args: [2]int{3, 4}, gated: true, run: cmdRaw},
		"lock-config":   {image: true, gated: true, forGood: true, run: cmdLockConfig},
		"lock-data":     {gated: true, forGood: true, run: cmdLockData},
		"lock-slot":     {args: [2]int{1, 1}, slots: []int{0}, gated: true, forGood: true, run: cmdLockSlot},
		"counter-inc":   {args: [2]int{1, 1}, gated: true, forGood: true, run: cmdCounterInc},
		"update-extra":  {args: [2]int{2, 2}, gated: true, forGood: true, run: cmdUpdateExtra},
	}
}

// The three policies of one invocation (code review PR D2 A-M1, A-M2, B-M2, B-m6). Which one a command gets is
// decided in run() from the command table and the flags, in one place; a command function cannot widen it.
//
//   - readOnly: commands that need no allow list. Info, plain Read, GenKey in public-key mode, Counter read.
//   - rewritable: an -allow listed chip. Everything on lab's list EXCEPT what cannot be undone (lab.ForGood) and
//     except a Write that addresses the config words no experiment writes: 0-3 (serial, revision) and 21 (bytes
//     84-87: UserExtra, UserExtraAdd and the two lock bytes). That Write cannot change those bytes is the vendor's
//     statement, not a measurement on our chip.
//   - forGood: rewritable plus Lock, UpdateExtra and Counter increment. Only for a for-good command, not in a dry
//     run, on a listed chip whose serial was typed again in -serial.
func policyReadOnly(c se608.Cmd) error {
	switch {
	case c.Op == se608.OpInfo && c.P1 == 0,
		c.Op == se608.OpRead && c.P1&0x7C == 0,
		c.Op == se608.OpGenKey && c.P1 == se608.GenKeyPublic,
		c.Op == se608.OpCounter && c.P1 == 0:
		return nil
	}
	return fmt.Errorf("%w: a read-only se-lab command tried to send opcode 0x%02x mode 0x%02x", se608.ErrRefused, c.Op, c.P1)
}

func protectedConfigWrite(c se608.Cmd) bool {
	if c.Op != se608.OpWrite || se608.Zone(c.P1&0x03) != se608.ZoneConfig {
		return false
	}
	block, word := int(c.P2>>3)&0x03, int(c.P2&0x07)
	if c.P1&0x80 != 0 { // 32 bytes: block 0 holds words 0-3, block 2 holds word 21
		return block == 0 || block == 2
	}
	w := block*8 + word
	return w <= 3 || w == 21
}

func policyRewritable(c se608.Cmd) error {
	if lab.ForGood(c) {
		return fmt.Errorf("%w: opcode 0x%02x mode 0x%02x changes a chip for good: not in this invocation", se608.ErrRefused, c.Op, c.P1)
	}
	if protectedConfigWrite(c) {
		return fmt.Errorf("%w: a Write to config words 0-3 or 21 (serial, revision, lock bytes)", se608.ErrRefused)
	}
	return lab.Policy(c)
}

func policyForGood(c se608.Cmd) error {
	if protectedConfigWrite(c) {
		return fmt.Errorf("%w: a Write to config words 0-3 or 21 (serial, revision, lock bytes)", se608.ErrRefused)
	}
	return lab.Policy(c)
}

// The policy tiers by name; run() picks a name, the policy comes from this table.
const (
	tierReadOnly   = "read-only"
	tierRewritable = "rewritable"
	tierForGood    = "for-good"
)

var policies = map[string]se608.Policy{tierReadOnly: policyReadOnly, tierRewritable: policyRewritable, tierForGood: policyForGood}

func (c *ctx) newDev(b se608.Bus, p se608.Policy) *se608.Dev {
	d := se608.NewPolicy(b, p)
	if c.e.clock != nil {
		c.e.clock(d)
	}
	return d
}

// toolRev is the VCS revision this binary was built from ("unknown" in a test binary or a build without VCS
// stamping): printed in every header, so every saved output says which tool produced it.
func toolRev() string {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	return toolRevFrom(bi.Settings)
}

// toolRevFrom is toolRev's parsing, separate so a test can feed it a dirty build's settings.
func toolRevFrom(settings []debug.BuildSetting) string {
	rev, dirty := "unknown", ""
	for _, s := range settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value
		case "vcs.modified":
			if s.Value == "true" {
				dirty = "+modified"
			}
		}
	}
	return rev + dirty
}

func commandNames() string {
	n := []string{"image"}
	for k := range commands {
		n = append(n, k)
	}
	sort.Strings(n)
	return strings.Join(n, ", ")
}

func run(args []string, e env) int {
	fs := flag.NewFlagSet("se-lab", flag.ContinueOnError)
	fs.SetOutput(e.errOut)
	bus := fs.String("bus", "/dev/i2c-1", "i2c-dev node")
	allow := fs.String("allow", "", "file of sacrificial chip serials (18 hex digits per line)")
	b17 := fs.String("byte17", "", "blank config byte 17 recorded in E1 (2 hex digits)")
	serial := fs.String("serial", "", "the chip's full serial, typed again, for a command that changes it for good")
	expect := fs.String("expect-crc", "", "lock-config: the config CRC computed independently beforehand (4 hex digits)")
	otpFill := fs.String("otp-fill", "00", "lock-data: the byte the OTP zone holds (00 after fill-data wrote it)")
	dry := fs.Bool("dry-run", false, "print what a for-good command would send, and stop")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	rest := fs.Args()
	if len(rest) == 0 {
		return usage(e, "command missing (%s)", commandNames())
	}
	name := rest[0]
	cmd, known := commands[name]
	if name == "image" {
		cmd, known = command{image: true}, true
	}
	if !known {
		return usage(e, "unknown command %q (%s)", name, commandNames())
	}
	if n := len(rest) - 1; n < cmd.args[0] || n > cmd.args[1] {
		return usage(e, "%s takes %d to %d arguments, got %d", name, cmd.args[0], cmd.args[1], n)
	}
	c := &ctx{e: e, args: rest[1:], dry: *dry}
	for _, i := range cmd.slots {
		if i < len(c.args) {
			if _, ok := c.slotArg(i); !ok {
				return exitUsage
			}
		}
	}

	if cmd.image {
		v, err := hex.DecodeString(*b17)
		if err != nil || len(v) != 1 {
			return usage(e, "%s needs -byte17 (the E1 value, 2 hex digits), got %q", name, *b17)
		}
		c.byte17 = v[0]
	}
	c.img = se608.Image(true, c.byte17)
	if name == "image" {
		printImage(e, c.img)
		return exitOK
	}
	if v, err := hex.DecodeString(*otpFill); err != nil || len(v) != 1 {
		return usage(e, "-otp-fill %q is not 2 hex digits", *otpFill)
	} else {
		c.otpFill = v[0]
	}
	if *expect != "" {
		v, err := strconv.ParseUint(*expect, 16, 16)
		if err != nil || len(*expect) != 4 {
			return usage(e, "-expect-crc %q is not 4 hex digits", *expect)
		}
		x := uint16(v)
		c.expect = &x
	}
	if name == "lock-config" && c.expect == nil {
		return usage(e, "lock-config needs -expect-crc (the CRC from the independent check, 255-608b-config.md §8.3)")
	}

	var allowed map[[9]byte]bool
	if cmd.gated {
		if *allow == "" {
			fmt.Fprintln(e.errOut, "se-lab: refused: "+name+" needs -allow (the sacrificial chip list)")
			return exitRefused
		}
		var err error
		if allowed, err = readAllow(*allow); err != nil {
			fmt.Fprintln(e.errOut, "se-lab:", err)
			return exitUsage
		}
	}
	if cmd.forGood && !c.dry && *serial == "" {
		fmt.Fprintln(e.errOut, "se-lab: refused: "+name+" changes the chip for good: type its full serial in -serial (or use -dry-run)")
		return exitRefused
	}

	b, closeBus, err := e.openBus(*bus)
	if errors.Is(err, se608.ErrBusy) {
		fmt.Fprintln(e.errOut, "se-lab: refused:", err)
		return exitRefused
	}
	if err != nil {
		fmt.Fprintln(e.errOut, "se-lab:", err)
		return exitFail
	}
	defer closeBus()
	tier := tierReadOnly
	if cmd.gated {
		tier = tierRewritable
	}
	installed := policies[tier]
	c.d = c.newDev(b, installed)

	var rev [4]byte
	if err := c.d.Do(func(s *se608.Session) (err error) { rev, err = s.Revision(); return }); err != nil {
		fmt.Fprintln(e.errOut, "se-lab: info:", err)
		return exitFail
	}
	if c.cfg, err = c.d.ReadConfig(); err != nil {
		fmt.Fprintln(e.errOut, "se-lab: read config:", err)
		return exitFail
	}
	c.sn = se608.Serial(c.cfg)
	c.outf("tool_rev=%s\nrevision=%s\nserial=%s\nlock_config=%02x\nlock_data=%02x\n",
		toolRev(), hex.EncodeToString(rev[:]), hex.EncodeToString(c.sn[:]), c.cfg[se608.LockConfigByte], c.cfg[se608.LockDataByte])
	if name == "dump" {
		cmdDump(c)
	}
	if rev != se608.Rev608B {
		return c.refuse("revision %x is not %x: stop (255-608b-config.md §8.0)", rev, se608.Rev608B)
	}
	if cmd.gated && !allowed[c.sn] {
		return c.refuse("chip %x is not on the sacrificial list", c.sn)
	}
	if cmd.forGood && !c.dry && !strings.EqualFold(*serial, hex.EncodeToString(c.sn[:])) {
		return c.refuse("-serial %q is not this chip's serial %x", *serial, c.sn)
	}
	if cmd.forGood && !c.dry {
		// Only here: a for-good command, not a dry run, the chip on the list, its serial typed again and equal.
		tier = tierForGood
		installed = policies[tier]
		c.d = c.newDev(b, installed)
	}
	if e.tier != nil {
		e.tier(tier, installed)
	}
	if name == "dump" {
		return exitOK
	}
	return cmd.run(c)
}

func cmdDump(c *ctx) int {
	for i := 0; i < se608.ConfigLen; i += 16 {
		c.outf("config[%3d]=% x\n", i, c.cfg[i:i+16])
	}
	c.outf("byte13=%02x\nbyte17=%02x\nbyte19=%02x\n", c.cfg[13], c.cfg[17], c.cfg[19])
	return exitOK
}

func cmdRandom(c *ctx) int {
	var r lab.Result
	if err := c.d.Do(func(s *se608.Session) (err error) { r, err = lab.Random(s); return }); err != nil {
		c.errf("random: %v", err)
		return exitFail
	}
	if r.IsStatus {
		c.outf("random=%s\n", r)
		return exitFail
	}
	c.outf("random=%s\n", hex.EncodeToString(r.Data))
	return exitOK
}

func cmdDataWrite(c *ctx) int {
	slot, ok := c.slotArg(0)
	if !ok {
		return exitUsage
	}
	pat := make([]byte, 32)
	for i := range pat {
		pat[i] = 0xA5
	}
	err := c.d.Do(func(s *se608.Session) error { return s.Write(se608.ZoneData, se608.DataAddr(slot, 0, 0), pat) })
	var se *se608.StatusError
	switch {
	case err == nil:
		c.outf("data_write_slot%d=accepted\n", slot)
	case errors.As(err, &se):
		c.outf("data_write_slot%d=status_%02x\n", slot, se.Code)
	default:
		c.errf("data-write: %v", err)
		return exitFail
	}
	return exitOK
}

func cmdCompare(c *ctx) int {
	c.outf("image=variant\nimage_sha256=%x\n", sha256.Sum256(c.img[16:]))
	return c.printDiff()
}

func cmdWriteImage(c *ctx) int {
	switch {
	case se608.ConfigLocked(c.cfg):
		return c.refuse("config zone is locked")
	case c.cfg[17] != c.byte17:
		return c.refuse("chip byte 17 = %02x, -byte17 = %02x", c.cfg[17], c.byte17)
	}
	c.outf("image=variant\nimage_sha256=%x\n", sha256.Sum256(c.img[16:]))
	n, err := c.d.WriteConfigImage(c.img)
	c.outf("written_words=%d\n", n)
	if err != nil {
		c.errf("write-image: %v", err)
		return exitFail
	}
	if c.cfg, err = c.d.ReadConfig(); err != nil {
		c.errf("read back: %v", err)
		return exitFail
	}
	return c.printDiff()
}

func (c *ctx) printDiff() int {
	if bad := se608.DiffImage(c.cfg, c.img); len(bad) != 0 {
		for _, i := range bad {
			c.outf("differs byte=%d chip=%02x image=%02x\n", i, c.cfg[i], c.img[i])
		}
		c.outf("compare=DIFFERENT\n")
		return exitDiffers
	}
	c.outf("compare=EQUAL\n")
	return exitOK
}

// printImage prints bytes 16-127 (the image §4 defines; bytes not written are shown as zero) and their SHA-256.
func printImage(e env, img [se608.ConfigLen]byte) {
	for i := 16; i < se608.ConfigLen; i += 16 {
		fmt.Fprintf(e.out, "image[%3d]=% x\n", i, img[i:i+16])
	}
	fmt.Fprintf(e.out, "image=variant\nimage_sha256=%x\n", sha256.Sum256(img[16:]))
}

func usage(e env, f string, a ...any) int {
	fmt.Fprintf(e.errOut, "se-lab: "+f+"\n", a...)
	return exitUsage
}

// readAllow reads the sacrificial list: one serial (18 hex digits) per line; blank lines and # comments ignored.
func readAllow(path string) (map[[9]byte]bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("allow list: %w", err)
	}
	defer f.Close()
	m := map[[9]byte]bool{}
	sc := bufio.NewScanner(f)
	for ln := 1; sc.Scan(); ln++ {
		t := strings.TrimSpace(sc.Text())
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		b, err := hex.DecodeString(t)
		if err != nil || len(b) != 9 {
			return nil, fmt.Errorf("allow list line %d: %q is not 18 hex digits", ln, t)
		}
		m[[9]byte(b)] = true
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("allow list: %w", err)
	}
	if len(m) == 0 {
		return nil, errors.New("allow list is empty")
	}
	return m, nil
}

func (c *ctx) slotArg(i int) (int, bool) {
	n, err := strconv.Atoi(c.args[i])
	if err != nil || n < 0 || n > 15 {
		c.errf("slot %q is not 0-15", c.args[i])
		return 0, false
	}
	return n, true
}

func (c *ctx) hexArg(i int, what string, sizes ...int) ([]byte, bool) {
	b, err := hex.DecodeString(c.args[i])
	if err == nil {
		for _, n := range sizes {
			if len(b) == n {
				return b, true
			}
		}
		if len(sizes) == 0 {
			return b, true
		}
	}
	c.errf("%s %q is not hex of length %v", what, c.args[i], sizes)
	return nil, false
}
