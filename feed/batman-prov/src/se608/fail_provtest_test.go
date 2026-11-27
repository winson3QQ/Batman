//go:build prov_test

package se608_test

import (
	"testing"

	"batman-prov/se608"
	"batman-prov/se608/fakechip"
)

// "N sequences without a response, then the chip is back" (impl §2.2): the failures are transport errors, the bus
// is not touched while they last, and the count is exact.
func TestSeFailSeam(t *testing.T) {
	chip := fakechip.New()
	d := se608.New(chip)
	rev := func() error { return d.Do(func(s *se608.Session) error { _, err := s.Revision(); return err }) }
	if err := rev(); err != nil {
		t.Fatal(err)
	}
	wakes := chip.Wakes
	se608.FailSequences(2)
	for i := 0; i < 2; i++ {
		if err := rev(); err == nil || !se608.IsTransport(err) {
			t.Fatalf("sequence %d under se-fail: %v, want a transport error", i, err)
		}
	}
	if chip.Wakes != wakes {
		t.Fatal("a failed sequence reached the bus")
	}
	if err := rev(); err != nil {
		t.Fatalf("the sequence after the failures: %v", err)
	}
	if chip.Wakes != wakes+1 {
		t.Fatalf("wakes %d, want %d", chip.Wakes, wakes+1)
	}
}
