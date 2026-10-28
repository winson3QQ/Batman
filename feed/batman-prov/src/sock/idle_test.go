package sock

import (
	"os"
	"testing"
	"time"
)

// prov-unit-auth (254-p1-impl §5.1) "timeout": a connection that sends nothing is closed by the server after Idle
// (2 s in start()), not held open.
func TestIdleConnectionClosed(t *testing.T) {
	needRoot(t)
	p, _ := start(t, os.Getuid())
	c := dial(t, p)
	defer c.Close()
	c.SetDeadline(time.Now().Add(6 * time.Second))
	t0 := time.Now()
	buf := make([]byte, 64)
	n, err := c.Read(buf)
	el := time.Since(t0)
	if err == nil && n > 0 {
		t.Fatalf("the server sent %d bytes to a silent client", n)
	}
	if el < 1500*time.Millisecond || el > 5*time.Second {
		t.Fatalf("closed after %v (want about the 2 s idle limit, before the client's own 6 s deadline)", el)
	}
}
