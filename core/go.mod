module github.com/SingLinkLabs/singlink-vpn-app/core

go 1.27.3

require (
	github.com/SingLinkLabs/singlink-protocol v0.0.0-20261117132120-b9246900205c
	golang.org/x/sys v0.48.0
	gvisor.dev/gvisor v0.0.0-20261111202248-15a1a0dd7620
)

require (
	github.com/google/btree v1.1.2 // indirect
	golang.org/x/exp v0.0.0-20250711185948-6ae5c78190dc // indirect
	golang.org/x/time v0.15.0 // indirect
)

// The sibling checkout must be the exact commit above (also recorded in
// protocol-revision.txt); scripts/protocol_provenance.py verify enforces it.
replace github.com/SingLinkLabs/singlink-protocol => ../../singlink-protocol
