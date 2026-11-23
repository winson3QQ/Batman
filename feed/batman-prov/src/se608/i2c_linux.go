//go:build linux

package se608

import (
	"errors"
	"fmt"

	"golang.org/x/sys/unix"
)

const ioctlI2CSlave = 0x0703 // I2C_SLAVE, linux/i2c-dev.h

// LinuxBus is /dev/i2c-N through i2c-dev: I2C_SLAVE selects the address, then plain read(2) / write(2), one
// transaction each (impl §2.2). The bus speed is the adapter's (100 kHz on the Pi by default).
type LinuxBus struct {
	fd   int
	addr int
}

// ErrBusy: another process holds the chip lock.
var ErrBusy = errors.New("se608: the chip lock is held by another process")

// OpenI2C opens path read-write and takes the chip lock: an exclusive, non-blocking flock on the device node itself.
// Only a process that can open the bus can hold it, so no lock file in a shared directory is needed (code review
// PR D B-M1). Tools that do not flock (i2c-tools) are not stopped by it; the rig runs nothing else on the bus.
func OpenI2C(path string) (*LinuxBus, error) {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("se608: open %s: %w", path, err)
	}
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = unix.Close(fd)
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, fmt.Errorf("%w (%s)", ErrBusy, path)
		}
		return nil, fmt.Errorf("se608: flock %s: %w", path, err)
	}
	return &LinuxBus{fd: fd, addr: -1}, nil
}

func (b *LinuxBus) Close() error { return unix.Close(b.fd) }

func (b *LinuxBus) set(addr uint16) error {
	if int(addr) == b.addr {
		return nil
	}
	if err := unix.IoctlSetInt(b.fd, ioctlI2CSlave, int(addr)); err != nil {
		b.addr = -1
		return fmt.Errorf("I2C_SLAVE 0x%02x: %w", addr, err)
	}
	b.addr = int(addr)
	return nil
}

func (b *LinuxBus) Write(addr uint16, p []byte) error {
	if err := b.set(addr); err != nil {
		return err
	}
	n, err := unix.Write(b.fd, p)
	if err != nil {
		return err
	}
	if n != len(p) {
		return fmt.Errorf("short write %d/%d", n, len(p))
	}
	return nil
}

func (b *LinuxBus) Read(addr uint16, p []byte) error {
	if err := b.set(addr); err != nil {
		return err
	}
	n, err := unix.Read(b.fd, p)
	if err != nil {
		return err
	}
	if n != len(p) {
		return fmt.Errorf("short read %d/%d", n, len(p))
	}
	return nil
}
