// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// Command testnode runs a throwaway SingLink node on loopback for the app's
// end-to-end test (test/synthetic_node_e2e_test.dart). Every key, token and
// replay file is generated fresh at start and discarded at exit; it listens
// only on 127.0.0.1 and is never a deployment example.
//
// It prints one JSON line {"link":"singlink://..."} once the node is ready
// and exits when its standard input closes.
package main

import (
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/SingLinkLabs/singlink-protocol/singlink"
)

func main() {
	dir, err := os.MkdirTemp("", "singlink-testnode")
	check(err)
	defer os.RemoveAll(dir)
	key, err := singlink.GenerateServerKey()
	check(err)
	issuer, err := singlink.GenerateEd25519()
	check(err)
	device, err := singlink.GenerateEd25519()
	check(err)
	replay, err := singlink.InitializeReplayFile(filepath.Join(dir, "state", "replay.db"), 0)
	check(err)
	srv, err := singlink.NewServer(singlink.ServerConfig{
		ReplayStore: replay,
		Key:         key,
		Issuers:     singlink.NewIssuers(issuer.Public().(ed25519.PublicKey)),
		// The test's targets are on loopback.
		AllowPrivate: true,
		DialTimeout:  3 * time.Second,
	})
	check(err)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	check(err)
	go srv.Serve(ln)
	time.Sleep(1100 * time.Millisecond) // first flights must be stamped after node start
	token, err := singlink.IssueToken(issuer, &singlink.Token{
		DevicePub: device.Public().(ed25519.PublicKey),
		Caps:      singlink.CapTCP | singlink.CapUDP,
		NotBefore: time.Now().Add(-time.Minute),
		NotAfter:  time.Now().Add(time.Hour),
	})
	check(err)
	link := (&singlink.Profile{Name: "Synthetic e2e node", Server: ln.Addr().String(), Transport: "tcp",
		ServerKey: key.Public(), Token: token, Device: device}).Link()
	check(json.NewEncoder(os.Stdout).Encode(map[string]string{"link": link}))
	io.Copy(io.Discard, os.Stdin)
	ln.Close()
}

func check(err error) {
	if err != nil {
		os.Stderr.WriteString("synthetic test node failed: " + err.Error() + "\n")
		os.Exit(1)
	}
}
