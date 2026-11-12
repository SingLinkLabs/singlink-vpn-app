package main

// #include <stdlib.h>
import "C"

import "runtime/debug"

// SingLinkSetMemoryLimit sets the Go runtime's soft memory limit in bytes
// (runtime/debug.SetMemoryLimit) and returns {"ok":true,"previous":<bytes>}.
// A negative value only reports the current limit.
//
// The iOS Network Extension calls it before starting the tunnel: the
// extension is killed by the system above ~50 MB, and GOMEMLIMIT cannot be
// set with setenv there, because a c-archive's Go runtime reads its
// environment when the binary is loaded, before any app code runs.
//
//export SingLinkSetMemoryLimit
func SingLinkSetMemoryLimit(bytes C.longlong) (res *C.char) {
	defer guard(&res)
	return out(map[string]any{"ok": true, "previous": debug.SetMemoryLimit(int64(bytes))})
}
