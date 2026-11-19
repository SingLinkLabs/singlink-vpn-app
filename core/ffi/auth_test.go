// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

//go:build linux || darwin

package main

// App F-01 (VPN Labs): the local proxy port requires the engine's random
// credentials unless the app explicitly turns authentication off for the
// desktop system-proxy mode. These tests drive startLocal (the body of the
// exported SingLinkStart) against the real pinned engine and a synthetic
// loopback node; core/ffi/cabi_test.go repeats the refusal checks through
// the real C ABI.

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/SingLinkLabs/singlink-protocol/engine"
)

func startLocalJSON(t *testing.T, e *engine.Engine, cfg map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return startLocal(e, string(raw))
}

func dialProxy(t *testing.T, addr string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(5 * time.Second))
	t.Cleanup(func() { c.Close() })
	return c
}

// socksGreeting offers the given methods and returns the method the
// server selected (0xFF: none acceptable).
func socksGreeting(t *testing.T, c net.Conn, methods ...byte) byte {
	t.Helper()
	if _, err := c.Write(append([]byte{5, byte(len(methods))}, methods...)); err != nil {
		t.Fatal(err)
	}
	var reply [2]byte
	if _, err := io.ReadFull(c, reply[:]); err != nil {
		t.Fatalf("greeting reply: %v", err)
	}
	if reply[0] != 5 {
		t.Fatalf("greeting reply version %d", reply[0])
	}
	return reply[1]
}

// socksLogin runs RFC 1929 and returns the status byte (0 = success).
func socksLogin(t *testing.T, c net.Conn, user, pass string) byte {
	t.Helper()
	msg := []byte{1, byte(len(user))}
	msg = append(msg, user...)
	msg = append(msg, byte(len(pass)))
	msg = append(msg, pass...)
	if _, err := c.Write(msg); err != nil {
		t.Fatal(err)
	}
	var reply [2]byte
	if _, err := io.ReadFull(c, reply[:]); err != nil {
		// A refused login may also just close the connection.
		return 0xFF
	}
	return reply[1]
}

func httpConnectStatus(t *testing.T, addr, auth string) int {
	t.Helper()
	c := dialProxy(t, addr)
	req := "CONNECT 192.0.2.1:443 HTTP/1.1\r\nHost: 192.0.2.1:443\r\n"
	if auth != "" {
		req += "Proxy-Authorization: Basic " + auth + "\r\n"
	}
	if _, err := io.WriteString(c, req+"\r\n"); err != nil {
		t.Fatal(err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatalf("HTTP proxy reply: %v", err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func TestStartLocalRequiresCredentialsWhenAuthRequested(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	t.Cleanup(e.Stop)
	reply := startLocalJSON(t, &e, map[string]any{"link": link, "listen": "127.0.0.1:0", "auth": true})
	if reply["ok"] != true || reply["auth"] != true {
		t.Fatalf("start reply = %v", reply)
	}
	user, _ := reply["username"].(string)
	pass, _ := reply["password"].(string)
	if len(user) < 16 || len(pass) < 16 || user == pass {
		t.Fatalf("weak or missing credentials: user %d chars, password %d chars", len(user), len(pass))
	}
	addr, _ := reply["listen"].(string)
	if !strings.HasPrefix(addr, "127.0.0.1:") || strings.HasSuffix(addr, ":0") {
		t.Fatalf("listen = %q", addr)
	}

	// A client that offers only "no authentication" is refused.
	if m := socksGreeting(t, dialProxy(t, addr), 0); m != 0xFF {
		t.Fatalf("SOCKS5 without credentials: server selected method %#x, want 0xFF", m)
	}
	// Wrong password and wrong username are refused.
	c := dialProxy(t, addr)
	if m := socksGreeting(t, c, 0, 2); m != 2 {
		t.Fatalf("SOCKS5 server selected method %#x, want username/password", m)
	}
	if st := socksLogin(t, c, user, pass+"x"); st == 0 {
		t.Fatal("SOCKS5 login with a wrong password succeeded")
	}
	c = dialProxy(t, addr)
	socksGreeting(t, c, 2)
	if st := socksLogin(t, c, "x"+user, pass); st == 0 {
		t.Fatal("SOCKS5 login with a wrong username succeeded")
	}
	// The right credentials are accepted.
	c = dialProxy(t, addr)
	socksGreeting(t, c, 2)
	if st := socksLogin(t, c, user, pass); st != 0 {
		t.Fatalf("SOCKS5 login with the session credentials: status %d", st)
	}

	// HTTP proxy requests need Proxy-Authorization too.
	if code := httpConnectStatus(t, addr, ""); code != http.StatusProxyAuthRequired {
		t.Fatalf("HTTP CONNECT without credentials: %d, want 407", code)
	}
	bad := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass + "x"))
	if code := httpConnectStatus(t, addr, bad); code != http.StatusProxyAuthRequired {
		t.Fatalf("HTTP CONNECT with a wrong password: %d, want 407", code)
	}
	good := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass))
	if code := httpConnectStatus(t, addr, good); code == http.StatusProxyAuthRequired {
		t.Fatal("HTTP CONNECT with the session credentials was refused as unauthenticated")
	}

	// Every start gets new credentials.
	e.Stop()
	again := startLocalJSON(t, &e, map[string]any{"link": link, "listen": "127.0.0.1:0", "auth": true})
	if again["ok"] != true || again["username"] == user || again["password"] == pass {
		t.Fatalf("credentials were reused across sessions: %v", again["ok"])
	}
}

func TestStartLocalDefaultsToAuthentication(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	t.Cleanup(e.Stop)
	reply := startLocalJSON(t, &e, map[string]any{"link": link, "listen": "127.0.0.1:0"})
	if reply["ok"] != true || reply["auth"] != true || reply["password"] == "" {
		t.Fatalf("a start without an explicit auth field must authenticate: %v", reply["auth"])
	}
	if m := socksGreeting(t, dialProxy(t, reply["listen"].(string)), 0); m != 0xFF {
		t.Fatalf("SOCKS5 without credentials: method %#x, want 0xFF", m)
	}
}

func TestStartLocalExplicitNoAuthForSystemProxy(t *testing.T) {
	link := syntheticLink(t)
	var e engine.Engine
	t.Cleanup(e.Stop)
	reply := startLocalJSON(t, &e, map[string]any{"link": link, "listen": "127.0.0.1:0", "auth": false})
	if reply["ok"] != true || reply["auth"] != false || reply["username"] != "" || reply["password"] != "" {
		t.Fatalf("system-proxy start reply = %v", reply)
	}
	if m := socksGreeting(t, dialProxy(t, reply["listen"].(string)), 0); m != 0 {
		t.Fatalf("SOCKS5 no-auth in system-proxy mode: method %#x, want 0", m)
	}
}

func TestStartLocalRejectsBadConfig(t *testing.T) {
	var e engine.Engine
	if r := startLocal(&e, "{"); r["ok"] != false {
		t.Fatalf("malformed config accepted: %v", r)
	}
	if r := startLocalJSON(t, &e, map[string]any{"link": "singlink://bad", "auth": true}); r["ok"] != false {
		t.Fatalf("bad link accepted: %v", r)
	}
	if r := startLocalJSON(t, &e, map[string]any{"link": syntheticLink(t), "listen": "0.0.0.0:0"}); r["ok"] != false {
		t.Fatalf("non-loopback listen accepted: %v", r)
	}
}
