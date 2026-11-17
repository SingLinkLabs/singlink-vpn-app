// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

//go:build linux || darwin

package main

// A-04: descriptor ownership of SingLinkTunStart. The core never takes the
// caller's descriptor; it consumes exactly its own duplicate on every path.
// These tests drive the real pinned engine and the real tunnel against a
// synthetic loopback-only node, with fake devices (close counting) and real
// pipe descriptors (OS-level proof that exactly the duplicate was closed).

import (
	"context"
	"crypto/ed25519"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/SingLinkLabs/singlink-protocol/engine"
	"github.com/SingLinkLabs/singlink-protocol/singlink"

	"github.com/SingLinkLabs/singlink-vpn-app/core/tunnel"
)

// countingDevice blocks in Read until closed, like an idle TUN.
type countingDevice struct {
	closes  atomic.Int32
	once    sync.Once
	done    chan struct{}
	readErr error // returned at once by Read when set (a failed TUN)
}

func newCountingDevice() *countingDevice { return &countingDevice{done: make(chan struct{})} }

func (d *countingDevice) Read([]byte) (int, error) {
	if d.readErr != nil {
		return 0, d.readErr
	}
	<-d.done
	return 0, io.EOF
}
func (d *countingDevice) Write(p []byte) (int, error) { return len(p), nil }
func (d *countingDevice) Close() error {
	d.closes.Add(1)
	d.once.Do(func() { close(d.done) })
	return nil
}

// syntheticLink starts an in-process node on loopback that refuses every
// destination (so the engine's reachability probe never leaves the host)
// and returns a link for it.
func syntheticLink(t *testing.T) string {
	t.Helper()
	key, err := singlink.GenerateServerKey()
	if err != nil {
		t.Fatal(err)
	}
	issuer, _ := singlink.GenerateEd25519()
	dev, _ := singlink.GenerateEd25519()
	replay, err := singlink.InitializeReplayFile(filepath.Join(t.TempDir(), "state", "replay.db"), 0)
	if err != nil {
		t.Fatal(err)
	}
	srv, err := singlink.NewServer(singlink.ServerConfig{
		ReplayStore: replay,
		Key:         key,
		Issuers:     singlink.NewIssuers(issuer.Public().(ed25519.PublicKey)),
		DenyCIDRs:   []netip.Prefix{netip.MustParsePrefix("0.0.0.0/0"), netip.MustParsePrefix("::/0")},
		DialTimeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go srv.Serve(ln)
	time.Sleep(1100 * time.Millisecond) // first flights must be stamped after node start
	tok, err := singlink.IssueToken(issuer, &singlink.Token{DevicePub: dev.Public().(ed25519.PublicKey), Caps: singlink.CapTCP | singlink.CapUDP,
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	return (&singlink.Profile{Server: ln.Addr().String(), Transport: "tcp", ServerKey: key.Public(), Token: tok, Device: dev}).Link()
}

// silentLink returns a link to a loopback listener that accepts and never
// answers, so the engine's handshake blocks until cancelled.
func silentLink(t *testing.T) string {
	t.Helper()
	key, _ := singlink.GenerateServerKey()
	issuer, _ := singlink.GenerateEd25519()
	dev, _ := singlink.GenerateEd25519()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			t.Cleanup(func() { c.Close() })
		}
	}()
	tok, _ := singlink.IssueToken(issuer, &singlink.Token{DevicePub: dev.Public().(ed25519.PublicKey), Caps: singlink.CapTCP,
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)})
	return (&singlink.Profile{Server: ln.Addr().String(), Transport: "tcp", ServerKey: key.Public(), Token: tok, Device: dev}).Link()
}

// closedLink returns a link to a loopback port nothing listens on.
func closedLink(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	key, _ := singlink.GenerateServerKey()
	issuer, _ := singlink.GenerateEd25519()
	dev, _ := singlink.GenerateEd25519()
	tok, _ := singlink.IssueToken(issuer, &singlink.Token{DevicePub: dev.Public().(ed25519.PublicKey), Caps: singlink.CapTCP,
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)})
	return (&singlink.Profile{Server: addr, Transport: "tcp", ServerKey: key.Public(), Token: tok, Device: dev}).Link()
}

func setHook(t *testing.T, f func()) {
	testHookTunAcquired = f
	t.Cleanup(func() { testHookTunAcquired = nil })
}

func waitCloses(t *testing.T, d *countingDevice, want int32) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for d.closes.Load() != want && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	// Give any stray second close a chance to show up.
	time.Sleep(100 * time.Millisecond)
	if got := d.closes.Load(); got != want {
		t.Fatalf("device closed %d times, want %d", got, want)
	}
}

// The audited window: Stop lands after the tunnel took the device but before
// the engine published the session. The engine's stale-start cleanup closes
// the device; startTun must not close it again.
func TestStartTunCancelAfterAcquisitionClosesOnce(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	dev := newCountingDevice()
	setHook(t, func() { e.Stop() })
	err := startTun(&e, dev, link, tunnel.Config{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	waitCloses(t, dev, 1)
	if e.Status().Running {
		t.Fatal("engine still running after a cancelled start")
	}
}

// A panic after the tunnel took the device (before the cleanup reached the
// engine) closes the tunnel and the device exactly once, and the engine can
// start again afterwards.
func TestStartTunPanicAfterAcquisitionClosesOnce(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	dev := newCountingDevice()
	setHook(t, func() { panic("synthetic") })
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("no panic")
			}
		}()
		startTun(&e, dev, link, tunnel.Config{})
	}()
	waitCloses(t, dev, 1)
	testHookTunAcquired = nil
	deadline := time.Now().Add(5 * time.Second)
	for {
		next := newCountingDevice()
		err := startTun(&e, next, link, tunnel.Config{})
		if err == nil {
			e.Stop()
			waitCloses(t, next, 1)
			break
		}
		waitCloses(t, next, 1)
		if time.Now().After(deadline) {
			t.Fatalf("engine did not recover after the panic: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	waitCloses(t, dev, 1)
}

// Failures before the tunnel takes the device: the core closes it exactly
// once itself (and, at the FFI level, that device is only ever a duplicate).
func TestStartTunPreAcquisitionFailuresCloseOnce(t *testing.T) {
	cases := map[string]func(t *testing.T, e *engine.Engine) string{
		"bad link": func(*testing.T, *engine.Engine) string { return "singlink://not-a-valid-link" },
		"node unreachable": func(t *testing.T, _ *engine.Engine) string {
			return closedLink(t)
		},
		"engine busy": func(t *testing.T, e *engine.Engine) string {
			link := syntheticLink(t)
			if err := startTun(e, newCountingDevice(), link, tunnel.Config{}); err != nil {
				t.Fatalf("first start: %v", err)
			}
			t.Cleanup(e.Stop)
			return link
		},
		"stop during handshake": func(t *testing.T, e *engine.Engine) string {
			link := silentLink(t)
			time.AfterFunc(300*time.Millisecond, e.Stop)
			return link
		},
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			var e engine.Engine
			link := mk(t, &e)
			setHook(t, func() { t.Error("tunnel acquired the device on a pre-acquisition failure") })
			dev := newCountingDevice()
			if err := startTun(&e, dev, link, tunnel.Config{}); err == nil {
				t.Fatal("start succeeded")
			}
			waitCloses(t, dev, 1)
		})
	}
}

// After success the tunnel owns the device: stop closes it once, and a
// later Stop or the TUN watcher does not close it again.
func TestStartTunStopAfterSuccessClosesOnce(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	dev := newCountingDevice()
	if err := startTun(&e, dev, link, tunnel.Config{}); err != nil {
		t.Fatal(err)
	}
	if dev.closes.Load() != 0 {
		t.Fatal("device closed while the session runs")
	}
	e.Stop()
	e.Stop()
	waitCloses(t, dev, 1)
}

// A TUN that fails (Android revoke: reads error out) stops the session
// through the matching-client watcher; the device is closed once.
func TestStartTunWatcherFailureClosesOnce(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	dev := newCountingDevice()
	dev.readErr = syscall.EBADF
	if err := startTun(&e, dev, link, tunnel.Config{}); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	waitCloses(t, dev, 1)
	deadline := time.Now().Add(5 * time.Second)
	for e.Status().Running && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if e.Status().Running {
		t.Fatal("engine still running after the TUN failed")
	}
	e.Stop()
	waitCloses(t, dev, 1)
}

// pipeFD is a stand-in for the TUN descriptor Kotlin detaches: the read end
// of a pipe. Writing to the write end proves whether any descriptor still
// references the read end (EPIPE once every copy is closed).
type pipeFD struct{ r, w int }

func newPipeFD(t *testing.T) pipeFD {
	var p [2]int
	if err := syscall.Pipe(p[:]); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Close(p[1]) })
	return pipeFD{r: p[0], w: p[1]}
}

func inode(t *testing.T, fd int) uint64 {
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		t.Fatalf("fstat(%d): %v", fd, err)
	}
	return uint64(st.Ino)
}

// checkOnlyDuplicateClosed asserts the caller's descriptor is still open
// (same pipe, a reader exists), then closes it as the caller would and
// asserts no other copy is left (the duplicate was closed, not leaked).
func checkOnlyDuplicateClosed(t *testing.T, p pipeFD, ino uint64) {
	t.Helper()
	if got := inode(t, p.r); got != ino {
		t.Fatalf("caller's fd now refers to inode %d, want %d", got, ino)
	}
	if _, err := syscall.Write(p.w, []byte{0}); err != nil {
		t.Fatalf("write with the caller's fd open: %v", err)
	}
	if err := syscall.Close(p.r); err != nil {
		t.Fatalf("caller's close of its own fd: %v (closed by the core?)", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, err := syscall.Write(p.w, []byte{0})
		if errors.Is(err, syscall.EPIPE) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("write after the caller closed its fd = %v, want EPIPE (core duplicate leaked)", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// FFI-level contract with real descriptors: dup, start, cancel after the
// tunnel took the duplicate. Exactly the duplicate is closed by the core;
// the caller's descriptor stays valid for its single close.
func TestTunStartRealFDCancelAfterAcquisition(t *testing.T) {
	link := syntheticLink(t)
	p := newPipeFD(t)
	ino := inode(t, p.r)
	var e engine.Engine
	setHook(t, func() { e.Stop() })
	dev, err := tunnel.DupFDDevice(p.r, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := startTun(&e, dev, link, tunnel.Config{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	checkOnlyDuplicateClosed(t, p, ino)
}

func TestTunStartRealFDPreAcquisitionFailure(t *testing.T) {
	p := newPipeFD(t)
	ino := inode(t, p.r)
	var e engine.Engine
	dev, err := tunnel.DupFDDevice(p.r, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := startTun(&e, dev, "singlink://not-a-valid-link", tunnel.Config{}); err == nil {
		t.Fatal("start succeeded")
	}
	checkOnlyDuplicateClosed(t, p, ino)
}

func TestTunStartRealFDStopAfterSuccess(t *testing.T) {
	link := syntheticLink(t)
	p := newPipeFD(t)
	var e engine.Engine
	dev, err := tunnel.DupFDDevice(p.r, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := startTun(&e, dev, link, tunnel.Config{}); err != nil {
		t.Fatal(err)
	}
	// Android closes its original right after the call returned; the core's
	// duplicate keeps the interface (here: the pipe reader) alive.
	if err := syscall.Close(p.r); err != nil {
		t.Fatal(err)
	}
	if _, err := syscall.Write(p.w, []byte{0x45}); err != nil {
		t.Fatalf("core duplicate not alive while running: %v", err)
	}
	e.Stop()
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, err := syscall.Write(p.w, []byte{0})
		if errors.Is(err, syscall.EPIPE) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("write after stop = %v, want EPIPE (duplicate leaked)", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestDupFDDeviceRejectsInvalidFD(t *testing.T) {
	if _, err := tunnel.DupFDDevice(-1, false); err == nil {
		t.Fatal("negative fd accepted")
	}
	p := newPipeFD(t)
	syscall.Close(p.r)
	if _, err := tunnel.DupFDDevice(p.r, false); err == nil {
		t.Fatal("closed fd accepted")
	}
}

type fdIdent struct{ dev, ino uint64 }

// fdTable maps every open descriptor number of this process to the file it
// refers to (/proc/self/fd on Linux/Android, /dev/fd on Apple platforms).
func fdTable(t *testing.T) map[int]fdIdent {
	t.Helper()
	dir := "/proc/self/fd"
	if _, err := os.Stat(dir); err != nil {
		dir = "/dev/fd"
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	out := map[int]fdIdent{}
	for _, e := range entries {
		n, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		var st syscall.Stat_t
		if syscall.Fstat(n, &st) != nil {
			continue // the directory listing's own descriptor, already closed
		}
		out[n] = fdIdent{uint64(st.Dev), uint64(st.Ino)}
	}
	return out
}

func countRefs(table map[int]fdIdent, id fdIdent) int {
	n := 0
	for _, v := range table {
		if v == id {
			n++
		}
	}
	return n
}

// Process-wide descriptor table across the audited window: before the start
// only the caller's descriptor refers to the TUN stand-in; while the core
// runs there are exactly two (original + duplicate); after a cancelled start
// exactly one, the caller's, at the same number; every descriptor that was
// open before is still open on the same file (nothing unrelated was closed);
// after the caller's single close there are none.
func TestTunStartFDTableCancelAfterAcquisition(t *testing.T) {
	link := syntheticLink(t)
	p := newPipeFD(t)
	var st syscall.Stat_t
	if err := syscall.Fstat(p.r, &st); err != nil {
		t.Fatal(err)
	}
	tun := fdIdent{uint64(st.Dev), uint64(st.Ino)}
	before := fdTable(t)
	// The write end shares the identity on Linux, not on Apple platforms.
	base := countRefs(before, tun)
	if base < 1 || base > 2 {
		t.Fatalf("refs before = %d", base)
	}
	var e engine.Engine
	var during int
	setHook(t, func() {
		during = countRefs(fdTable(t), tun)
		e.Stop()
	})
	dev, err := tunnel.DupFDDevice(p.r, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := startTun(&e, dev, link, tunnel.Config{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if during != base+1 {
		t.Fatalf("refs while the tunnel held the duplicate = %d, want %d", during, base+1)
	}
	time.Sleep(200 * time.Millisecond)
	after := fdTable(t)
	if got := countRefs(after, tun); got != base {
		t.Fatalf("refs after the cancelled start = %d, want %d (duplicate leaked or original closed)", got, base)
	}
	if after[p.r] != tun {
		t.Fatalf("caller's descriptor %d no longer refers to the TUN stand-in", p.r)
	}
	for n, id := range before {
		if after[n] != id {
			t.Fatalf("descriptor %d changed from %v to %v: an unrelated descriptor was closed", n, id, after[n])
		}
	}
	if err := syscall.Close(p.r); err != nil {
		t.Fatalf("caller's single close: %v", err)
	}
	if got := countRefs(fdTable(t), tun); got != base-1 {
		t.Fatalf("refs after the caller's close = %d, want %d", got, base-1)
	}
}
