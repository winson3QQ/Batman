package main

import (
	"testing"
	"time"

	"github.com/godbus/dbus/v5"

	"batman-prov/provd"
)

// #329 N1 (docs/design/329-n1-plan.md §5.1): a connected device with no session stops counting after linkGrace.
// No bus: signals are hand-made, links inserted directly, time moved by `now` or by setting `since` back.
const (
	tName = ":1.42"
	devA  = dbus.ObjectPath("/org/bluez/hci0/dev_AA_AA_AA_AA_AA_AA")
	devB  = dbus.ObjectPath("/org/bluez/hci0/dev_BB_BB_BB_BB_BB_BB")
)

func tBLE(t *testing.T) (*bleSide, *int) {
	t.Helper()
	lines := 0
	b := newBLE(nil, provd.TestEnv{}, func(string, ...any) { lines++ })
	b.bluezName = tName
	return b, &lines
}

// connected: the InterfacesAdded form BlueZ uses for an incoming connection (bluez.go deviceChanged comment)
func sigAdded(sender string, p dbus.ObjectPath, on bool) *dbus.Signal {
	return &dbus.Signal{Sender: sender, Path: "/", Name: "org.freedesktop.DBus.ObjectManager.InterfacesAdded",
		Body: []any{p, map[string]map[string]dbus.Variant{"org.bluez.Device1": {"Connected": dbus.MakeVariant(on)}}}}
}

func sigProp(sender string, p dbus.ObjectPath, on bool) *dbus.Signal {
	return &dbus.Signal{Sender: sender, Path: p, Name: "org.freedesktop.DBus.Properties.PropertiesChanged",
		Body: []any{"org.bluez.Device1", map[string]dbus.Variant{"Connected": dbus.MakeVariant(on)}, []string{}}}
}

func addLink(b *bleSide, p dbus.ObjectPath) *bleLink {
	l := &bleLink{b: b, dev: p, in: make(chan []byte, 1), txOK: make(chan struct{}), gone: make(chan struct{})}
	b.mu.Lock()
	b.links[p] = l
	b.mu.Unlock()
	return l
}

func ent(b *bleSide, p dbus.ObjectPath) *devEnt {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.devConn[p]
}

func mustEnt(t *testing.T, b *bleSide, p dbus.ObjectPath) *devEnt {
	t.Helper()
	e := ent(b, p)
	if e == nil {
		t.Fatalf("precondition: no devConn entry for %s (signal dropped?)", p)
	}
	return e
}

func back(b *bleSide, p dbus.ObjectPath, d time.Duration) {
	b.mu.Lock()
	if e := b.devConn[p]; e != nil {
		e.since = e.since.Add(-d)
	}
	b.mu.Unlock()
}

func live(b *bleSide, now time.Time) (int, []dbus.ObjectPath) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return liveLinks(b.links, b.devConn, now)
}

func count(b *bleSide, now time.Time) (int, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.countLocked(now)
}

func TestT1_FreshDeviceCounted(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	e := mustEnt(t, b, devA)
	if n, st := live(b, e.since.Add(time.Second)); n != 1 || len(st) != 0 {
		t.Fatalf("T1 n=%d stale=%v (want 1, none)", n, st)
	}
	if n, st := live(b, e.since.Add(29*time.Second)); n != 1 || len(st) != 0 {
		t.Fatalf("T1 at 29 s n=%d stale=%v (want 1, none)", n, st)
	}
}

func TestT2_StaleAfterGraceLoggedOnce(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	e := mustEnt(t, b, devA)
	at := e.since.Add(31 * time.Second)
	if n, st := live(b, at); n != 0 || len(st) != 1 || st[0] != devA {
		t.Fatalf("T2 n=%d stale=%v (want 0, [A])", n, st)
	}
	if n, k := count(b, at); n != 0 || k != 1 {
		t.Fatalf("T2 countLocked first n=%d marked=%d (want 0, 1)", n, k)
	}
	if n, k := count(b, at.Add(5*time.Second)); n != 0 || k != 0 {
		t.Fatalf("T2 countLocked second n=%d marked=%d (want 0, 0)", n, k)
	}
}

func TestT3_DeviceWithLinkCountedOnce(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	e := mustEnt(t, b, devA)
	addLink(b, devA)
	if n, st := live(b, e.since.Add(time.Second)); n != 1 || len(st) != 0 {
		t.Fatalf("T3 n=%d stale=%v (want 1 — not 2 —, none)", n, st)
	}
}

func TestT4_ClosedLinkGetsOneMoreGrace(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	mustEnt(t, b, devA)
	l := addLink(b, devA)
	back(b, devA, 60*time.Second) // the session lasted 60 s
	l.Close()
	now := time.Now()
	e := mustEnt(t, b, devA) // still connected: Close's Disconnect did not land
	if _, ok := b.links[devA]; ok {
		t.Fatal("T4 precondition: Close left the link")
	}
	if n, st := live(b, now.Add(time.Second)); n != 1 || len(st) != 0 {
		t.Fatalf("T4 right after Close n=%d stale=%v (want 1, none)", n, st)
	}
	if n, st := live(b, e.since.Add(29*time.Second)); n != 1 || len(st) != 0 {
		t.Fatalf("T4 29 s after Close n=%d stale=%v (want 1, none)", n, st)
	}
	if n, st := live(b, now.Add(31*time.Second)); n != 0 || len(st) != 1 {
		t.Fatalf("T4 31 s after Close n=%d stale=%v (want 0, [A])", n, st)
	}
	// logged once as stale; a late link then its Close start a new period, which is logged again
	if _, k := count(b, now.Add(31*time.Second)); k != 1 || !mustEnt(t, b, devA).logged {
		t.Fatalf("T4 first stale period marked=%d (want 1)", k)
	}
	addLink(b, devA).Close()
	if e := mustEnt(t, b, devA); e.logged {
		t.Fatal("T4 Close left logged set")
	}
	back(b, devA, 31*time.Second)
	if _, k := count(b, time.Now()); k != 1 {
		t.Fatalf("T4 second stale period marked=%d (want 1)", k)
	}
}

func TestT5_DisconnectThenCloseThenReconnect(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	mustEnt(t, b, devA)
	l := addLink(b, devA)
	b.deviceChanged(sigProp(tName, devA, false))
	if ent(b, devA) != nil {
		t.Fatal("T5 precondition: Connected=false left the entry")
	}
	l.Close()                     // on the fd-watch goroutine in real life, after the signal
	back(b, devA, 60*time.Second) // 60 s pass (moves an entry only if Close made one)
	b.deviceChanged(sigAdded(tName, devA, true))
	mustEnt(t, b, devA)
	if n, st := live(b, time.Now()); n != 1 || len(st) != 0 {
		t.Fatalf("T5 n=%d stale=%v (want 1, none: the new connection gets a fresh grace)", n, st)
	}
}

func TestT6_OpenSessionCountedAtAnyAge(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	e := mustEnt(t, b, devA)
	addLink(b, devA)
	for _, d := range []time.Duration{31 * time.Second, 90 * time.Second, time.Hour} {
		if n, st := live(b, e.since.Add(d)); n != 1 || len(st) != 0 {
			t.Fatalf("T6 at %v n=%d stale=%v (want 1, none)", d, n, st)
		}
		if n, k := count(b, e.since.Add(d)); n != 1 || k != 0 {
			t.Fatalf("T6 countLocked at %v n=%d marked=%d (want 1, 0)", d, n, k)
		}
	}
}

func TestT7_StaleDevicePlusOtherLink(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	e := mustEnt(t, b, devA)
	b.deviceChanged(sigAdded(tName, devB, true))
	mustEnt(t, b, devB)
	addLink(b, devB)
	if n, st := live(b, e.since.Add(31*time.Second)); n != 1 || len(st) != 1 || st[0] != devA {
		t.Fatalf("T7 n=%d stale=%v (want 1, [A])", n, st)
	}
}

func TestT8_OwnerChangeEmpties(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	mustEnt(t, b, devA)
	b.refreshOwner() // no bus: the owner reads "" != bluezName, as after a bluetoothd restart
	if ent(b, devA) != nil {
		t.Fatal("T8 the owner change left the entry")
	}
	if n, st := live(b, time.Now()); n != 0 || len(st) != 0 {
		t.Fatalf("T8 n=%d stale=%v (want 0, none)", n, st)
	}
}

func TestT9_LinkWithoutEntryCounted(t *testing.T) {
	b, _ := tBLE(t)
	addLink(b, devA)
	if ent(b, devA) != nil {
		t.Fatal("T9 precondition: an entry exists")
	}
	if n, st := live(b, time.Now().Add(time.Hour)); n != 1 || len(st) != 0 {
		t.Fatalf("T9 n=%d stale=%v (want 1, none)", n, st)
	}
}

func TestT10_SecondConnectedDoesNotRestartGrace(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(tName, devA, true))
	mustEnt(t, b, devA)
	back(b, devA, 20*time.Second) // 20 s pass
	b.deviceChanged(sigProp(tName, devA, true))
	mustEnt(t, b, devA)
	if n, st := live(b, time.Now().Add(11*time.Second)); n != 0 || len(st) != 1 { // 31 s after the first signal
		t.Fatalf("T10 n=%d stale=%v (want 0, [A])", n, st)
	}
}

func TestT11_OtherSenderIgnored(t *testing.T) {
	b, _ := tBLE(t)
	b.deviceChanged(sigAdded(":1.99", devA, true))
	b.deviceChanged(sigProp(":1.99", devA, true))
	if ent(b, devA) != nil {
		t.Fatal("T11 a signal from :1.99 made an entry")
	}
}
