package main

import "testing"

// the lines are batman-config-save's own (feed/batman-provision/files/usr/bin/batman-config-save:101,182,258,492,494)
func TestParseCheck(t *testing.T) {
	cases := []struct {
		rc        int
		out       string
		fresh, ok bool
	}{
		{0, "batman-config-save: p5 fresh\n", true, true},
		{5, "batman-config-save: p5 stale: system.hostname\n", false, true},
		{5, "batman-config-save: p5 stale: an unfinished network change (.txn) — the helper finishes it at the next app action or reboot\n", false, true},
		{8, "batman-config-save: p5 error lock-busy pid=123 age=40s (kill 123 if it is stuck; a D-state holder needs a reboot)\n", false, false},
		{124, "", false, false},
		{0, "", false, false}, // rc 0 without the line is not "fresh"
		{5, "p5 fresh", false, false},
	}
	for _, c := range cases {
		f, err := parseCheck(c.rc, c.out)
		if (err == nil) != c.ok || (c.ok && f != c.fresh) {
			t.Fatalf("rc %d %q -> %v %v", c.rc, c.out, f, err)
		}
	}
}
