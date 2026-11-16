// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
// Runtime-only synthetic profiles for parser/storage tests. No network is used.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"github.com/SingLinkLabs/singlink-protocol/singlink"
	"os"
	"time"
)

func main() {
	key, err := singlink.GenerateServerKey()
	check(err)
	issuer, err := singlink.GenerateEd25519()
	check(err)
	device, err := singlink.GenerateEd25519()
	check(err)
	token, err := singlink.IssueToken(issuer, &singlink.Token{DevicePub: device.Public().(ed25519.PublicKey), Caps: singlink.CapTCP,
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)})
	check(err)
	base := singlink.Profile{Name: "Synthetic parser fixture", Server: "127.0.0.1:9", ServerKey: key.Public(), Token: token, Device: device}
	links := map[string]string{}
	links["defaultTLS"] = base.Link()
	base.Transport = "tcp"
	links["rawTCP"] = base.Link()
	base.Transport = "tls"
	base.Insecure = true
	links["insecureTLS"] = base.Link()
	base.Pin = make([]byte, 32)
	_, err = rand.Read(base.Pin)
	check(err)
	links["pinnedTLS"] = base.Link()
	check(json.NewEncoder(os.Stdout).Encode(links))
}
func check(err error) {
	if err != nil {
		os.Stderr.WriteString("Synthetic fixture generation failed\n")
		os.Exit(1)
	}
}
