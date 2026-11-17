// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"github.com/SingLinkLabs/singlink-protocol/engine"
	"github.com/SingLinkLabs/singlink-protocol/singlink"

	"github.com/SingLinkLabs/singlink-vpn-app/core/tunnel"
)

// testHookTunAcquired, when set by a test, runs inside the engine callback
// right after the tunnel has taken dev and before the engine publishes the
// session, i.e. in the window where a concurrent Stop makes the start stale.
var testHookTunAcquired func()

// startTun runs a device-wide session over dev on e and always consumes
// dev, whatever the result:
//
//   - nil: the running tunnel owns dev and closes it when the session stops
//     (SingLinkTunStop / SingLinkStop, TUN failure, or a matching-client
//     invalidation).
//   - error before the tunnel took dev (engine busy, bad link, node
//     unreachable or handshake failure, cancelled before acquisition,
//     tunnel setup failure): dev is closed here, once.
//   - error after the tunnel took dev (Stop or invalidation landed before
//     the engine published the session): the engine already ran the
//     session cleanup, which closed dev once; it is not closed again here.
//
// A panic in between still releases dev here (closing the tunnel that took
// it, if any) unless the cleanup was handed to the engine.
func startTun(e *engine.Engine, dev tunnel.Device, link string, cfg tunnel.Config) error {
	// handedOff becomes true only when the cleanup that closes dev is
	// returned to the engine, which then runs it on every later failure
	// (engine.finish) or stop. Until then this function owns dev, or the
	// tunnel t that took it.
	var t *tunnel.Tunnel
	handedOff := false
	defer func() {
		if handedOff {
			return
		}
		if t != nil {
			t.Close() // closes dev once
		} else {
			dev.Close()
		}
	}()
	return e.StartWith(link, "tun", func(c *singlink.Client) (func(), error) {
		cfg.Client = c
		started, err := tunnel.Start(dev, cfg)
		if err != nil {
			return nil, err // tunnel.Start does not close dev; the defer does
		}
		t = started
		cleanup := func() {
			tunMu.Lock()
			if curTun == started {
				curTun = nil
			}
			tunMu.Unlock()
			started.Close()
		}
		tunMu.Lock()
		curTun = started
		tunMu.Unlock()
		// If the OS tears this TUN down, stop the engine as well (but never
		// a newer session started after this one). This also clears the
		// engine's pending start if a panic unwinds through here.
		go func() {
			<-started.Done()
			e.StopClient(c)
		}()
		if testHookTunAcquired != nil {
			testHookTunAcquired()
		}
		handedOff = true
		return cleanup, nil
	})
}
