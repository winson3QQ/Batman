// Package sock is the helper's socket (docs/design/254-stage1-impl.md §3, §4.1): SOCK_SEQPACKET at
// /tmp/run/batman-prov/helper.sock, dir root 0750 group provd, socket 0660; SO_PEERCRED uid must be provd's or the
// connection is closed; up to MaxConns connections at once (254-p2-impl §1.3: provd's ctl + ops and provclient), each
// served by its own goroutine, requests within one connection one at a time; at most AcceptPerSec new connections a
// second (counted once a connection passed SO_PEERCRED and sent its first request); a request is <= 64 KiB; 30 s idle
// timeout. Serialising state changes is the handler's (node's mutex), not the server's.
// The directory is created fresh by the helper (O_NOFOLLOW semantics: a pre-existing symlink / foreign-owned path is
// a refusal to start, never followed).
package sock

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"batman-prov/cbor"
)

// MaxRequest is the per-packet limit (219-protocol §8 / 254 §4.1).
const MaxRequest = 65536

// MaxConns connections are served at once; the next one is closed at once (254-p2-impl §3).
const MaxConns = 4

// AcceptPerSec: new connections admitted per second; more are closed (a churning peer cannot reset a per-connection
// quota faster than this, 254-p2-impl §4.3).
const AcceptPerSec = 5

// Handler answers one decoded request map.
type Handler func(cbor.Map) cbor.Map

// Server is the listening socket.
type Server struct {
	Path    string
	PeerUID int // the only uid allowed to talk (provd)
	GID     int // group of the socket dir / socket (provd)
	Idle    time.Duration
	Log     func(string, ...any)
	ln      *net.UnixListener

	mu       sync.Mutex
	open     int         // connections holding a slot
	admitted []time.Time // admissions in the last second
	rateLog  time.Time   // last "accept rate" log line (one a minute)
}

// PrepareDir makes the socket dir: removes OUR stale socket, refuses anything that is not a root-owned real dir.
func PrepareDir(dir string, gid int) error {
	fi, err := os.Lstat(dir)
	switch {
	case errors.Is(err, os.ErrNotExist):
		if err := os.Mkdir(dir, 0o750); err != nil {
			return err
		}
	case err != nil:
		return err
	default:
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !fi.IsDir() || fi.Mode()&os.ModeSymlink != 0 || !ok || st.Uid != 0 {
			return fmt.Errorf("sock: %s exists and is not a root-owned directory — refusing to start", dir)
		}
	}
	if err := os.Chown(dir, 0, gid); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o750); err != nil {
		return err
	}
	// only our own socket may be cleaned; anything else in the dir is a refusal (and stays for inspection)
	ents, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range ents {
		p := filepath.Join(dir, e.Name())
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		st, _ := fi.Sys().(*syscall.Stat_t)
		if e.Name() == "helper.sock" && fi.Mode()&os.ModeSocket != 0 && st != nil && st.Uid == 0 {
			os.Remove(p)
			continue
		}
		return fmt.Errorf("sock: unexpected %s in the socket dir — refusing to start", p)
	}
	return nil
}

// Listen creates the socket (0660, group gid).
func (s *Server) Listen() error {
	addr := &net.UnixAddr{Name: s.Path, Net: "unixpacket"}
	ln, err := net.ListenUnix("unixpacket", addr)
	if err != nil {
		return err
	}
	ln.SetUnlinkOnClose(true)
	if err := os.Chown(s.Path, 0, s.GID); err != nil {
		ln.Close()
		return err
	}
	if err := os.Chmod(s.Path, 0o660); err != nil {
		ln.Close()
		return err
	}
	s.ln = ln
	return nil
}

// Close stops listening.
func (s *Server) Close() error {
	if s.ln == nil {
		return nil
	}
	return s.ln.Close()
}

// Serve serves every connection with the same handler.
func (s *Server) Serve(h Handler) error { return s.ServeConns(func() Handler { return h }) }

// ServeConns accepts until the listener closes; each connection gets its own goroutine and the handler newConn returns
// for it (per-connection state such as a quota).
func (s *Server) ServeConns(newConn func() Handler) error {
	for {
		c, err := s.ln.AcceptUnix()
		if err != nil {
			return err
		}
		go s.serveConn(c, newConn)
	}
}

func (s *Server) takeSlot() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.open >= MaxConns {
		return false
	}
	s.open++
	return true
}

func (s *Server) releaseSlot() {
	s.mu.Lock()
	s.open--
	s.mu.Unlock()
}

// admit counts a connection that passed SO_PEERCRED and sent its first request (dead connections left in the backlog
// do not count, 254-p2-impl §3); false = over AcceptPerSec.
func (s *Server) admit() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	keep := s.admitted[:0]
	for _, t := range s.admitted {
		if now.Sub(t) < time.Second {
			keep = append(keep, t)
		}
	}
	s.admitted = keep
	if len(keep) >= AcceptPerSec {
		if now.Sub(s.rateLog) >= time.Minute {
			s.rateLog = now
			s.Log("connection closed: more than %d new connections a second", AcceptPerSec)
		}
		return false
	}
	s.admitted = append(s.admitted, now)
	return true
}

func peerUID(c *net.UnixConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return -1, err
	}
	uid := -1
	var gerr error
	raw.Control(func(fd uintptr) {
		cred, err := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		if err != nil {
			gerr = err
			return
		}
		uid = int(cred.Uid)
	})
	return uid, gerr
}

func (s *Server) serveConn(c *net.UnixConn, newConn func() Handler) {
	defer c.Close()
	uid, err := peerUID(c)
	if err != nil || uid != s.PeerUID {
		s.Log("connection refused: peer uid %d (want %d) %v", uid, s.PeerUID, err)
		return
	}
	// the slot is freed only when this goroutine ends: a handler still running a long verb for a peer that went away
	// keeps it (254-p2-impl L81)
	if !s.takeSlot() {
		s.Log("connection refused: %d connections open", MaxConns)
		return
	}
	defer s.releaseSlot()
	h := newConn()
	buf := make([]byte, MaxRequest+1)
	first := true
	for {
		c.SetReadDeadline(time.Now().Add(s.Idle))
		n, err := c.Read(buf)
		if err != nil {
			return
		}
		if first {
			first = false
			if !s.admit() {
				return
			}
		}
		if n > MaxRequest {
			s.Log("request > 64 KiB: closing")
			return
		}
		x, err := cbor.Decode(buf[:n])
		m, ok := x.(cbor.Map)
		if err != nil || !ok {
			// a malformed packet ends the connection (the client is broken or hostile)
			resp, _ := cbor.Encode(cbor.M(1, uint64(0), 2, uint64(20), 3, cbor.M()))
			c.Write(resp)
			return
		}
		out, err := cbor.Encode(h(m))
		if err != nil {
			return
		}
		c.SetWriteDeadline(time.Now().Add(s.Idle))
		if _, err := c.Write(out); err != nil {
			return
		}
	}
}
