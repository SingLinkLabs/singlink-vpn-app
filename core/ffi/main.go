// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// Command ffi builds libsinglink for the SingLinkVPN apps: the protocol's C ABI
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
	return out(map[string]string{
		"version":     singlink.Version,
		"protocol":    singlink.ProtocolName,
		"attribution": "SingLinkVPN client, software provided by the original author SingLinkVPN · " + singlink.Attribution,
	})
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
	return out(startLocal(&eng, C.GoString(config)))
}

// startLocal starts the local SOCKS5/HTTP proxy port for config:
//
//	{"link":"singlink://...","listen":"127.0.0.1:1080","auth":true}
//
// "auth" defaults to true: the engine then requires a random username and
// password (crypto/rand, new for every start, held only in memory) on every
// SOCKS5 and HTTP proxy request, so other local processes and users cannot
// relay through the tunnel. The reply carries them for the app to show; it
// never logs or stores them. Only an explicit "auth":false (the desktop
// system-proxy mode: OS proxy settings cannot carry credentials) leaves
// the loopback port open to every local process.
func startLocal(e *engine.Engine, config string) map[string]any {
	var cfg struct {
		Link   string `json:"link"`
		Listen string `json:"listen"`
		Auth   *bool  `json:"auth"`
	}
	if err := json.Unmarshal([]byte(config), &cfg); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	auth := cfg.Auth == nil || *cfg.Auth
	// StartAuth returns this session's own credentials; they cannot belong
	// to a session started or stopped in between.
	user, pass, err := e.StartAuth(cfg.Link, cfg.Listen, engine.Options{Auth: auth})
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if auth && (user == "" || pass == "") {
		// Never report an unauthenticated port as protected.
		e.Stop()
		return map[string]any{"ok": false, "error": "local proxy authentication could not be enabled"}
	}
	st := e.Status()
	return map[string]any{"ok": true, "listen": st.Listen, "auth": auth, "username": user, "password": pass}
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

// SingLinkTunStart relays all device traffic arriving on a TUN file
// descriptor from the OS VPN API through the node in config:
//
//	{"link":"singlink://...","mtu":1500,"dns":"1.1.1.1:53","appleHeader":false}
//
// appleHeader must be true for the utun descriptor of an Apple Network
// Extension.
//
// Descriptor ownership does not depend on the result: the core never takes
// fd. It works on its own close-on-exec duplicate, which it always consumes:
// closed before returning on any failure (bad config, busy engine, node
// unreachable, handshake failure, a Stop that cancelled the start before or
// after the tunnel took the duplicate), otherwise closed by SingLinkTunStop /
// SingLinkStop or when the TUN fails. The caller keeps fd and closes it
// exactly once after this call has returned, whatever it returned (Android:
// the bridge's detached descriptor; Apple: the extension's utun, owned by
// the Network Extension). The caller must not close fd while the call is in
// progress: the number could be reused before the duplicate is made.
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
	dev, err := tunnel.DupFDDevice(int(fd), cfg.AppleHeader)
	if err != nil {
		return fail(fmt.Errorf("cannot duplicate the TUN descriptor: %w", err))
	}
	if err := startTun(&eng, dev, cfg.Link, tunnel.Config{MTU: cfg.MTU, DNSUpstream: cfg.DNS}); err != nil {
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
