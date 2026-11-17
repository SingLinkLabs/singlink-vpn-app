// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

//go:build linux || darwin

package tunnel

import (
	"os"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

// fdDevice wraps a TUN file descriptor handed over by the OS VPN API
// (Android VpnService, Apple's utun under NEPacketTunnelProvider).
// On Apple platforms every packet carries a 4-byte address-family header.
//
// The descriptor is switched to non-blocking mode and read through Go's
// poller (os.File): a plain blocking read(2) is not woken by close(2), so
// once the OS takes the interface down (Android onRevoke) no packet ever
// arrives, Tunnel.Close waits forever and the interface leaks.
type fdDevice struct {
	f     *os.File
	afHdr bool
	wbuf  []byte
	once  sync.Once
}

// NewFDDevice returns a Device that takes ownership of fd: closing the
// Device closes fd. Set appleHeader on macOS/iOS utun.
func NewFDDevice(fd int, appleHeader bool) Device {
	syscall.SetNonblock(fd, true)
	return &fdDevice{f: os.NewFile(uintptr(fd), "tun"), afHdr: appleHeader}
}

// DupFDDevice returns a Device over a close-on-exec duplicate of fd and
// never takes fd itself: the caller still owns fd and must close it, and
// closing the Device closes only the duplicate. On error nothing was
// duplicated and there is nothing to close.
//
// This is the ownership contract of SingLinkTunStart: whatever the start
// result, the core consumes exactly its own duplicate and the OS VPN layer
// closes exactly its original, so a failed or cancelled start can never
// make both sides close the same descriptor number.
func DupFDDevice(fd int, appleHeader bool) (Device, error) {
	if fd < 0 {
		return nil, syscall.EBADF
	}
	// F_DUPFD_CLOEXEC duplicates and marks close-on-exec atomically, so no
	// child forked meanwhile (by Go, Java or native code) inherits it.
	dup, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return NewFDDevice(dup, appleHeader), nil
}

func (d *fdDevice) Read(p []byte) (int, error) {
	if !d.afHdr {
		return d.f.Read(p)
	}
	buf := make([]byte, len(p)+4)
	n, err := d.f.Read(buf)
	if err != nil {
		return 0, err
	}
	if n < 4 {
		return 0, nil
	}
	return copy(p, buf[4:n]), nil
}

func (d *fdDevice) Write(p []byte) (int, error) {
	if !d.afHdr {
		return d.f.Write(p)
	}
	if cap(d.wbuf) < len(p)+4 {
		d.wbuf = make([]byte, len(p)+4)
	}
	b := d.wbuf[:len(p)+4]
	af := byte(syscall.AF_INET)
	if len(p) > 0 && p[0]>>4 == 6 {
		af = syscall.AF_INET6
	}
	b[0], b[1], b[2], b[3] = 0, 0, 0, af
	copy(b[4:], p)
	n, err := d.f.Write(b)
	return max(n-4, 0), err
}

// Close closes the descriptor and wakes a pending Read.
func (d *fdDevice) Close() error {
	var err error
	d.once.Do(func() { err = d.f.Close() })
	return err
}
