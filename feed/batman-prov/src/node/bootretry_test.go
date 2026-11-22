package node

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

// #254 L111 (docs/design/254-v16-group1.md §2): a failed boot Finish is retried by the helper itself, bounded, for
// causes a retry can cure. Negative control: with bootRetry's call removed from BootFinish (or retryable() always
// false) TestBootRetry{Rc2ThenOK,GivesUpAfter8,LeaveForgetRc3,TransientRestoreCheck,PostponedWhileTrial,
// VerbNotRefusedAfterFailedRetry} fail.

// Tests never retry on the real clock: an unplanned retry goroutine parks for good.
func init() { bootRetrySleep = func(time.Duration) { select {} } }

// stepper drives n's retry clock: each sleep is reported on waits and returns when the test calls step.
type stepper struct {
	waits chan time.Duration
	run   chan struct{}
}

func newStepper(n *Node) *stepper {
	s := &stepper{waits: make(chan time.Duration, 64), run: make(chan struct{})}
	n.retrySleep = func(d time.Duration) { s.waits <- d; <-s.run }
	return s
}

// next: the wait the retry asks for (it is then parked until release)
func (s *stepper) next(t *testing.T) time.Duration {
	t.Helper()
	select {
	case d := <-s.waits:
		return d
	case <-time.After(5 * time.Second):
		t.Fatal("the retry never slept")
	}
	return 0
}

// none: the retry does not sleep again (it ended)
func (s *stepper) none(t *testing.T) {
	t.Helper()
	select {
	case d := <-s.waits:
		t.Fatalf("the retry slept again (%s), want it ended", d)
	case <-time.After(300 * time.Millisecond):
	}
}

// logRig: the rig's node logs into a buffer (the retry's lines are asserted)
type logBuf struct {
	mu sync.Mutex
	l  []string
}

func (b *logBuf) log(f string, a ...any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.l = append(b.l, fmt.Sprintf(f, a...))
}
func (b *logBuf) has(sub string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, s := range b.l {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}
func (b *logBuf) count(sub string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	c := 0
	for _, s := range b.l {
		if strings.Contains(s, sub) {
			c++
		}
	}
	return c
}

// waitLog: the line appears within 5 s
func (b *logBuf) wait(t *testing.T, sub string) {
	t.Helper()
	for i := 0; i < 500; i++ {
		if b.has(sub) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	t.Fatalf("no log line %q in %q", sub, b.l)
}

// settle: the retry goroutine is between tries (holds no mutex)
func (r *rig) settle() { r.n.mu.Lock(); r.n.mu.Unlock() }

func withLog(r *rig) *logBuf {
	b := &logBuf{}
	r.n.Log = b.log
	return b
}

// (a) rc 2 on the boot Finish, then the first retry succeeds
func TestBootRetryRc2ThenOK(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	lb, s := withLog(r), newStepper(r.n)
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2}}
	sk := len(r.sys.setkeys)
	r.n.BootFinish(func() {})
	if d := s.next(t); d != 60*time.Second {
		t.Fatalf("first wait %s, want 60s", d)
	}
	if !lb.has("boot finish: ") || !provstore.TxnPresent(r.n.P) {
		t.Fatalf("the boot Finish did not fail first: %q", lb.l)
	}
	s.run <- struct{}{}
	lb.wait(t, "finished (boot retry 1)")
	s.none(t)
	r.settle()
	r.finishedCleanly("sae-v1-pass/m1/28")
	if n := len(r.sys.setkeys) - sk; n != 2 {
		t.Fatalf("setkeys %d, want 2 (boot + retry 1)", n)
	}
}

// (b) rc 2 for good: exactly 8 retries on the schedule, then the CRIT line, .txn kept
func TestBootRetryGivesUpAfter8(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	lb, s := withLog(r), newStepper(r.n)
	for i := 0; i < 20; i++ {
		r.sys.setkeyErrs = append(r.sys.setkeyErrs, &SetkeyError{RC: 2})
	}
	sk := len(r.sys.setkeys)
	r.n.BootFinish(func() {})
	for i, want := range bootRetryWaits {
		if d := s.next(t); d != want {
			t.Fatalf("wait %d: %s, want %s", i+1, d, want)
		}
		s.run <- struct{}{}
	}
	lb.wait(t, "CRIT boot finish: gave up after 8 retries")
	s.none(t)
	r.settle()
	if !provstore.TxnPresent(r.n.P) {
		t.Fatal(".txn gone although every try failed")
	}
	if n := len(r.sys.setkeys) - sk; n != 9 {
		t.Fatalf("setkeys %d, want 9 (boot + 8 retries)", n)
	}
	if c := lb.count("(cause setkey-rc2)"); c != 8 {
		t.Fatalf("%d retry failure lines, want 8", c)
	}
}

// (c) a verb finishes the change during the wait: the retry stops without a further Finish
func TestBootRetryStopsWhenAVerbFinished(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	s := newStepper(r.n)
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2}}
	r.n.BootFinish(func() {})
	s.next(t)
	r.sys.now = r.sys.now.Add(61 * time.Second) // past the verb backoff
	if c := r.sshSet(); c != OK {
		t.Fatalf("the verb's own Finish: %d", c)
	}
	sk := len(r.sys.setkeys)
	s.run <- struct{}{}
	s.none(t)
	r.settle()
	if len(r.sys.setkeys) != sk {
		t.Fatalf("the retry ran a Finish after the verb finished the change (+%d setkeys)", len(r.sys.setkeys)-sk)
	}
}

// (e) causes that are not retried: rc 124, rc 1, rc 143, and a save that hit the deadline
func TestBootRetryNotForDeadlineOrUnknown(t *testing.T) {
	for _, c := range []struct {
		name, cause string
		setkey      error
		save        int
	}{
		{"setkey rc 124", "deadline", &SetkeyError{RC: provstore.RCTimeout}, 0},
		{"setkey rc 1", "setkey-other", &SetkeyError{RC: 1}, 0},
		{"setkey rc 143", "setkey-other", &SetkeyError{RC: 143}, 0},
		{"save rc 124", "deadline", nil, provstore.RCTimeout},
	} {
		t.Run(c.name, func(t *testing.T) {
			r, _ := memberRig(t)
			r.crashTxn2("sae-v2-pass", "m2", "36")
			lb, s := withLog(r), newStepper(r.n)
			if c.setkey != nil {
				r.sys.setkeyErrs = []error{c.setkey}
			}
			if c.save != 0 {
				r.sys.saveTxnOut = []saveRC{{rc: c.save}}
			}
			r.n.BootFinish(func() {})
			lb.wait(t, "boot finish: not retried (cause "+c.cause+")")
			s.none(t)
		})
	}
}

// (e') review v2 B-M1: a committed leave whose forget failed (rc 3: the key may still be on the air) is retried
func TestBootRetryLeaveForgetRc3(t *testing.T) {
	r, _ := memberRig(t)
	r.sys.forgetErr = &SetkeyError{RC: 3}
	if c := r.leave(); c != EApply {
		t.Fatalf("leave with a failing forget: %d, want EApply", c)
	}
	if !provstore.TxnPresent(r.n.P) {
		t.Fatal("no .txn after the committed leave")
	}
	r.restart()
	lb, s := withLog(r), newStepper(r.n)
	mr := r.sys.markersRemoved
	r.n.BootFinish(func() {})
	s.next(t)
	if !lb.has("boot finish: ") {
		t.Fatalf("the boot forget did not fail: %q", lb.l)
	}
	r.sys.forgetErr = nil
	s.run <- struct{}{}
	lb.wait(t, "finished (boot retry 1)")
	s.none(t)
	r.settle()
	if provstore.TxnPresent(r.n.P) || r.sys.markersRemoved == mr || !strings.HasPrefix(r.wl(), placeholderKey+"/") {
		t.Fatalf("after the retry: txn=%v markers +%d wl=%s", provstore.TxnPresent(r.n.P), r.sys.markersRemoved-mr, r.wl())
	}
}

// (e”) A4 m1 path: CheckRestorable could not run (transient) -> retried, then the snapshot is restored
func TestBootRetryTransientRestoreCheck(t *testing.T) {
	r := claimedRig(t)
	k, id, ch, _ := r.sys.CurrentWireless()
	rec := r.rec()
	if err := provstore.WriteTxn(r.n.P, crashTok, rec.Generation, rec.Generation+1, "network/join", k, id, ch, false); err != nil {
		t.Fatal(err)
	}
	r.sys.wl = [3]string{"sae-new-pass", "mnew", "36"}
	r.restart()
	lb, s := withLog(r), newStepper(r.n)
	r.sys.restorableErr = errors.New("uci get wireless.x.device rc=4")
	r.n.BootFinish(func() {})
	s.next(t)
	if !lb.has("boot finish: ") {
		t.Fatalf("the boot Finish did not fail on the transient check: %q", lb.l)
	}
	r.sys.restorableErr = nil
	s.run <- struct{}{}
	lb.wait(t, "finished (boot retry 1)")
	r.settle()
	if provstore.TxnPresent(r.n.P) || r.wl() != k+"/"+id+"/"+ch {
		t.Fatalf("after the retry: txn=%v wl=%s (want the snapshot %s/%s/%s)", provstore.TxnPresent(r.n.P), r.wl(), k, id, ch)
	}
}

// (f) a trial (or an OTA being written) postpones the retry without counting it; logged once per stretch
func TestBootRetryPostponedWhileTrial(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	lb, s := withLog(r), newStepper(r.n)
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2}}
	r.n.BootFinish(func() {})
	s.next(t)
	r.sys.trial = true
	sk := len(r.sys.setkeys)
	for i := 0; i < 3; i++ {
		s.run <- struct{}{}
		if d := s.next(t); d != bootRetryPostpone {
			t.Fatalf("postponed wait %s, want %s", d, bootRetryPostpone)
		}
	}
	if len(r.sys.setkeys) != sk {
		t.Fatal("a retry ran during the trial")
	}
	if c := lb.count("boot finish retry postponed: trial"); c != 1 {
		t.Fatalf("%d postpone lines, want 1", c)
	}
	r.sys.trial = false
	s.run <- struct{}{}
	lb.wait(t, "finished (boot retry 1)") // still retry 1: the postponed waits did not count
	r.settle()
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// (g) review v3 A m1 / B m1: a member-role peer can make the helper run a pending Finish before its chain is checked;
// during the retry window that stays at most one Finish per verb backoff (retries do not touch the backoff)
func TestBootRetryKeepsTheVerbBackoff(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	s := newStepper(r.n)
	for i := 0; i < 10; i++ {
		r.sys.setkeyErrs = append(r.sys.setkeyErrs, &SetkeyError{RC: 2})
	}
	r.n.BootFinish(func() {})
	s.next(t)
	r.sys.now = r.sys.now.Add(61 * time.Second)
	sk := len(r.sys.setkeys)
	r.applyUpdateBody(cbor.M()) // a chain that is not one: Finish first, then refused
	r.applyUpdateBody(cbor.M())
	r.applyUpdateBody(cbor.M())
	if n := len(r.sys.setkeys) - sk; n != 1 {
		t.Fatalf("%d Finishes from 3 invalid updates within one backoff, want 1", n)
	}
	s.run <- struct{}{} // a retry in between does not open the backoff
	s.next(t)
	sk = len(r.sys.setkeys)
	r.applyUpdateBody(cbor.M())
	if n := len(r.sys.setkeys) - sk; n != 0 {
		t.Fatalf("an invalid update right after a failed retry ran %d Finish(es), want 0 (the verb backoff stands)", n)
	}
}

// (h) a failed retry does not raise the verb backoff: an owner's verb right after it runs its own Finish
func TestBootRetryVerbNotRefusedAfterFailedRetry(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	lb, s := withLog(r), newStepper(r.n)
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2}, &SetkeyError{RC: 2}}
	r.n.BootFinish(func() {})
	s.next(t)
	r.sys.now = r.sys.now.Add(61 * time.Second) // the boot failure's backoff (60 s) is over
	s.run <- struct{}{}
	s.next(t) // retry 1 failed (rc 2), the retry sleeps again
	if !lb.has("boot finish retry 1: ") {
		t.Fatalf("retry 1 did not fail: %q", lb.l)
	}
	if c := r.sshSet(); c != OK {
		t.Fatalf("an owner verb right after a failed retry: %d, want OK (its own Finish)", c)
	}
	if provstore.TxnPresent(r.n.P) {
		t.Fatal(".txn left after the verb's Finish")
	}
}

// (f') an OTA being written (batman-slot holds the slot flock) postpones the retry like a trial does; code review A m5 /
// B m4. Negative control: without the otaBusy gate the retry runs under the OTA.
func TestBootRetryPostponedWhileOTA(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	lb, s := withLog(r), newStepper(r.n)
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2}}
	r.n.BootFinish(func() {})
	s.next(t)
	f, err := os.OpenFile(filepath.Join(r.n.P.RunDir, "batman-slot.flock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	sk := len(r.sys.setkeys)
	s.run <- struct{}{}
	if d := s.next(t); d != bootRetryPostpone || len(r.sys.setkeys) != sk {
		t.Fatalf("with the slot flock held: wait %s, setkeys +%d (want postponed, none)", d, len(r.sys.setkeys)-sk)
	}
	if !lb.has("boot finish retry postponed: ota busy") {
		t.Fatalf("no postpone line: %q", lb.l)
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	f.Close()
	s.run <- struct{}{}
	lb.wait(t, "finished (boot retry 1)")
	r.settle()
	r.finishedCleanly("sae-v1-pass/m1/28")
}

// (d) a retry never overlaps a verb: while a verb holds the helper mutex the retry's try waits for it (code review A m5 /
// B m4)
func TestBootRetryWaitsForTheMutex(t *testing.T) {
	r, _ := memberRig(t)
	r.crashTxn2("sae-v2-pass", "m2", "36")
	lb, s := withLog(r), newStepper(r.n)
	r.sys.setkeyErrs = []error{&SetkeyError{RC: 2}}
	r.n.BootFinish(func() {})
	s.next(t)
	r.n.mu.Lock() // a verb in progress
	sk := len(r.sys.setkeys)
	s.run <- struct{}{}
	time.Sleep(300 * time.Millisecond)
	if len(r.sys.setkeys) != sk || lb.has("boot retry 1") {
		r.n.mu.Unlock()
		t.Fatal("the retry ran while the mutex was held")
	}
	r.n.mu.Unlock()
	lb.wait(t, "finished (boot retry 1)")
}
