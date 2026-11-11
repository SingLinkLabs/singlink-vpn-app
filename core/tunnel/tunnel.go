// Package tunnel turns a TUN device into SingLink connections, which is how
// the mobile apps (Android VpnService, iOS/macOS Network Extension) provide a
// device-wide VPN. IP packets from the device are fed into a user-space
// TCP/IP stack (gVisor netstack); every TCP connection and UDP flow it
// terminates is relayed through a SingLink client.
//
// DNS (UDP port 53, any address) is answered over DNS-over-TCP through the
// tunnel, so name resolution never leaks outside it.
package tunnel

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"github.com/SingLinkLabs/singlink-protocol/singlink"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// Device is a TUN device: each Read returns one IP packet and each Write
// sends one.
type Device interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
	Close() error
}

// Config configures a tunnel.
type Config struct {
	Client *singlink.Client
	MTU    int // default 1500
	// DNSUpstream receives the device's DNS queries over TCP through the
	// tunnel (default 1.1.1.1:53).
	DNSUpstream string
	// UDPIdle closes a UDP flow after this much inactivity (default 2m).
	UDPIdle time.Duration
}

// Tunnel is a running TUN-to-SingLink bridge.
type Tunnel struct {
	cfg    Config
	dev    Device
	stack  *stack.Stack
	ep     *channel.Endpoint
	ctx    context.Context
	cancel context.CancelFunc
	dns    *dnsClient
	wg     sync.WaitGroup

	// Flows counts TCP connections and UDP flows currently relayed.
	Flows atomic.Int64
}

// Start runs the tunnel until Close or until the device fails.
func Start(dev Device, cfg Config) (*Tunnel, error) {
	if cfg.Client == nil {
		return nil, errors.New("tunnel: client required")
	}
	if cfg.MTU == 0 {
		cfg.MTU = 1500
	}
	if cfg.DNSUpstream == "" {
		cfg.DNSUpstream = "1.1.1.1:53"
	}
	if cfg.UDPIdle == 0 {
		cfg.UDPIdle = 2 * time.Minute
	}
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	ep := channel.New(1024, uint32(cfg.MTU), "")
	if err := s.CreateNIC(1, ep); err != nil {
		return nil, errors.New("tunnel: create NIC: " + err.String())
	}
	// Accept packets for every destination and answer from any address.
	s.SetPromiscuousMode(1, true)
	s.SetSpoofing(1, true)
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: 1},
		{Destination: header.IPv6EmptySubnet, NIC: 1},
	})
	sackOpt := tcpip.TCPSACKEnabled(true)
	s.SetTransportProtocolOption(tcp.ProtocolNumber, &sackOpt)

	ctx, cancel := context.WithCancel(context.Background())
	t := &Tunnel{cfg: cfg, dev: dev, stack: s, ep: ep, ctx: ctx, cancel: cancel}
	t.dns = &dnsClient{t: t}

	tcpFwd := tcp.NewForwarder(s, 0, 2048, t.handleTCP)
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)
	udpFwd := udp.NewForwarder(s, t.handleUDP)
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)

	t.wg.Add(2)
	go t.readDevice()
	go t.writeDevice()
	return t, nil
}

// Close stops the tunnel and closes the device.
func (t *Tunnel) Close() {
	t.cancel()
	t.dev.Close()
	t.ep.Close()
	t.stack.Close()
	t.wg.Wait()
	t.dns.close()
}

// Done is closed when the tunnel stops.
func (t *Tunnel) Done() <-chan struct{} { return t.ctx.Done() }

func (t *Tunnel) readDevice() {
	defer t.wg.Done()
	defer t.cancel()
	buf := make([]byte, t.cfg.MTU+64)
	for {
		n, err := t.dev.Read(buf)
		if err != nil {
			return
		}
		if n < 1 {
			continue
		}
		var proto tcpip.NetworkProtocolNumber
		switch buf[0] >> 4 {
		case 4:
			proto = ipv4.ProtocolNumber
		case 6:
			proto = ipv6.ProtocolNumber
		default:
			continue
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), buf[:n]...))})
		t.ep.InjectInbound(proto, pkt)
		pkt.DecRef()
	}
}

func (t *Tunnel) writeDevice() {
	defer t.wg.Done()
	for {
		pkt := t.ep.ReadContext(t.ctx)
		if pkt == nil {
			return
		}
		v := pkt.ToView()
		_, err := t.dev.Write(v.AsSlice())
		v.Release()
		pkt.DecRef()
		if err != nil {
			t.cancel()
			return
		}
	}
}

func toAddrPort(a tcpip.Address, port uint16) netip.AddrPort {
	ip, _ := netip.AddrFromSlice(a.AsSlice())
	return netip.AddrPortFrom(ip.Unmap(), port)
}

func (t *Tunnel) handleTCP(r *tcp.ForwarderRequest) {
	id := r.ID()
	dst := toAddrPort(id.LocalAddress, id.LocalPort)
	var wq waiter.Queue
	ep, err := r.CreateEndpoint(&wq)
	if err != nil {
		r.Complete(true)
		return
	}
	r.Complete(false)
	local := gonet.NewTCPConn(&wq, ep)
	t.Flows.Add(1)
	go func() {
		defer t.Flows.Add(-1)
		defer local.Close()
		dctx, cancel := context.WithTimeout(t.ctx, 15*time.Second)
		remote, err := t.cfg.Client.DialTCP(dctx, dst.String())
		cancel()
		if err != nil {
			return
		}
		defer remote.Close()
		pipe(t.ctx, local, remote)
	}()
}

// pipe relays both directions; a clean EOF is passed on as a half close.
func pipe(ctx context.Context, a, b net.Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-ctx.Done()
		a.Close()
		b.Close()
	}()
	var wg sync.WaitGroup
	wg.Add(2)
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		_, err := io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok && err == nil {
			cw.CloseWrite()
			return
		}
		cancel()
	}
	go cp(a, b)
	go cp(b, a)
	wg.Wait()
}

func (t *Tunnel) handleUDP(r *udp.ForwarderRequest) bool {
	id := r.ID()
	dst := toAddrPort(id.LocalAddress, id.LocalPort)
	var wq waiter.Queue
	ep, err := r.CreateEndpoint(&wq)
	if err != nil {
		return true
	}
	local := gonet.NewUDPConn(&wq, ep)
	t.Flows.Add(1)
	go func() {
		defer t.Flows.Add(-1)
		defer local.Close()
		if dst.Port() == 53 {
			t.dns.serve(local)
			return
		}
		t.relayUDP(local, dst)
	}()
	return true
}

// relayUDP carries one UDP flow (one local source port) over its own
// SingLink UDP session.
func (t *Tunnel) relayUDP(local *gonet.UDPConn, dst netip.AddrPort) {
	ctx, cancel := context.WithTimeout(t.ctx, 15*time.Second)
	pc, err := t.cfg.Client.DialUDP(ctx)
	cancel()
	if err != nil {
		return
	}
	defer pc.Close()
	var last atomic.Int64
	last.Store(time.Now().UnixNano())
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			// The flow's endpoint is connected to the device, with the
			// destination as its local address: replies go out from there.
			b, _, err := pc.ReadFrom()
			if err != nil {
				return
			}
			last.Store(time.Now().UnixNano())
			if _, err := local.Write(b); err != nil {
				return
			}
		}
	}()
	buf := make([]byte, 65535)
	d := singlink.AddrFromAddrPort(dst)
	for {
		local.SetReadDeadline(time.Now().Add(t.cfg.UDPIdle))
		n, _, err := local.ReadFrom(buf)
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() && time.Since(time.Unix(0, last.Load())) < t.cfg.UDPIdle {
				select {
				case <-done:
					return
				case <-t.ctx.Done():
					return
				default:
					continue
				}
			}
			return
		}
		last.Store(time.Now().UnixNano())
		if pc.WriteTo(buf[:n], d) != nil {
			return
		}
	}
}
