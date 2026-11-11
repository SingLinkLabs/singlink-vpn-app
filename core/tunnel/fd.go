//go:build linux || darwin

package tunnel

import (
	"errors"
	"syscall"
)

// fdDevice wraps a TUN file descriptor handed over by the OS VPN API
// (Android VpnService, Apple's utun under NEPacketTunnelProvider).
// On Apple platforms every packet carries a 4-byte address-family header.
type fdDevice struct {
	fd     int
	afHdr  bool
	wbuf   []byte
	closed chan struct{}
}

// NewFDDevice returns a Device for fd. Set appleHeader on macOS/iOS utun.
func NewFDDevice(fd int, appleHeader bool) Device {
	return &fdDevice{fd: fd, afHdr: appleHeader, closed: make(chan struct{})}
}

func (d *fdDevice) Read(p []byte) (int, error) {
	if !d.afHdr {
		n, err := syscall.Read(d.fd, p)
		return n, retryable(err)
	}
	buf := make([]byte, len(p)+4)
	n, err := syscall.Read(d.fd, buf)
	if err != nil {
		return 0, retryable(err)
	}
	if n < 4 {
		return 0, nil
	}
	return copy(p, buf[4:n]), nil
}

func (d *fdDevice) Write(p []byte) (int, error) {
	if !d.afHdr {
		return syscall.Write(d.fd, p)
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
	n, err := syscall.Write(d.fd, b)
	return max(n-4, 0), err
}

func (d *fdDevice) Close() error {
	select {
	case <-d.closed:
		return nil
	default:
		close(d.closed)
	}
	return syscall.Close(d.fd)
}

// retryable maps EINTR/EAGAIN to a zero-length read the loop simply repeats.
func retryable(err error) error {
	if errors.Is(err, syscall.EINTR) || errors.Is(err, syscall.EAGAIN) {
		return nil
	}
	return err
}
