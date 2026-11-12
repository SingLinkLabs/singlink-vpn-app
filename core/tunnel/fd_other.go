// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
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

func (noFDDevice) Read([]byte) (int, error)  { return 0, errNoFD }
func (noFDDevice) Write([]byte) (int, error) { return 0, errNoFD }
func (noFDDevice) Close() error              { return nil }
