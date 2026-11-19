// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

//go:build linux || darwin

package main

// App F-02 (VPN Labs): the descriptor contract of the exported
// SingLinkTunStart / SingLinkTunStop, and the local-proxy authentication of
// SingLinkStart (App F-01), exercised through the real C ABI. The test
// builds this package as a c-shared library, compiles
// testdata/cabi_harness.c against the generated header and runs it in its
// own process with real pipe descriptors (see the harness for the checks).
//
// It needs cgo and a C compiler. Without them it is skipped, unless
// SINGLINK_REQUIRE_CABI_TEST=1 (CI), which turns a skip into a failure.

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func cabiUnavailable(t *testing.T, why string) {
	t.Helper()
	if os.Getenv("SINGLINK_REQUIRE_CABI_TEST") == "1" {
		t.Fatalf("C ABI test required but unavailable: %s", why)
	}
	t.Skipf("C ABI test skipped: %s", why)
}

func TestCABITunDescriptorOwnershipAndProxyAuth(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the c-shared library")
	}
	goBin, err := exec.LookPath("go")
	if err != nil {
		cabiUnavailable(t, "no go command on PATH")
	}
	cc := os.Getenv("CC")
	if cc == "" {
		cc = "cc"
	}
	if _, err := exec.LookPath(strings.Fields(cc)[0]); err != nil {
		cabiUnavailable(t, "no C compiler ("+cc+")")
	}
	if out, err := exec.Command(goBin, "env", "CGO_ENABLED").Output(); err != nil || strings.TrimSpace(string(out)) != "1" {
		cabiUnavailable(t, "cgo is disabled")
	}

	dir := t.TempDir()
	lib := filepath.Join(dir, "libsinglink.so")
	if runtime.GOOS == "darwin" {
		lib = filepath.Join(dir, "libsinglink.dylib")
	}
	build := exec.Command(goBin, "build", "-trimpath", "-buildmode=c-shared", "-o", lib, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=1")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building the c-shared library: %v\n%s", err, out)
	}
	header := strings.TrimSuffix(lib, filepath.Ext(lib)) + ".h"
	if err := os.Rename(header, filepath.Join(dir, "libsinglink.h")); err != nil {
		t.Fatal(err)
	}
	harness := filepath.Join(dir, "cabi_harness")
	args := append(strings.Fields(cc)[1:], "-std=c11", "-D_GNU_SOURCE", "-D_DARWIN_C_SOURCE", "-Wall", "-Werror",
		"-I", dir, "-o", harness, filepath.Join("testdata", "cabi_harness.c"), "-lpthread")
	if runtime.GOOS == "linux" {
		args = append(args, "-ldl")
	}
	if out, err := exec.Command(strings.Fields(cc)[0], args...).CombinedOutput(); err != nil {
		t.Fatalf("compiling the C harness: %v\n%s", err, out)
	}

	run := exec.Command(harness)
	run.Env = append(os.Environ(),
		"SL_LIB="+lib,
		"SL_LINK_OK="+syntheticLink(t),
		"SL_LINK_CLOSED="+closedLink(t),
		"SL_LINK_SILENT="+silentLink(t),
	)
	var out bytes.Buffer
	run.Stdout, run.Stderr = &out, &out
	err = run.Run()
	t.Logf("C harness output:\n%s", out.String())
	if err != nil {
		t.Fatalf("C ABI harness failed: %v", err)
	}
	if !strings.Contains(out.String(), "PASS: 0 failure(s)") || strings.Contains(out.String(), "not ok") {
		t.Fatal("C ABI harness reported failures")
	}
	if n := strings.Count("\n"+out.String(), "\nok - "); n < 13 {
		t.Fatalf("C ABI harness ran %d checks, want at least 13", n)
	}
}
