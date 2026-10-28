//go:build prov_test

package seam

// ArmForTest arms the point called name for a unit test in another package and replaces the reboot with fire, which
// must not return (a real reboot never does): tests panic in it and recover. It returns the function that undoes both.
// prov_test builds only; the name must be one of the closed list.
func ArmForTest(name string, fire func(name string)) (restore func()) {
	p, ok := names[name]
	if !ok {
		panic("seam: unknown point " + name)
	}
	prevArmed, prevReboot := armed, reboot
	armed = p
	reboot = func(n string, _ func(string, ...any)) { fire(n) }
	return func() { armed, reboot = prevArmed, prevReboot }
}

// Names lists the closed set of point names.
func Names() []string {
	out := make([]string, 0, len(names))
	for n := range names {
		out = append(out, n)
	}
	return out
}

// SafeForTests makes every way this package can reboot panic instead. The prov_test unit tests run as root (design
// §2.2): without this, a point reached by a regression (or a mutant run as a negative control) would write sysrq "b"
// and reset the CI runner or the developer's WSL VM (code review r3 B-M1). Each prov_test test package calls it from
// TestMain; ArmForTest still replaces reboot per test and restores this one.
func SafeForTests() {
	reboot = func(n string, _ func(string, ...any)) {
		panic("seam: killpoint " + n + " fired in a unit test that did not arm it (ArmForTest)")
	}
	sysrqPath = "/nonexistent/batman-seam-test/sysrq-trigger" // fire() called directly cannot reach the real trigger
	kmsgPath = "/nonexistent/batman-seam-test/kmsg"
	fallback = func() error { panic("seam: fallback reboot in a unit test") }
}
