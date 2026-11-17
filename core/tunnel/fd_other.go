// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

//go:build !linux && !darwin

package tunnel

import "errors"

// errNoFD is returned on platforms without a TUN file descriptor from the OS
// VPN API (Windows uses system-proxy mode with the local SOCKS5 listener).
var errNoFD = errors.New("TUN file descriptors are not supported on this platform")

type noFDDevice struct{}

// NewFDDevice exists so the C ABI builds everywhere; on this platform the
// device fails on first use and the tunnel stops.
func NewFDDevice(int, bool) Device { return noFDDevice{} }

// DupFDDevice always fails here: there is no TUN descriptor to duplicate,
// and the caller keeps (and closes) whatever it passed.
func DupFDDevice(int, bool) (Device, error) { return nil, errNoFD }

func (noFDDevice) Read([]byte) (int, error)  { return 0, errNoFD }
func (noFDDevice) Write([]byte) (int, error) { return 0, errNoFD }
func (noFDDevice) Close() error              { return nil }
