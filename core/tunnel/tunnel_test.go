package tunnel

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"github.com/SingLinkLabs/singlink-protocol/singlink"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// phone simulates the device's own network stack: its packets go into the
// tunnel exactly as a TUN interface would deliver them.
type phone struct {
	s  *stack.Stack
	ep *channel.Endpoint
}

func newPhone(t *testing.T) *phone {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	ep := channel.New(1024, 1500, "")
	if err := s.CreateNIC(1, ep); err != nil {
		t.Fatal(err)
	}
	s.AddProtocolAddress(1, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddrFrom4([4]byte{172, 19, 0, 1}).WithPrefix(),
	}, stack.AddressProperties{})
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	t.Cleanup(func() { s.Close() })
	return &phone{s: s, ep: ep}
}

// device is the TUN side the tunnel reads from and writes to.
type device struct {
	p      *phone
	ctx    context.Context
	cancel context.CancelFunc
}

func (d *device) Read(b []byte) (int, error) {
	pkt := d.p.ep.ReadContext(d.ctx)
	if pkt == nil {
		return 0, io.EOF
	}
	defer pkt.DecRef()
	v := pkt.ToView()
	defer v.Release()
	return copy(b, v.AsSlice()), nil
}

func (d *device) Write(b []byte) (int, error) {
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), b...))})
	d.p.ep.InjectInbound(ipv4.ProtocolNumber, pkt)
	pkt.DecRef()
	return len(b), nil
}

func (d *device) Close() error { d.cancel(); return nil }

// node starts a SingLink node allowing private destinations and returns a
// client for it.
func node(t *testing.T) *singlink.Client {
	t.Helper()
	key, _ := singlink.GenerateServerKey()
	issuer, _ := singlink.GenerateEd25519()
	dev, _ := singlink.GenerateEd25519()
	srv, err := singlink.NewServer(singlink.ServerConfig{Key: key, Issuers: singlink.NewIssuers(issuer.Public().(ed25519.PublicKey)), AllowPrivate: true})
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
	tok, _ := singlink.IssueToken(issuer, &singlink.Token{DevicePub: dev.Public().(ed25519.PublicKey), Caps: singlink.CapTCP | singlink.CapUDP,
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)})
	return singlink.NewClient(&singlink.Profile{Server: ln.Addr().String(), Transport: "tcp", ServerKey: key.Public(), Token: tok, Device: dev})
}

func setup(t *testing.T, dnsUpstream string) (*phone, *Tunnel) {
	p := newPhone(t)
	ctx, cancel := context.WithCancel(context.Background())
	tun, err := Start(&device{p: p, ctx: ctx, cancel: cancel}, Config{Client: node(t), DNSUpstream: dnsUpstream})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(tun.Close)
	// The test targets live on 127.0.0.1; real TUN traffic never does.
	loop := tcpip.AllowExternalLoopbackTrafficOption(true)
	tun.stack.SetNetworkProtocolOption(ipv4.ProtocolNumber, &loop)
	p.s.SetNetworkProtocolOption(ipv4.ProtocolNumber, &loop)
	return p, tun
}

func fullAddr(ap netip.AddrPort) tcpip.FullAddress {
	return tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(ap.Addr().AsSlice()), Port: ap.Port()}
}

func TestTCPThroughTunnel(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	p, tun := setup(t, "")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := gonet.DialContextTCP(ctx, p.s, fullAddr(netip.MustParseAddrPort(ln.Addr().String())), ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	msg := bytes.Repeat([]byte("singlink-vpn "), 50000) // ~650 KB, many segments
	go c.Write(msg)
	got := make([]byte, len(msg))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatal("echo mismatch")
	}
	if tun.Flows.Load() < 1 {
		t.Fatal("flow not counted")
	}
}

func TestUDPAndDNSThroughTunnel(t *testing.T) {
	// UDP echo target.
	uc, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	defer uc.Close()
	go func() {
		b := make([]byte, 2048)
		for {
			n, from, err := uc.ReadFromUDP(b)
			if err != nil {
				return
			}
			uc.WriteToUDP(append([]byte("re:"), b[:n]...), from)
		}
	}()
	// DNS-over-TCP upstream that answers every query with "answer:" + query.
	dl, _ := net.Listen("tcp", "127.0.0.1:0")
	defer dl.Close()
	go func() {
		for {
			c, err := dl.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				for {
					var l [2]byte
					if _, err := io.ReadFull(c, l[:]); err != nil {
						return
					}
					q := make([]byte, binary.BigEndian.Uint16(l[:]))
					io.ReadFull(c, q)
					a := append([]byte("answer:"), q...)
					c.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(a))), a...))
				}
			}()
		}
	}()
	p, _ := setup(t, dl.Addr().String())

	exchange := func(dst netip.AddrPort, msg string) string {
		c, err := gonet.DialUDP(p.s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(dst.Addr().AsSlice()), Port: dst.Port()}, ipv4.ProtocolNumber)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(10 * time.Second))
		c.Write([]byte(msg))
		b := make([]byte, 2048)
		n, err := c.Read(b)
		if err != nil {
			t.Fatal(err)
		}
		return string(b[:n])
	}
	if got := exchange(netip.MustParseAddrPort(uc.LocalAddr().String()), "ping"); got != "re:ping" {
		t.Fatalf("udp: %q", got)
	}
	// Any address on port 53 is DNS: answered through the tunnel over TCP.
	for i, q := range []string{"query-1", "query-2"} {
		if got := exchange(netip.MustParseAddrPort("172.19.0.2:53"), q); got != "answer:"+q {
			t.Fatalf("dns %d: %q", i, got)
		}
	}
}

func TestCloseStopsTunnel(t *testing.T) {
	_, tun := setup(t, "")
	done := make(chan struct{})
	go func() { tun.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close hung")
	}
	select {
	case <-tun.Done():
	default:
		t.Fatal("Done not closed")
	}
	_ = errors.New
}
