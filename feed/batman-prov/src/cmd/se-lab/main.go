//go:build linux

// se-lab — the rig tool for the ATECC608B experiments E0-E3 (docs/design/255-608b-config.md §8; 255-608b-impl.md
// §5). A developer tool: it is not built into any image (feed/batman-prov/Makefile builds only batman-provhelper and
// batman-provd); it runs from tmpfs on the rig Pi (Raspberry Pi OS Lite). Build it static:
//
//	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o se-lab ./cmd/se-lab
//
// This build has no lock command and no command that writes a byte for good (se608.Exec refuses them, Write refuses
// the OTP zone), so every change it makes to a chip can be written again until a later tool locks the config zone
// (E4).
//
//	se-lab -byte17 HH image                  print the variant image (bytes 16-127) and its SHA-256; no chip
//	se-lab [flags] info                      revision, serial, lock bytes                      (E1, read-only)
//	se-lab [flags] dump                      the 128-byte config zone in hex                   (E1, read-only)
//	se-lab [flags] -byte17 HH compare        read back and compare with the variant image      (E3, read-only)
//	se-lab [flags] -allow F random           Random, mode 0                                    (E2)
//	se-lab [flags] -allow F data-write SLOT  write 32 bytes to SLOT block 0; prints the status (E2)
//	se-lab [flags] -allow F -byte17 HH write-image   write the differing words, read back, compare (E3)
//
// -bus /dev/i2c-1. The chip lock is an exclusive flock on the bus device itself (se608.OpenI2C). -allow FILE is the
// sacrificial chip list, one 18-hex-digit serial per line; random, data-write and write-image act only on a listed
// chip. -byte17 is the blank byte 17 E1 recorded (§4 keeps it); write-image refuses a chip whose byte 17 differs.
// Every command that reads the chip stops (exit 3) when the revision is not 00 00 60 03 (§8.0).
//
// Exit: 0 done (compare: equal); 1 chip or bus failure; 2 usage; 3 refused (lock held, wrong revision, chip not on
// the list, config locked, byte 17 differs); 4 compare found differences.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"batman-prov/se608"
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

func run(args []string, e env) int {
	fs := flag.NewFlagSet("se-lab", flag.ContinueOnError)
	fs.SetOutput(e.errOut)
	bus := fs.String("bus", "/dev/i2c-1", "i2c-dev node")
	allow := fs.String("allow", "", "file of sacrificial chip serials (18 hex digits per line)")
	b17 := fs.String("byte17", "", "blank config byte 17 recorded in E1 (2 hex digits)")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	rest := fs.Args()
	if len(rest) == 0 {
		return usage(e, "command missing (image, info, dump, compare, random, data-write SLOT, write-image)")
	}
	cmd := rest[0]
	slot := -1
	switch cmd {
	case "image", "info", "dump", "compare", "random", "write-image":
		if len(rest) != 1 {
			return usage(e, "%s takes no arguments", cmd)
		}
	case "data-write":
		if len(rest) != 2 {
			return usage(e, "data-write SLOT")
		}
		n, err := strconv.Atoi(rest[1])
		if err != nil || n < 0 || n > 15 {
			return usage(e, "slot %q is not 0-15", rest[1])
		}
		slot = n
	default:
		return usage(e, "unknown command %q", cmd)
	}

	needImage := cmd == "image" || cmd == "compare" || cmd == "write-image"
	var byte17 byte
	if needImage {
		v, err := hex.DecodeString(*b17)
		if err != nil || len(v) != 1 {
			return usage(e, "%s needs -byte17 (the E1 value, 2 hex digits), got %q", cmd, *b17)
		}
		byte17 = v[0]
	}
	img := se608.Image(true, byte17)
	if cmd == "image" {
		printImage(e, img)
		return exitOK
	}

	gated := cmd == "random" || cmd == "data-write" || cmd == "write-image"
	var allowed map[[9]byte]bool
	if gated {
		if *allow == "" {
			fmt.Fprintln(e.errOut, "se-lab: refused: "+cmd+" needs -allow (the sacrificial chip list)")
			return exitRefused
		}
		var err error
		if allowed, err = readAllow(*allow); err != nil {
			fmt.Fprintln(e.errOut, "se-lab:", err)
			return exitUsage
		}
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
	d := se608.New(b)

	var rev [4]byte
	if err := d.Do(func(s *se608.Session) (err error) { rev, err = s.Revision(); return }); err != nil {
		fmt.Fprintln(e.errOut, "se-lab: info:", err)
		return exitFail
	}
	cfg, err := d.ReadConfig()
	if err != nil {
		fmt.Fprintln(e.errOut, "se-lab: read config:", err)
		return exitFail
	}
	sn := se608.Serial(cfg)
	fmt.Fprintf(e.out, "revision=%s\nserial=%s\nlock_config=%02x\nlock_data=%02x\n",
		hex.EncodeToString(rev[:]), hex.EncodeToString(sn[:]), cfg[se608.LockConfigByte], cfg[se608.LockDataByte])
	if cmd == "dump" {
		for i := 0; i < se608.ConfigLen; i += 16 {
			fmt.Fprintf(e.out, "config[%3d]=% x\n", i, cfg[i:i+16])
		}
		fmt.Fprintf(e.out, "byte13=%02x\nbyte17=%02x\nbyte19=%02x\n", cfg[13], cfg[17], cfg[19])
	}
	if rev != se608.Rev608B {
		fmt.Fprintf(e.errOut, "se-lab: refused: revision %x is not %x: stop (255-608b-config.md §8.0)\n", rev, se608.Rev608B)
		return exitRefused
	}
	if gated {
		switch {
		case !allowed[sn]:
			fmt.Fprintf(e.errOut, "se-lab: refused: chip %x is not on the sacrificial list\n", sn)
			return exitRefused
		case se608.ConfigLocked(cfg):
			fmt.Fprintln(e.errOut, "se-lab: refused: config zone is locked")
			return exitRefused
		case cmd == "write-image" && cfg[17] != byte17:
			fmt.Fprintf(e.errOut, "se-lab: refused: chip byte 17 = %02x, -byte17 = %02x\n", cfg[17], byte17)
			return exitRefused
		}
	}

	switch cmd {
	case "info", "dump":
		return exitOK
	case "random":
		var r []byte
		if err := d.Do(func(s *se608.Session) (err error) { r, err = s.Random(); return }); err != nil {
			fmt.Fprintln(e.errOut, "se-lab: random:", err)
			return exitFail
		}
		fmt.Fprintf(e.out, "random=%s\n", hex.EncodeToString(r))
		return exitOK
	case "data-write":
		pat := bytes.Repeat([]byte{0xA5}, 32)
		err := d.Do(func(s *se608.Session) error { return s.Write(se608.ZoneData, se608.DataAddr(slot, 0, 0), pat) })
		var se *se608.StatusError
		switch {
		case err == nil:
			fmt.Fprintf(e.out, "data_write_slot%d=accepted\n", slot)
		case errors.As(err, &se):
			fmt.Fprintf(e.out, "data_write_slot%d=status_%02x\n", slot, se.Code)
		default:
			fmt.Fprintln(e.errOut, "se-lab: data-write:", err)
			return exitFail
		}
		return exitOK
	}

	// compare, write-image
	fmt.Fprintf(e.out, "image=variant\nimage_sha256=%x\n", sha256.Sum256(img[16:]))
	if cmd == "write-image" {
		n, err := d.WriteConfigImage(img)
		fmt.Fprintf(e.out, "written_words=%d\n", n)
		if err != nil {
			fmt.Fprintln(e.errOut, "se-lab: write-image:", err)
			return exitFail
		}
		if cfg, err = d.ReadConfig(); err != nil {
			fmt.Fprintln(e.errOut, "se-lab: read back:", err)
			return exitFail
		}
	}
	if bad := se608.DiffImage(cfg, img); len(bad) != 0 {
		for _, i := range bad {
			fmt.Fprintf(e.out, "differs byte=%d chip=%02x image=%02x\n", i, cfg[i], img[i])
		}
		fmt.Fprintln(e.out, "compare=DIFFERENT")
		return exitDiffers
	}
	fmt.Fprintln(e.out, "compare=EQUAL")
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
