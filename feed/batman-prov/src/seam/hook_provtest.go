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
