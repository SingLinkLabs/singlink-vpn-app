// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

//go:build linux || darwin

package tunnel

import (
	"syscall"
	"testing"
	"time"
)

// A pending Read must return once the device is closed, even when no packet
// ever arrives (the OS took the TUN interface down).
func TestFDDeviceCloseWakesRead(t *testing.T) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(fds[1])
	dev := NewFDDevice(fds[0], false)

	if _, err := syscall.Write(fds[1], []byte{0x45, 1, 2}); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	if n, err := dev.Read(buf); err != nil || n != 3 || buf[0] != 0x45 {
		t.Fatalf("read = %d, %v", n, err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := dev.Read(buf)
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	dev.Close()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("read after close returned no error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not wake the pending Read")
	}
	if err := dev.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}
