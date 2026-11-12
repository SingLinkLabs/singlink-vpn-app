// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

//go:build linux || darwin

package tunnel

import (
	"os"
	"sync"
	"syscall"
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

// NewFDDevice returns a Device for fd. Set appleHeader on macOS/iOS utun.
func NewFDDevice(fd int, appleHeader bool) Device {
	syscall.SetNonblock(fd, true)
	return &fdDevice{f: os.NewFile(uintptr(fd), "tun"), afHdr: appleHeader}
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
