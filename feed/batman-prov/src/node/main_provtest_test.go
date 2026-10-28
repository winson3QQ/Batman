//go:build prov_test

package node

import (
	"os"
	"testing"

	"batman-prov/seam"
)

// The prov_test unit tests run as root: no point may reach a real reboot (seam.SafeForTests, code review r3 B-M1).
func TestMain(m *testing.M) {
	seam.SafeForTests()
	os.Exit(m.Run())
}
