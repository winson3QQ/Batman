package main

import (
	"testing"

	"github.com/godbus/dbus/v5"

	"batman-prov/provd"
)

// prov-gatt-254 (#254, design v3.1 §10 #8): the node's outbound frame limit is min(OutFrame, ATT MTU - 3), the MTU being
// the one BlueZ passes with AcquireNotify (bluez.go mtuOf / setTX / FrameLimit). On the air the harness's Windows
// central always negotiates a large MTU (L = 244), so the low-MTU branch is judged here only. Driven through the real
// AcquireNotify export (option parsing, socketpair, setTX), not by setting the field.
func acquireTX(t *testing.T, b *bleSide, opts map[string]dbus.Variant) {
	t.Helper()
	g := &gattObj{b: b, kind: "tx"}
	fd, _, derr := g.AcquireNotify(dbus.Sender(tName), opts)
	if derr != nil {
		t.Fatalf("AcquireNotify: %v", derr)
	}
	_ = fd // the far end; closeLater closes our copy of it
}

func TestFrameLimitFollowsAcquireNotifyMTU(t *testing.T) {
	cases := []struct {
		name string
		mtu  any // nil = no "mtu" option (BlueZ always sends one; mtuOf then assumes 23)
		want int
	}{
		{"no mtu option", nil, 20},
		{"mtu 0", uint16(0), 20},
		{"mtu 23 (no exchange)", uint16(23), 20},
		{"mtu 100", uint16(100), 97},
		{"mtu 247 (exactly OutFrame + 3)", uint16(247), provd.OutFrame},
		{"mtu 248", uint16(248), provd.OutFrame},
		{"mtu 517 (BlueZ / WinRT maximum)", uint16(517), provd.OutFrame},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			b, _ := tBLE(t)
			l := addLink(b, devA)
			defer l.Close()
			opts := map[string]dbus.Variant{"device": dbus.MakeVariant(devA)}
			if c.mtu != nil {
				opts["mtu"] = dbus.MakeVariant(c.mtu)
			}
			acquireTX(t, b, opts)
			if got := l.FrameLimit(); got != c.want {
				t.Fatalf("FrameLimit after AcquireNotify(mtu=%v) = %d, want %d", c.mtu, got, c.want)
			}
		})
	}
}

// Characterization (design v3.1 §5.1 M1 / review A-M9): the limit is taken when the central subscribes. A central
// that subscribes BEFORE the MTU exchange keeps the 20 B limit for the link's life — nothing in provd hears about a
// later exchange; only a new AcquireNotify (a re-subscription) moves it. Slower, never too long for the link.
func TestFrameLimitFixedAtSubscription(t *testing.T) {
	b, _ := tBLE(t)
	l := addLink(b, devA)
	defer l.Close()
	acquireTX(t, b, map[string]dbus.Variant{"device": dbus.MakeVariant(devA), "mtu": dbus.MakeVariant(uint16(23))})
	if got := l.FrameLimit(); got != 20 {
		t.Fatalf("after a subscription at MTU 23: %d, want 20", got)
	}
	// (an MTU exchange to 517 here reaches BlueZ only; provd is not told)
	if got := l.FrameLimit(); got != 20 {
		t.Fatalf("without a new AcquireNotify the limit moved to %d", got)
	}
	acquireTX(t, b, map[string]dbus.Variant{"device": dbus.MakeVariant(devA), "mtu": dbus.MakeVariant(uint16(517))})
	if got := l.FrameLimit(); got != provd.OutFrame {
		t.Fatalf("after a re-subscription at MTU 517: %d, want %d", got, provd.OutFrame)
	}
}

// A TX subscription for a device that is not the link's must not change the link's limit.
func TestFrameLimitPerDevice(t *testing.T) {
	b, _ := tBLE(t)
	la := addLink(b, devA)
	lb := addLink(b, devB)
	defer la.Close()
	defer lb.Close()
	acquireTX(t, b, map[string]dbus.Variant{"device": dbus.MakeVariant(devA), "mtu": dbus.MakeVariant(uint16(100))})
	acquireTX(t, b, map[string]dbus.Variant{"device": dbus.MakeVariant(devB), "mtu": dbus.MakeVariant(uint16(517))})
	if la.FrameLimit() != 97 || lb.FrameLimit() != provd.OutFrame {
		t.Fatalf("per-device limits: A=%d (want 97), B=%d (want %d)", la.FrameLimit(), lb.FrameLimit(), provd.OutFrame)
	}
}
