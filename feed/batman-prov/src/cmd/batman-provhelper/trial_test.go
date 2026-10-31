package main

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// 254-p2-impl §9: a slow is-trial (stub sleeps) does not hold info.state once a value exists (stale-while-revalidate),
// and concurrent callers share one exec (single-flight). Mutant: exec on every call -> the stale read takes 2 s ->
// FAIL; no single-flight -> calls > 1 -> FAIL.
func TestTrialCacheStaleWhileRevalidate(t *testing.T) {
	var calls atomic.Int32
	slow := make(chan struct{})
	c := newTrialCache(50*time.Millisecond, func() bool {
		if calls.Add(1) > 1 {
			<-slow
		}
		return true
	})
	if !c.Trial() || calls.Load() != 1 { // no value yet: waits for the first exec
		t.Fatalf("first read: calls=%d", calls.Load())
	}
	time.Sleep(60 * time.Millisecond) // stale now
	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); c.Trial() }()
	}
	wg.Wait()
	if d := time.Since(start); d > time.Second {
		t.Fatalf("stale reads waited %s for the refresh", d)
	}
	time.Sleep(20 * time.Millisecond)
	if n := calls.Load(); n != 2 {
		t.Fatalf("%d execs for 10 concurrent stale reads (want 1 refresh)", n-1)
	}
	close(slow)
}

// a fresh value is not re-executed
func TestTrialCacheFresh(t *testing.T) {
	var calls atomic.Int32
	c := newTrialCache(time.Minute, func() bool { calls.Add(1); return false })
	for i := 0; i < 5; i++ {
		if c.Trial() {
			t.Fatal("committed read as trial")
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("%d execs", calls.Load())
	}
}
