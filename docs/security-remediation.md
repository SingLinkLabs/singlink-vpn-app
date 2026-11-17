# Security controls for the first-generation open-source client

This document describes implementation boundaries, not an audit-pass or commercial
application claim. Independent verification and device testing are separate steps.

## Protected credentials and migration

Ordinary app JSON contains display metadata and opaque references. The complete
connection link and exact warning acknowledgement live together in a native
protected record. Production does not select the in-memory store used by tests.

- Android: a non-exportable Android Keystore AES-GCM key protects per-reference
  ciphertext, with fresh IVs and reference-bound authentication. Ciphertext is
  stored under `noBackupFilesDir`; ordinary backup is disabled explicitly. Hardware
  backing, StrongBox and device-lock behavior require device-specific verification.
- iOS: app and extension use a matching build-expanded Keychain access group and
  `AfterFirstUnlockThisDeviceOnly`, without iCloud synchronization. The OS tunnel
  configuration contains only a reference. A real signed device is still needed
  to verify extension sharing, provisioning, reboot and locked-device behavior.
- macOS: the native login Keychain is used without claiming iOS accessibility
  semantics or hardware protection. Distribution signing/notarization is separate.
- Windows: DPAPI uses the current user, with encrypted files in app-local storage,
  reference-bound entropy and immutable-reference writes. Full Windows runtime
  tests are separate from compilation. Other code running as that user can still
  be inside the threat boundary.

The legacy JSON migration writes and verifies a protected record before committing
metadata. A reference-only transaction journal supports crash recovery. Locked,
missing, corrupt or unavailable stores block connection rather than using a
plaintext fallback. Failed migration keeps the existing legacy data for retry.
After metadata commit, removed app-owned records are deleted; failed cleanup stays
queued and is retried. A leftover `state.json.tmp` from an interrupted older write
(which could hold a plaintext link) is removed at start-up. If a profile's protected
record is missing (restored without its OS key, reset Keychain or DPAPI master key),
connecting fails closed with a re-import message; re-importing the same server
replaces the broken entry, and a broken entry never blocks importing others. If
settings cannot be loaded at all (locked store during migration, corrupt metadata),
Settings offers Retry (after unlocking) and a confirmed reset that removes the
app-owned files so servers can be added again; neither path writes plaintext. This does not erase user-created backups, snapshots, swap,
crash dumps or historical disk blocks. Do not place real profiles in tests/logs.

## Lifecycle and warnings

Connection generations invalidate late completions. New starts wait for obsolete
owned cleanup, and shutdown waits for start/proxy cleanup before returning.
Normal quit waits for that barrier; a cleanup failure cancels quit and allows a
visible retry. A forced process termination cannot make the same guarantee.
Platform callbacks reject obsolete consent, service and tunnel starts. An obsolete
Android foreground-service start still calls `startForeground` before stopping;
TUN descriptor ownership is described under A-04 below. A quit whose cleanup hangs is cancelled after 20 seconds with a
visible error instead of freezing or exiting. The Go TUN
watcher stops only its owning client, using `Engine.StopClient`.

Warnings from the real parser reach an explicit confirmation dialog. Cancellation
or absent acknowledgement prevents import. Acknowledgement is bound to the exact
protected link and is rechecked on connection, including extension starts from
iOS Settings. Unknown warning forms fail closed for review.

## 2026-11-17 re-audit remediation

Each item below names the change, the tests that cover it and what still needs
real devices. Passing tests do not prove the absence of other defects.

### A-04: Android TUN descriptor closed twice after a failed start (Low)

Cause: Kotlin detached the TUN descriptor and Dart marked it adopted only when
`SingLinkTunStart` returned ok. A Stop (or a TUN/watcher failure) landing after the
Go callback had wrapped the descriptor but before the engine published the session
made the engine run the session cleanup (closing it) and return `context.Canceled`;
Kotlin then closed the same number again, which could hit an unrelated descriptor
reusing it. A `tunnel.Start` failure after wrapping could also leave the Go
`os.File` finalizer to close it later.

Fix: ownership no longer depends on the result. `SingLinkTunStart` never takes the
caller's descriptor: it makes a close-on-exec duplicate (`F_DUPFD_CLOEXEC`) and
always consumes exactly that duplicate. `startTun` closes it itself on every
failure before the tunnel took it (bad config, busy engine, bad link, unreachable
node or handshake failure, Stop before acquisition, tunnel setup failure, panic);
once the tunnel took it, the engine's stale-start cleanup, Stop or the TUN watcher
closes it once. Dart always asks Kotlin to close the original exactly once after
the core call has returned (success, failure, cancellation, thrown call), or
without calling the core when the start is abandoned first; Kotlin closes only
descriptors it handed out, at most once, and `stop` never closes descriptors, so
nothing closes the original while the core call is in progress. The `adopted`
message is gone. On Apple the core now closes only its duplicate instead of the
Network Extension's own utun descriptor. A failed `tunStart` call also triggers a
`tunStop`, `onRevoke` work moved to the main thread, and a status poll during a
reconnect no longer stops the new session's service.

Tests: `core/ffi/tunstart_test.go` drives the real pinned engine and tunnel with a
loopback synthetic node: Stop after acquisition (exactly one close), pre-acquisition
failures (bad link, unreachable node, busy engine, Stop during handshake: one close
by the core, tunnel never acquired), stop after success, TUN read failure through
the watcher, a panic after acquisition, and real pipe descriptors proving that the
caller's descriptor stays open for its single close and the duplicate never leaks.
`test/android_fd_ownership_test.dart` checks the Dart ordering against a modelled
native side for every result.

`TestTunStartFDTableCancelAfterAcquisition` snapshots the whole process descriptor
table (`/proc/self/fd`, `/dev/fd` on Apple) across a cancel-after-acquisition:
exactly one extra reference while the tunnel holds the duplicate, the caller's
descriptor unchanged afterwards, no previously open descriptor closed, none left
after the caller's single close.

Emulator: the `core/ffi` and `core/tunnel` test binaries, cross-compiled with the
NDK for android/arm64, pass on an Android 16 (API 36) arm64 emulator, including the
`/proc/self/fd` table test and ten repeated runs of the cancellation tests; the
debug APK installs and starts there. Still unverified: the full app path (VPN
consent, a real `VpnService` TUN descriptor, Dart and Kotlin together) during a
cancel-during-start, controlled descriptor-number reuse on a physical device, and
the Kotlin bridge has no automated test of its own; iOS/macOS extension behaviour
with the duplicate needs a signed device run.

### A-H01: CI supply chain

Every action is pinned to a full commit SHA with its version tag as a comment.
The workflow token has no permissions by default; each job grants `contents: read`,
and only the three artifact jobs add `id-token`/`attestations: write` for
`actions/attest-build-provenance`, which publishes signed SLSA provenance for each
uploaded artifact on pushes (verify with `gh attestation verify`). The `.source.json`
fingerprints stay. Gate tests in `scripts/test_security_build_gates.py` reject an
unpinned action, broader permissions or an artifact without attestation.
Attestation proves which workflow run built a file, not that it is release signed.

### A-H02: development library fallback

Release builds (`dart.vm.product`) search only the core packaged with the app;
`SINGLINK_LIB`, working-directory and ancestor-folder candidates exist only in
debug/profile builds and tests. Covered by `test/models_test.dart`. A packaged
release run on each desktop OS is still to be done.

### A-H03: connected-state wording

Mobile (device-wide VPN): "Protected · Traffic encrypted by SingLinkVPN". Desktop
with the system proxy applied: "System proxy on — apps using it are protected";
without it (off or failed): "Connected · Apps set to use proxy 127.0.0.1:1080 are
protected". Warning consent is unchanged. Covered by `test/controller_test.dart`
and the macOS goldens.

### A-H04: DNS query flood

At most 64 upstream DNS queries are in flight per tunnel across all DNS flows; the
excess is answered at once with a header-only SERVFAIL (same ID, RD echoed) and
freed slots are reused. Covered by `TestDNSOutstandingQueriesAreCapped` and
`TestServfailEchoesIDAndRD` (also run on the Android emulator). A sustained
on-device flood was not run.

### A-H05: profile identifiers

New profiles get 128 random bits from the platform CSPRNG (32 hex digits) instead
of a timestamp; stored IDs, including legacy ones, are kept. Covered by
`test/models_test.dart`.

### A-H06: iOS stop acknowledgement

`stopIfActive` reports success only after iOS shows the tunnel disconnected or
invalid; a timeout, a still-live status or a manager-load error is returned as a
failure, an already disconnecting tunnel is waited for, and a new start never
proceeds over a tunnel that did not stop. The controller keeps showing a session
whose stop failed while the core still reports it running ("The VPN did not stop.
Try again."). Covered by `ios/RunnerTests` (status decisions; passed on a fresh
iOS 27.2 Simulator), `test/ios_tunnel_core_test.dart` and `test/controller_test.dart`.
Extension termination needs a signed device; the Simulator cannot run the tunnel.

### Test-suite failures from the re-audit (section 8)

The Windows `ffi_mock_test` teardown now retries and tolerates the mock DLL that
Windows keeps loaded, and CI runs the full `flutter test` on the Windows runner
(MinGW `gcc` builds the mock; the synthetic parser test uses the freshly built
DLL). Goldens are compared only on macOS, where the references were rendered.
`test/synthetic_node_e2e_test.dart` runs connect, probe, SOCKS relay, status and
stop through the real core against a throwaway loopback node (`core/testnode`,
fresh keys, no external server) wherever the core library is built, including CI
on macOS; `real_core_test.dart` against a live node stays optional.

## Protected release signing

Debug/demo builds use only a generated debug identity and must be labelled as such.
Android release tasks require externally supplied values for:

- `SINGLINK_RELEASE_STORE_FILE`
- `SINGLINK_RELEASE_STORE_PASSWORD`
- `SINGLINK_RELEASE_KEY_ALIAS`
- `SINGLINK_RELEASE_KEY_PASSWORD`

Use a private external keystore and a protected local/CI environment. Never commit
keystores, passwords, signing certificates, personal team identifiers or production
secrets. The release gate rejects absent inputs and the default `debug.keystore`;
Gradle still validates the actual certificate/password when signing. Presence of
inputs alone does not prove a distribution artifact is properly signed. Verify
its certificate fingerprint through the trusted release process. Public pull
requests have no release signing inputs. CI uploads only artifacts named as such:
`SingLinkVPN-android-DEMO-debug-apk`, `SingLinkVPN-windows-x64-UNSIGNED-ci` and
`SingLinkVPN-macos-UNSIGNED-adhoc-ci` (ad-hoc signed, not notarized); the iOS job
builds without code signing and uploads nothing.

## Pinned core source

`core/protocol-revision.txt` is the single immutable reviewed protocol revision.
`core/go.mod` requires the protocol at the matching pseudo-version
(`v0.0.0-<commit time UTC>-<first 12 hex>`); the gate rejects any disagreement
between the two. Every supported Make/build/package entry point and CI job
verifies the sibling checkout and rejects a dirty or mismatched tree; every CI
protocol checkout uses that full SHA, so a moving upstream `main` cannot change
what a given app revision builds. Native `.source.json` stamps bind
the protocol commit, app core source hash and artifact hash. Android rebuilds stale
artifacts; Apple/Windows packaging rejects them. Rebuild artifacts after changing
the pin or app-core source. A stamp is reproducibility bookkeeping, not a signed
release attestation and not a replacement for independent review.

## Verification commands

Use fresh synthetic profiles and isolated test environments only:

```
python3 scripts/test_security_build_gates.py
make -C core test macos
flutter analyze
flutter test
```

The real-parser test generates fresh issuer/node/device keys at runtime and uses
loopback profile addresses without connecting. Native Android instrumentation must
run on a fresh test emulator. iOS `RunnerTests` must run only on a newly created
isolated Simulator; a missing entitlement is an explicit skip, not a successful
shared-Keychain result. Simulator support does not imply a working VPN extension.

## Platform references

- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Android backup controls](https://developer.android.com/identity/data/autobackup)
- [Android signing](https://developer.android.com/studio/publish/app-signing)
- [Apple shared Keychain access](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Apple Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [Windows current-user DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
