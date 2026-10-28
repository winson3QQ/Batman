//go:build prov_test

package main

import (
	"testing"

	"batman-prov/seam"
)

// This package has no TestMain: the seam package's init must still have made the test binary safe (r4 B-m1),
// so a future test of daemon() / seam.Arm run as root cannot write sysrq.
func TestSeamSafeWithoutTestMain(t *testing.T) {
	if !seam.IsSafeForTests() {
		t.Fatal("seam is not in SafeForTests mode in a test binary without TestMain")
	}
}
