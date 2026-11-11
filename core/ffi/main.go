// Command ffi builds libsinglink for the 星連VPN apps: the protocol's C ABI
// (SingLinkStart, SingLinkStatus, ...) plus the device-wide VPN entry points
// used on Android and iOS/macOS (SingLinkTunStart, SingLinkTunStop).
//
// Every function returns a JSON string allocated with malloc that the caller
// must release with SingLinkFree. See core/Makefile for per-platform builds.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync"
	"time"
	"unsafe"

	"github.com/SingLinkLabs/singlink-protocol/engine"
	"github.com/SingLinkLabs/singlink-protocol/singlink"

	"github.com/SingLinkLabs/singlink-vpn-app/core/tunnel"
)

var (
	eng    engine.Engine
	tunMu  sync.Mutex
	curTun *tunnel.Tunnel
)

func out(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"ok":false,"error":"internal encoding error"}`)
	}
	return C.CString(string(b))
}

func fail(err error) *C.char { return out(map[string]any{"ok": false, "error": err.Error()}) }

// guard turns a panic into an error reply instead of killing the host app.
// Every export is synchronous and may block: call it off the UI thread.
func guard(res **C.char) {
	if r := recover(); r != nil {
		*res = fail(fmt.Errorf("internal error: %v", r))
	}
}

//export SingLinkVersion
func SingLinkVersion() (res *C.char) {
	defer guard(&res)
	return out(map[string]string{"version": singlink.Version, "protocol": singlink.ProtocolName})
}

//export SingLinkParseLink
func SingLinkParseLink(link *C.char) (res *C.char) {
	defer guard(&res)
	p, err := singlink.ParseLink(C.GoString(link))
	if err != nil {
		return fail(err)
	}
	t, err := p.TokenInfo()
	if err != nil {
		return fail(err)
	}
	var caps []string
	if t.Has(singlink.CapTCP) {
		caps = append(caps, "tcp")
	}
	if t.Has(singlink.CapUDP) {
		caps = append(caps, "udp")
	}
	return out(map[string]any{"ok": true, "profile": map[string]any{
		"name":      p.Name,
		"server":    p.Server,
		"transport": p.Transport,
		"sni":       p.SNI,
		"subject":   hex.EncodeToString(t.Subject[:]),
		"plan":      t.Plan,
		"expiresAt": t.NotAfter.Unix(),
		"caps":      caps,
		"rateKbps":  t.RateKbps,
		"maxConns":  t.MaxConns,
	}, "warnings": p.Warnings()})
}

//export SingLinkStart
func SingLinkStart(config *C.char) (res *C.char) {
	defer guard(&res)
	var cfg struct {
		Link   string `json:"link"`
		Listen string `json:"listen"`
		Auth   bool   `json:"auth"`
	}
	if err := json.Unmarshal([]byte(C.GoString(config)), &cfg); err != nil {
		return fail(err)
	}
	if err := eng.Start(cfg.Link, cfg.Listen, engine.Options{Auth: cfg.Auth}); err != nil {
		return fail(err)
	}
	user, pass := eng.Credentials()
	return out(map[string]any{"ok": true, "username": user, "password": pass})
}

//export SingLinkStop
func SingLinkStop() (res *C.char) {
	defer guard(&res)
	eng.Stop()
	return out(map[string]any{"ok": true})
}

//export SingLinkStatus
func SingLinkStatus() *C.char { return out(eng.Status()) }

//export SingLinkProbe
func SingLinkProbe(url *C.char, timeoutMs C.int) (res *C.char) {
	defer guard(&res)
	code, d, err := eng.Probe(C.GoString(url), time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return fail(err)
	}
	return out(map[string]any{"ok": true, "status": code, "latencyMs": d.Milliseconds()})
}

//export SingLinkExitIP
func SingLinkExitIP(timeoutMs C.int) (res *C.char) {
	defer guard(&res)
	ip, err := eng.ExitIP(time.Duration(timeoutMs) * time.Millisecond)
	if err != nil {
		return fail(err)
	}
	return out(map[string]any{"ok": true, "ip": ip})
}

// SingLinkTunStart takes over a TUN file descriptor from the OS VPN API and
// relays all device traffic through the node in config:
//
//	{"link":"singlink://...","mtu":1500,"dns":"1.1.1.1:53","appleHeader":false}
//
// appleHeader must be true for the utun descriptor of an Apple Network
// Extension. The descriptor is closed by SingLinkTunStop / SingLinkStop.
//
//export SingLinkTunStart
func SingLinkTunStart(fd C.int, config *C.char) (res *C.char) {
	defer guard(&res)
	var cfg struct {
		Link        string `json:"link"`
		MTU         int    `json:"mtu"`
		DNS         string `json:"dns"`
		AppleHeader bool   `json:"appleHeader"`
	}
	if err := json.Unmarshal([]byte(C.GoString(config)), &cfg); err != nil {
		return fail(err)
	}
	err := eng.StartWith(cfg.Link, "tun", func(c *singlink.Client) (func(), error) {
		t, err := tunnel.Start(tunnel.NewFDDevice(int(fd), cfg.AppleHeader), tunnel.Config{Client: c, MTU: cfg.MTU, DNSUpstream: cfg.DNS})
		if err != nil {
			return nil, err
		}
		tunMu.Lock()
		curTun = t
		tunMu.Unlock()
		// If the OS tears this TUN down, stop the engine as well (but never
		// a newer session started after this one).
		go func() {
			<-t.Done()
			tunMu.Lock()
			mine := curTun == t
			tunMu.Unlock()
			if mine {
				eng.Stop()
			}
		}()
		return func() {
			tunMu.Lock()
			if curTun == t {
				curTun = nil
			}
			tunMu.Unlock()
			t.Close()
		}, nil
	})
	if err != nil {
		return fail(err)
	}
	return out(map[string]any{"ok": true})
}

//export SingLinkTunStop
func SingLinkTunStop() (res *C.char) {
	defer guard(&res)
	eng.Stop()
	return out(map[string]any{"ok": true})
}

//export SingLinkFree
func SingLinkFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
