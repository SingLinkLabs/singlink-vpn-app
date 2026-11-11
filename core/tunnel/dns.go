package tunnel

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

// dnsClient answers the device's DNS queries with DNS-over-TCP (RFC 7766)
// through the tunnel, reusing a few idle connections.
type dnsClient struct {
	t    *Tunnel
	mu   sync.Mutex
	idle []net.Conn
}

const maxIdleDNS = 4

func (d *dnsClient) serve(local *gonet.UDPConn) {
	buf := make([]byte, 4096)
	for {
		local.SetReadDeadline(time.Now().Add(30 * time.Second))
		n, from, err := local.ReadFrom(buf)
		if err != nil {
			return
		}
		q := append([]byte(nil), buf[:n]...)
		go func() {
			if resp, err := d.query(q); err == nil {
				local.WriteTo(resp, from)
			}
		}()
	}
}

func (d *dnsClient) query(q []byte) ([]byte, error) {
	for attempt := 0; attempt < 2; attempt++ {
		c, reused, err := d.get()
		if err != nil {
			return nil, err
		}
		resp, err := exchange(c, q)
		if err == nil {
			d.put(c)
			return resp, nil
		}
		c.Close()
		if !reused {
			return nil, err
		}
		// A reused connection may have been closed by the server: retry once.
	}
	return nil, io.ErrUnexpectedEOF
}

func exchange(c net.Conn, q []byte) ([]byte, error) {
	c.SetDeadline(time.Now().Add(8 * time.Second))
	msg := binary.BigEndian.AppendUint16(nil, uint16(len(q)))
	if _, err := c.Write(append(msg, q...)); err != nil {
		return nil, err
	}
	var l [2]byte
	if _, err := io.ReadFull(c, l[:]); err != nil {
		return nil, err
	}
	resp := make([]byte, binary.BigEndian.Uint16(l[:]))
	if _, err := io.ReadFull(c, resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func (d *dnsClient) get() (net.Conn, bool, error) {
	d.mu.Lock()
	if n := len(d.idle); n > 0 {
		c := d.idle[n-1]
		d.idle = d.idle[:n-1]
		d.mu.Unlock()
		return c, true, nil
	}
	d.mu.Unlock()
	ctx, cancel := context.WithTimeout(d.t.ctx, 10*time.Second)
	defer cancel()
	c, err := d.t.cfg.Client.DialTCP(ctx, d.t.cfg.DNSUpstream)
	return c, false, err
}

func (d *dnsClient) put(c net.Conn) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.idle) >= maxIdleDNS {
		c.Close()
		return
	}
	d.idle = append(d.idle, c)
}

func (d *dnsClient) close() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, c := range d.idle {
		c.Close()
	}
	d.idle = nil
}
