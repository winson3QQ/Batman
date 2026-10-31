package main

// The BLE side (254-p2-impl §4.1, §4.4): one GATT application (service + RX / TX / CTRL / STATUS) and one
// LEAdvertisement1, over the system bus at a fixed path (no /var in the jail, F-P30). The only BlueZ methods called
// are the eight the dbus policy allows (§4.7). Every exported method checks the caller is org.bluez's unique name.

import (
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/prop"

	"batman-prov/provd"
)

const (
	busAddr   = "unix:path=/tmp/run/dbus/system_bus_socket"
	bluez     = "org.bluez"
	adapter   = dbus.ObjectPath("/org/bluez/hci0")
	appPath   = dbus.ObjectPath("/org/batman/provd")
	svcPath   = appPath + "/service0"
	advPath   = appPath + "/adv0"
	SvcUUID   = "540aa38c-0086-4d58-a9c0-c7c9d1e1bd42" // D4 (254-p2-impl §4.1)
	rxUUID    = "540aa38c-0086-4d59-a9c0-c7c9d1e1bd42"
	txUUID    = "540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42"
	ctrlUUID  = "540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42"
	statUUID  = "540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42"
	errFailed = "org.freedesktop.DBus.Error.Failed" // -> ATT 0x0E (F-P16)
	errDenied = "org.freedesktop.DBus.Error.AccessDenied"
	rpaBase   = 900 * time.Second
	advUUIDAD = 18 // BlueZ's AD for one 128-bit service UUID list: len(1) type(1) uuid(16)
	advFlags  = 3  // the Flags AD the kernel prepends (F-P10)
	advMax    = 31
)

type bleSide struct {
	srv  *provd.Server
	te   provd.TestEnv
	logf func(string, ...any)

	mu        sync.Mutex
	conn      *dbus.Conn
	bluezName string
	appOK     bool
	advOn     bool
	links     map[dbus.ObjectPath]*bleLink
	devConn   map[dbus.ObjectPath]bool // Device1.Connected as BlueZ reports it (a link without Acquire*, e.g. a STATUS read)
	nextRPA   time.Time
	foreign   int
	advAt     time.Time // last register / withdraw
	lastWhy   string
	quit      chan struct{}
	kickc     chan struct{}
}

func newBLE(srv *provd.Server, te provd.TestEnv, logf func(string, ...any)) *bleSide {
	return &bleSide{srv: srv, te: te, logf: logf, links: map[dbus.ObjectPath]*bleLink{}, devConn: map[dbus.ObjectPath]bool{},
		quit:  make(chan struct{}),
		kickc: make(chan struct{}, 1)}
}

// preflight: the ADV length self-check (§4.4) — only our own program error; the kernel patch is the real guard.
func (b *bleSide) preflight() int {
	n := advUUIDAD
	if b.te.AdvLenTest > 0 {
		n = b.te.AdvLenTest
	}
	if n+advFlags > advMax {
		b.logf("adv: payload would be %d B (max %d)", n, advMax-advFlags)
		return 3
	}
	return 0
}

func jitter(lo, hi int) time.Duration {
	v, _ := rand.Int(rand.Reader, big.NewInt(int64(hi-lo+1)))
	return time.Duration(lo+int(v.Int64())) * time.Second
}

// ---- exported objects ------------------------------------------------------------------------------------------

type gattObj struct {
	b    *bleSide
	kind string // rx / tx / ctrl / status
}

func (b *bleSide) fromBluez(sender dbus.Sender) *dbus.Error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.bluezName == "" || string(sender) != b.bluezName {
		return dbus.NewError(errDenied, []any{"not org.bluez"})
	}
	return nil
}

func devOf(opts map[string]dbus.Variant) dbus.ObjectPath {
	if v, ok := opts["device"]; ok {
		if p, ok := v.Value().(dbus.ObjectPath); ok {
			return p
		}
	}
	return ""
}

func mtuOf(opts map[string]dbus.Variant) int {
	if v, ok := opts["mtu"]; ok {
		if m, ok := v.Value().(uint16); ok {
			return int(m)
		}
	}
	return 23
}

func (g *gattObj) ReadValue(sender dbus.Sender, opts map[string]dbus.Variant) ([]byte, *dbus.Error) {
	if e := g.b.fromBluez(sender); e != nil {
		return nil, e
	}
	switch g.kind {
	case "ctrl":
		return provd.Ctrl(), nil
	case "status":
		if v, ok := g.b.srv.Status(); ok {
			return v, nil
		}
	}
	return nil, dbus.NewError(errFailed, nil) // not fresh: an error, never a guess (§4.1)
}

func (g *gattObj) WriteValue(sender dbus.Sender, value []byte, opts map[string]dbus.Variant) *dbus.Error {
	if e := g.b.fromBluez(sender); e != nil {
		return e
	}
	if g.kind != "rx" {
		return dbus.NewError("org.bluez.Error.NotSupported", nil)
	}
	l := g.b.link(devOf(opts))
	if l == nil {
		return dbus.NewError(errFailed, nil)
	}
	l.push(append([]byte(nil), value...))
	return nil
}

func seqpair() (mine *os.File, theirs int, err error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_SEQPACKET|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, -1, err
	}
	return os.NewFile(uintptr(fds[0]), "ble"), fds[1], nil
}

// closeLater: our copy of the end handed to BlueZ must go once the reply carried it, or the far end never sees HUP
func closeLater(fd int) { time.AfterFunc(5*time.Second, func() { syscall.Close(fd) }) }

func (g *gattObj) AcquireWrite(sender dbus.Sender, opts map[string]dbus.Variant) (dbus.UnixFD, uint16, *dbus.Error) {
	if e := g.b.fromBluez(sender); e != nil {
		return -1, 0, e
	}
	l := g.b.link(devOf(opts))
	if g.kind != "rx" || l == nil {
		return -1, 0, dbus.NewError(errFailed, nil)
	}
	mine, theirs, err := seqpair()
	if err != nil {
		return -1, 0, dbus.NewError(errFailed, nil)
	}
	l.setRX(mine)
	closeLater(theirs)
	return dbus.UnixFD(theirs), uint16(mtuOf(opts)), nil
}

func (g *gattObj) AcquireNotify(sender dbus.Sender, opts map[string]dbus.Variant) (dbus.UnixFD, uint16, *dbus.Error) {
	if e := g.b.fromBluez(sender); e != nil {
		return -1, 0, e
	}
	l := g.b.link(devOf(opts))
	if g.kind != "tx" || l == nil {
		return -1, 0, dbus.NewError("org.bluez.Error.NotSupported", nil)
	}
	mine, theirs, err := seqpair()
	if err != nil {
		l.Close()
		return -1, 0, dbus.NewError("org.bluez.Error.NotSupported", nil)
	}
	l.setTX(mine, mtuOf(opts))
	closeLater(theirs)
	return dbus.UnixFD(theirs), uint16(mtuOf(opts)), nil
}

// StartNotify: only AcquireNotify is supported (the notify socket has back-pressure, D-Bus notifications do not)
func (g *gattObj) StartNotify(sender dbus.Sender) *dbus.Error {
	return dbus.NewError("org.bluez.Error.NotSupported", nil)
}
func (g *gattObj) StopNotify(sender dbus.Sender) *dbus.Error { return nil }

type advObj struct{ b *bleSide }

func (a *advObj) Release(sender dbus.Sender) *dbus.Error {
	if e := a.b.fromBluez(sender); e != nil {
		return e
	}
	a.b.mu.Lock()
	a.b.advOn = false
	a.b.mu.Unlock()
	return nil
}

type objMgr struct {
	b    *bleSide
	objs map[dbus.ObjectPath]map[string]map[string]dbus.Variant
}

func (o *objMgr) GetManagedObjects(sender dbus.Sender) (map[dbus.ObjectPath]map[string]map[string]dbus.Variant, *dbus.Error) {
	if e := o.b.fromBluez(sender); e != nil {
		return nil, e
	}
	return o.objs, nil
}

func (b *bleSide) export(c *dbus.Conn) error {
	chars := []struct {
		kind, uuid string
		flags      []string
		extra      map[string]any
	}{
		{"rx", rxUUID, []string{"write-without-response"}, map[string]any{"WriteAcquired": false}},
		{"tx", txUUID, []string{"notify"}, map[string]any{"NotifyAcquired": false}},
		{"ctrl", ctrlUUID, []string{"read"}, nil},
		{"status", statUUID, []string{"read"}, nil},
	}
	if b.te.GattEncryptCtrl {
		chars[2].flags = []string{"encrypt-read"} // prov-gatt-254's negative control (h23 §4.8.3)
	}
	om := &objMgr{b: b, objs: map[dbus.ObjectPath]map[string]map[string]dbus.Variant{}}
	sp := map[string]*prop.Prop{"UUID": {Value: SvcUUID}, "Primary": {Value: true}}
	if _, err := prop.Export(c, svcPath, prop.Map{"org.bluez.GattService1": sp}); err != nil {
		return err
	}
	om.objs[svcPath] = map[string]map[string]dbus.Variant{"org.bluez.GattService1": {
		"UUID": dbus.MakeVariant(SvcUUID), "Primary": dbus.MakeVariant(true)}}
	for i, ch := range chars {
		p := dbus.ObjectPath(fmt.Sprintf("%s/char%d", svcPath, i))
		props := map[string]*prop.Prop{"UUID": {Value: ch.uuid}, "Service": {Value: svcPath}, "Flags": {Value: ch.flags}}
		vm := map[string]dbus.Variant{"UUID": dbus.MakeVariant(ch.uuid), "Service": dbus.MakeVariant(svcPath),
			"Flags": dbus.MakeVariant(ch.flags)}
		for k, v := range ch.extra {
			props[k] = &prop.Prop{Value: v}
			vm[k] = dbus.MakeVariant(v)
		}
		if err := c.Export(&gattObj{b: b, kind: ch.kind}, p, "org.bluez.GattCharacteristic1"); err != nil {
			return err
		}
		if _, err := prop.Export(c, p, prop.Map{"org.bluez.GattCharacteristic1": props}); err != nil {
			return err
		}
		om.objs[p] = map[string]map[string]dbus.Variant{"org.bluez.GattCharacteristic1": vm}
	}
	if err := c.Export(om, appPath, "org.freedesktop.DBus.ObjectManager"); err != nil {
		return err
	}
	// the advertisement: UUID list only (21 B with the kernel's Flags), not discoverable, nothing else (§4.4)
	ap := map[string]*prop.Prop{"Type": {Value: "peripheral"}, "ServiceUUIDs": {Value: []string{SvcUUID}},
		"Discoverable": {Value: false}}
	if err := c.Export(&advObj{b: b}, advPath, "org.bluez.LEAdvertisement1"); err != nil {
		return err
	}
	_, err := prop.Export(c, advPath, prop.Map{"org.bluez.LEAdvertisement1": ap})
	return err
}

// ---- links ---------------------------------------------------------------------------------------------------

// bleLink is one connected phone: RX frames from the AcquireWrite socket (or WriteValue), TX frames to the
// AcquireNotify socket.
type bleLink struct {
	b      *bleSide
	dev    dbus.ObjectPath
	in     chan []byte
	mu     sync.Mutex
	rx, tx *os.File
	mtu    int
	txOK   chan struct{}
	gone   chan struct{}
	closed bool
}

func (b *bleSide) link(dev dbus.ObjectPath) *bleLink {
	if dev == "" {
		return nil
	}
	b.mu.Lock()
	l, ok := b.links[dev]
	if ok {
		b.mu.Unlock()
		return l
	}
	l = &bleLink{b: b, dev: dev, in: make(chan []byte, 64), txOK: make(chan struct{}), gone: make(chan struct{})}
	b.links[dev] = l
	b.mu.Unlock()
	b.withdraw("connect")
	if b.srv.Accept(l) == nil {
		l.Close()
		return nil
	}
	return l
}

func (l *bleLink) push(f []byte) {
	select {
	case l.in <- f:
	case <-l.gone:
	}
}

func (l *bleLink) watch(f *os.File, deliver bool) {
	buf := make([]byte, provd.MaxFrame+1)
	for {
		n, err := f.Read(buf)
		if err != nil || n == 0 {
			l.Close() // HUP: BlueZ dropped the ATT link (F-P16)
			return
		}
		if deliver {
			l.push(append([]byte(nil), buf[:n]...))
		}
	}
}

func (l *bleLink) setRX(f *os.File) {
	l.mu.Lock()
	old := l.rx
	l.rx = f
	l.mu.Unlock()
	if old != nil {
		old.Close()
	}
	go l.watch(f, true)
}

func (l *bleLink) setTX(f *os.File, mtu int) {
	l.mu.Lock()
	first := l.tx == nil
	l.tx, l.mtu = f, mtu
	l.mu.Unlock()
	if first {
		close(l.txOK)
	}
	go l.watch(f, false) // nothing is ever read from it: EOF = gone
}

func (l *bleLink) ReadFrame() ([]byte, error) {
	select {
	case f := <-l.in:
		return f, nil
	case <-l.gone:
		return nil, errors.New("ble: link gone")
	}
}

func (l *bleLink) WriteFrame(f []byte) error {
	select {
	case <-l.txOK:
	case <-l.gone:
		return errors.New("ble: link gone")
	case <-time.After(5 * time.Second):
		return errors.New("ble: no AcquireNotify")
	}
	l.mu.Lock()
	tx := l.tx
	l.mu.Unlock()
	_, err := tx.Write(f)
	return err
}

func (l *bleLink) FrameLimit() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.mtu > 3 {
		return min(provd.OutFrame, l.mtu-3)
	}
	return 20
}

func (l *bleLink) Kind() string { return "ble" }

// Close: drop the sockets and ask BlueZ to disconnect the device (async; the session is already over)
func (l *bleLink) Close() {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.closed = true
	if l.rx != nil {
		l.rx.Close()
	}
	if l.tx != nil {
		l.tx.Close()
	}
	close(l.gone)
	l.mu.Unlock()
	b := l.b
	b.mu.Lock()
	if b.links[l.dev] == l {
		delete(b.links, l.dev)
	}
	c := b.conn
	b.mu.Unlock()
	if c != nil {
		go c.Object(bluez, l.dev).Call("org.bluez.Device1.Disconnect", 0)
	}
	b.kick()
}

// ---- lifecycle -------------------------------------------------------------------------------------------------

func (b *bleSide) kick() {
	select {
	case b.kickc <- struct{}{}:
	default:
	}
}

func (b *bleSide) stop() {
	b.withdraw("stop")
	b.mu.Lock()
	ls := make([]*bleLink, 0, len(b.links))
	for _, l := range b.links {
		ls = append(ls, l)
	}
	b.mu.Unlock()
	for _, l := range ls {
		l.Close()
	}
	select {
	case <-b.quit:
	default:
		close(b.quit)
	}
}

// connect: bus, BlueZ owner, exported objects, signal matches. Retried with backoff by run.
func (b *bleSide) connect() error {
	c, err := dbus.Dial(busAddr)
	if err != nil {
		return err
	}
	if err := c.Auth(nil); err != nil {
		c.Close()
		return err
	}
	if err := c.Hello(); err != nil {
		c.Close()
		return err
	}
	if err := b.export(c); err != nil {
		c.Close()
		return err
	}
	c.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.DBus"), dbus.WithMatchMember("NameOwnerChanged"),
		dbus.WithMatchArg(0, bluez))
	c.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.DBus.ObjectManager"), dbus.WithMatchSender(bluez))
	// §4.4: a connection withdraws the advertisement — also one that never acquires RX / TX (a STATUS read)
	c.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.DBus.Properties"), dbus.WithMatchMember("PropertiesChanged"),
		dbus.WithMatchSender(bluez), dbus.WithMatchArg(0, "org.bluez.Device1"))
	b.mu.Lock()
	b.conn, b.appOK, b.advOn = c, false, false
	b.mu.Unlock()
	b.refreshOwner()
	return nil
}

func (b *bleSide) refreshOwner() {
	b.mu.Lock()
	c := b.conn
	b.mu.Unlock()
	var owner string
	if c != nil {
		c.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, bluez).Store(&owner)
	}
	b.mu.Lock()
	if owner != b.bluezName {
		b.appOK, b.advOn = false, false // a new bluetoothd knows neither
		b.devConn = map[dbus.ObjectPath]bool{}
	}
	b.bluezName = owner
	b.mu.Unlock()
}

// adapterOK: Adapter1 exists, not Pairable, not Discoverable (§4.4 preconditions besides the health line)
func (b *bleSide) adapterOK() bool {
	b.mu.Lock()
	c := b.conn
	b.mu.Unlock()
	if c == nil {
		return false
	}
	o := c.Object(bluez, adapter)
	var pair, disc bool
	if o.Call("org.freedesktop.DBus.Properties.Get", 0, "org.bluez.Adapter1", "Pairable").Store(&pair) != nil {
		return false
	}
	if o.Call("org.freedesktop.DBus.Properties.Get", 0, "org.bluez.Adapter1", "Discoverable").Store(&disc) != nil {
		return false
	}
	return !pair && !disc
}

// staleLinks disconnects every LE link BlueZ still lists as connected that is not one of ours (a provd restart does
// not drop them, and the kernel may refuse a connectable advertisement while a peripheral link exists, F-P41).
func (b *bleSide) staleLinks() {
	b.mu.Lock()
	c := b.conn
	b.mu.Unlock()
	if c == nil {
		return
	}
	n := 0
	for round := 0; round < 3; round++ {
		var objs map[dbus.ObjectPath]map[string]map[string]dbus.Variant
		if c.Object(bluez, "/").Call("org.freedesktop.DBus.ObjectManager.GetManagedObjects", 0).Store(&objs) != nil {
			return
		}
		var todo []dbus.ObjectPath
		for p, ifs := range objs {
			d, ok := ifs["org.bluez.Device1"]
			if !ok {
				continue
			}
			if v, ok := d["Connected"]; ok && v.Value() == true {
				b.mu.Lock()
				_, ours := b.links[p]
				b.mu.Unlock()
				if !ours {
					todo = append(todo, p)
				}
			}
		}
		if len(todo) == 0 {
			break
		}
		var wg sync.WaitGroup
		for _, p := range todo {
			wg.Add(1)
			go func(p dbus.ObjectPath) {
				defer wg.Done()
				call := c.Object(bluez, p).Go("org.bluez.Device1.Disconnect", 0, make(chan *dbus.Call, 1))
				select { // async in BlueZ: 2 s timer, the reply when Connected turns false; none for an already-gone one
				case <-call.Done:
				case <-time.After(5 * time.Second):
				}
			}(p)
			n++
		}
		wg.Wait()
	}
	if n > 0 {
		b.logf("provd: disconnected %d stale link(s)", n)
	}
}

func (b *bleSide) registerApp() error {
	b.mu.Lock()
	c := b.conn
	b.mu.Unlock()
	err := c.Object(bluez, adapter).Call("org.bluez.GattManager1.RegisterApplication", 0, appPath,
		map[string]dbus.Variant{}).Err
	if err == nil {
		b.mu.Lock()
		b.appOK = true
		b.mu.Unlock()
	}
	return err
}

func (b *bleSide) register(why string) {
	b.mu.Lock()
	c, on := b.conn, b.advOn
	b.mu.Unlock()
	if on || c == nil {
		return
	}
	b.staleLinks()
	if err := c.Object(bluez, adapter).Call("org.bluez.LEAdvertisingManager1.RegisterAdvertisement", 0, advPath,
		map[string]dbus.Variant{}).Err; err != nil {
		b.logLimit("register", fmt.Sprintf("provd: adv register failed: %v", err))
		return
	}
	b.mu.Lock()
	b.advOn, b.nextRPA, b.advAt = true, time.Now().Add(rpaBase+jitter(30, 120)), time.Now()
	b.mu.Unlock()
	b.logf("provd: adv registered reason=%s", why)
}

func (b *bleSide) withdraw(why string) {
	b.mu.Lock()
	c, on := b.conn, b.advOn
	b.advOn = false
	if on {
		b.advAt = time.Now()
	}
	b.mu.Unlock()
	if !on || c == nil {
		return
	}
	c.Object(bluez, adapter).Call("org.bluez.LEAdvertisingManager1.UnregisterAdvertisement", 0, advPath)
	b.logf("provd: adv withdrawn reason=%s", why)
}

func (b *bleSide) logLimit(key, line string) {
	b.mu.Lock()
	same := b.lastWhy == key+line
	b.lastWhy = key + line
	b.mu.Unlock()
	if !same {
		b.logf("%s", line)
	}
}

// run keeps the BLE side converged: bus up, app registered, advertisement on exactly when the health preconditions
// hold, no link is open and the server is ready (§4.4).
func (b *bleSide) run() {
	back := time.Second
	var sig chan *dbus.Signal
	lastReason := "start"
	for {
		b.mu.Lock()
		c := b.conn
		b.mu.Unlock()
		if c == nil || !c.Connected() {
			if err := b.connect(); err != nil {
				b.logLimit("bus", fmt.Sprintf("provd: backoff %ds reason=bus (%v)", int(back/time.Second), err))
				select {
				case <-b.quit:
					return
				case <-time.After(back):
				}
				if back *= 2; back > 60*time.Second {
					back = 60 * time.Second
				}
				continue
			}
			back = time.Second
			sig = make(chan *dbus.Signal, 32)
			b.mu.Lock()
			b.conn.Signal(sig)
			b.mu.Unlock()
		}
		b.converge(&lastReason)
		select {
		case <-b.quit:
			return
		case s := <-sig:
			if s != nil && (s.Name == "org.freedesktop.DBus.Properties.PropertiesChanged" ||
				s.Name == "org.freedesktop.DBus.ObjectManager.InterfacesAdded" ||
				s.Name == "org.freedesktop.DBus.ObjectManager.InterfacesRemoved") {
				b.deviceChanged(s)
			}
			if s != nil && s.Name == "org.freedesktop.DBus.NameOwnerChanged" {
				b.refreshOwner()
				b.mu.Lock()
				gone := b.bluezName == ""
				b.mu.Unlock()
				if gone {
					b.logf("provd: adv withdrawn reason=bluetoothd")
				} else {
					lastReason = "bluetoothd"
				}
			}
		case <-b.srv.Changed():
		case <-b.kickc:
		case <-time.After(5 * time.Second):
		}
	}
}

// deviceChanged records Device1.Connected from org.bluez's own signals (any other sender is ignored: a local process
// must not be able to pause the advertisement by faking it). A device BlueZ creates for an incoming connection
// reports Connected=true only inside InterfacesAdded: gdbus folds a property change of an interface not yet announced
// into that signal (bluez-5.72 gdbus/object.c:1765, src/device.c:3271) — 04, 2026-10-31.
func (b *bleSide) deviceChanged(s *dbus.Signal) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if string(s.Sender) != b.bluezName || len(s.Body) < 2 {
		return
	}
	set := func(p dbus.ObjectPath, props map[string]dbus.Variant) {
		if v, ok := props["Connected"]; ok {
			if on, _ := v.Value().(bool); on {
				b.devConn[p] = true
			} else {
				delete(b.devConn, p)
			}
		}
	}
	switch s.Name {
	case "org.freedesktop.DBus.Properties.PropertiesChanged":
		if iface, _ := s.Body[0].(string); iface != "org.bluez.Device1" {
			return
		}
		ch, _ := s.Body[1].(map[string]dbus.Variant)
		set(s.Path, ch)
	case "org.freedesktop.DBus.ObjectManager.InterfacesAdded":
		p, _ := s.Body[0].(dbus.ObjectPath)
		ifs, _ := s.Body[1].(map[string]map[string]dbus.Variant)
		if d, ok := ifs["org.bluez.Device1"]; ok {
			set(p, d)
		}
	case "org.freedesktop.DBus.ObjectManager.InterfacesRemoved":
		p, _ := s.Body[0].(dbus.ObjectPath)
		l, _ := s.Body[1].([]string)
		for _, i := range l {
			if i == "org.bluez.Device1" {
				delete(b.devConn, p)
			}
		}
	}
	select {
	case b.kickc <- struct{}{}:
	default:
	}
}

func (b *bleSide) converge(reason *string) {
	b.mu.Lock()
	name, appOK, advOn, nlinks, next := b.bluezName, b.appOK, b.advOn, len(b.links)+len(b.devConn), b.nextRPA
	b.mu.Unlock()
	if name == "" {
		return // bluetoothd not on the bus: wait for NameOwnerChanged
	}
	ok, why := b.srv.HealthOK()
	if ok && !b.adapterOK() {
		ok, why = false, "health"
	}
	if !appOK && ok {
		b.staleLinks()
		if err := b.registerApp(); err != nil {
			b.logLimit("app", fmt.Sprintf("provd: GATT register failed: %v", err))
			return
		}
	}
	// foreign instances (root btmgmt / bluetoothctl advertise): log, do not act (L68)
	mine := 0
	if advOn {
		mine = 1
	}
	b.mu.Lock()
	since := b.advAt.Add(2 * time.Second) // the kernel count of a register / withdraw in flight is not foreign
	b.mu.Unlock()
	if k := b.srv.KernelInstances(since); k > mine {
		b.mu.Lock()
		changed := b.foreign != k-mine
		b.foreign = k - mine
		b.mu.Unlock()
		if changed {
			b.logf("provd: %d foreign advertising instance(s) on hci0 (not provd's)", k-mine)
		}
	}
	switch {
	case !ok:
		if advOn {
			b.withdraw(why)
			*reason = why
		}
	case nlinks > 0 || b.srv.Sessions() > 0:
		if advOn {
			b.withdraw("connect")
		}
		*reason = "disconnect"
	case advOn && time.Now().After(next):
		b.withdraw("rpa_timeout") // re-register so an expired RPA is really replaced (F-P17)
		b.register("rpa_timeout")
	case !advOn:
		b.register(*reason)
	}
}
