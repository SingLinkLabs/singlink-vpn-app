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

### Protocol pin and handshake diagnostic

The core is pinned to the remediated protocol revision
`7822e49cc84ee421fa9d0dbddd8fff6257019be9` (`core/protocol-revision.txt`, the
`core/go.mod` pseudo-version with its UTC commit time). That revision adds the
node-side F-01 fix (a copy of an admitted first flight never gets a status-only
answer); the client and the wire format are unchanged. Its client reports a refused
handshake as a possible protocol draft or server-key mismatch (keeping the older
"node rejected the credentials" prefix); the app shows "Couldn't connect: this
server uses a different protocol version or key. Update the app or re-import the
server link, and check your device time." Covered by
`test/location_and_errors_test.dart`.

### Test-suite failures from the re-audit (section 8)

The Windows `ffi_mock_test` teardown now retries and tolerates the mock DLL that
Windows keeps loaded, and CI runs the full `flutter test` on the Windows runner
(MinGW `gcc` builds the mock; the synthetic parser test uses the freshly built
DLL). Goldens are compared only on macOS, where the references were rendered.
The copyright-header test compares paths with `/` separators and tolerates CRLF
checkouts and a UTF-8 BOM on every host, so generated cgo headers under
`core/build` are excluded on Windows too (the check itself is unchanged).
`test/synthetic_node_e2e_test.dart` runs connect, probe, SOCKS relay, status and
stop through the real core against a throwaway loopback node (`core/testnode`,
fresh keys, no external server) wherever the core library is built, including CI
on macOS; `real_core_test.dart` against a live node stays optional.

## VPN Labs follow-up (2026-11-19)

Reported by VPN Labs (app audit VPNL-2026-0014, findings App F-01 to F-08;
follow-up of 2026-11-19 against commit c39ce58, line references from the
audited commit d955d0e). Each item names the cause, the change, the tests and
what still needs real devices or the owner's accounts. Passing tests do not
prove the absence of other defects.

### App F-01 (Low): desktop local proxy without authentication

Cause: `SingLinkService.start` sent only `{"link","listen"}`, and
`SingLinkStart` mapped the missing `auth` field to `engine.Options{Auth:false}`.
Any local process, including another user account's, could relay through the
user's server and token while the app was connected, also when the system
proxy was switched off.

Fix: the app always states `auth` explicitly and requests it whenever the OS
system proxy is not used (switch off, or a platform without it). `SingLinkStart`
in this app's core now defaults a missing `auth` to true and refuses to report
success if authentication was requested but no credentials exist. The pinned
engine generates the username and password with `crypto/rand` for each start
and enforces them for SOCKS5 (RFC 1929) and HTTP (`Proxy-Authorization`). The
app keeps them in memory only (`ProxyCredentials.toString` is redacted; never
logged, never in settings) and shows host, port, username and a masked password
with copy buttons in Settings > Advanced. In system-proxy mode (OS proxy
settings cannot carry credentials) Settings states that the port has no
password and any app or user account on the computer can use it while
connected. Changing the switch while connected reconnects so the port's
authentication always matches it; the switch is fixed while connecting, and a
change that still lands during a start is detected before the OS proxy is set
and reconnects. A start that returns no credentials fails closed and stops the
core.

Tests: `core/ffi/auth_test.go` (real engine, synthetic loopback node): auth on
when requested and by default, SOCKS5 without credentials gets method 0xFF,
wrong username or password refused, HTTP CONNECT without or with wrong
credentials gets 407, the right ones accepted, new credentials per start,
explicit `auth:false` open. `core/ffi/cabi_test.go` repeats the refusal through
the real C ABI. `test/ffi_mock_test.dart` checks the exact JSON payloads through
Dart FFI; `test/synthetic_node_e2e_test.dart` relays with the login through the
real core and checks an anonymous client is refused;
`test/vpnlabs_followup_test.dart` covers the controller (fresh login per
session, nothing in logs or settings, reconnect on toggle, fail closed) and the
Settings states.

Remaining: in system-proxy mode the port stays open to local processes by
design (documented in the UI), also when applying the OS proxy failed (the UI
then says so and turning the switch off restarts with a password). A copied
password stays on the clipboard until replaced; the app cannot mark it as
concealed. In the pinned protocol's SOCKS5 server, UDP ASSOCIATE requires the
login, but the relay then accepts the first datagram from any port of the
client's IP address, which on loopback is shared by all local processes; this
is a protocol-side item for the protocol repository.

### App F-02: no test of the exported SingLinkTunStart descriptor contract

Cause: the Go tests called `tunnel.DupFDDevice` and `startTun` directly; nothing
called the exported `SingLinkTunStart`/`SingLinkTunStop`, and `VpnBridge` had no
automated test.

Fix and tests: `core/ffi/cabi_test.go` builds the core as a c-shared library,
compiles `core/ffi/testdata/cabi_harness.c` against the generated
`libsinglink.h` and runs it in its own process with real pipe descriptors. For
malformed config, invalid link, unreachable node, negative and closed
descriptor numbers, success then `SingLinkTunStop`, success then `SingLinkStop`,
TUN failure (EOF) handled by the watcher, a busy engine and a Stop during the
handshake, it checks over the whole descriptor table that the caller's
descriptor stays open and unchanged, that exactly one close-on-exec duplicate
exists while the core holds it and none afterwards, and that sentinel
descriptors are untouched. CI runs it on macOS (`go test -race`) and Linux (the
Android job) with `SINGLINK_REQUIRE_CABI_TEST=1`, so it cannot silently skip.
`VpnBridge` now closes descriptors through a replaceable hook;
`android/app/src/test/.../VpnBridgeTest.kt` (JVM, `testDebugUnitTest` in CI)
checks that the original is closed exactly once after success and failure,
never by `stop` or revoke, once by the bridge for a stale or superseded
establish, never for unknown numbers, and not retried after a failing close.

Remaining: the Android path with a real `VpnService` descriptor and the Apple
utun path still need device runs.

### App F-03: Go 1.27.3 standard-library vulnerability (GO-2026-6859)

Cause: `core/go.mod` declared `go 1.27.3`; govulncheck v1.10.0 reported
GO-2026-6859 (net/http) reachable from the loopback test helper
`core/testnode`. CI did not run govulncheck.

Fix: `go 1.27.4`. Every CI job installs Go from `core/go.mod` and the tests job
fails if the toolchain differs; a pinned `govulncheck@v1.10.0` step (installed
through the Go checksum database) fails the build on any reachable
vulnerability in the core or the pinned protocol.

Tests: govulncheck v1.10.0 with go1.27.3 reports GO-2026-6859 (exit 3); with
go1.27.4: "No vulnerabilities found". `scripts/test_security_build_gates.py`
rejects a go directive below 1.27.4 and an unpinned govulncheck.

### App F-04: protection wording broader than the tunnel guarantees

Cause: the mobile connected screen said "Protected · Traffic encrypted by
SingLinkVPN" and the Android notification "All traffic is going through
SingLinkVPN", without a kill switch, Android always-on support or iOS
full-capture options.

Fix: the mobile connected state now reads "Connected · Device traffic goes
through SingLinkVPN while connected"; the notification reads "SingLinkVPN is
connected · Device traffic goes through SingLinkVPN while connected"
(supersedes the mobile wording of A-H03). Android supports always-on VPN:
the service declares `SUPPORTS_ALWAYS_ON`, handles Android's own start (no
CONNECT intent) by going foreground, starting the Dart side without an Activity
if needed and connecting the saved profile from the protected store with the
same warning check as the power button; it stops itself if that is impossible
(no server, locked storage, warnings to review) or takes over 90 seconds, and
it no longer stops a running session when Android repeats the start. Settings
offers "Always-on VPN", which opens Android's VPN settings, and explains that
"Block connections without VPN" there is the kill switch. On iOS, Settings
offers "Block traffic outside the VPN" (off by default): `includeAllNetworks`
with `excludeLocalNetworks`, so local devices stay reachable. Apple exempts the
packet tunnel provider's own connections, so the core can still reach its
node. `enforceRoutes` stays off (redundant with `includeAllNetworks`; with our
default routes alone it would also capture the local network), and on-demand
rules are not used (a user Disconnect would have to turn them off first). The
option is off by default because the effect on Apple services and on a tunnel
that fails to start (no traffic until the VPN is turned off) needs device
testing first.

Tests: `test/controller_test.dart` and `test/vpnlabs_followup_test.dart`
(wording; an OS start connects the saved profile, is handled once, releases the
service without a profile or with changed warnings), `VpnBridgeTest.kt` (start
classification, always-on request taken once, notification wording),
`test/ios_tunnel_core_test.dart` (the option reaches the tunnel),
`ios/RunnerTests` (`applyRoutingPolicy`; CI now runs RunnerTests on a fresh
Simulator).

Emulator (Android 16, API 36, debug build): with always-on and "Block
connections without VPN" set and no saved server, Android started the service
after boot, it went foreground (VPN exemption), the Dart side started without
an Activity and the service stopped itself about 15 seconds later, with no
crash and no service-start timeout. (The Flutter engine is started off the
service's start call; creating it inside `onStartCommand` tripped the start
timeout on the slow emulator.)

Remaining: the always-on connect of a saved server and leak tests on real
devices (always-on with and without lockdown, reboot, network changes, iOS
with the option on and off) could not be run here.

### App F-05: macOS release without hardened runtime or App Sandbox

Cause: the Runner target set no `ENABLE_HARDENED_RUNTIME`; CI produces ad-hoc
builds only.

Fix: `ENABLE_HARDENED_RUNTIME = YES` for Release and Profile. A build with a
development team (required for Developer ID) uses `Release.entitlements`:
network client/server, sandbox off, no runtime exception, library validation
on. Library validation cannot accept ad-hoc signed frameworks (verified: an
ad-hoc hardened build fails to load FlutterMacOS.framework), so a team-less
ad-hoc build (local and CI, never distributable) selects
`Release-AdHoc.entitlements`, which adds only
`com.apple.security.cs.disable-library-validation`; the selection is the build
setting `Runner/Release$(SINGLINK_ADHOC_ENTITLEMENTS_$(DEVELOPMENT_TEAM))`,
and the distribution gate rejects that entitlement. The local ad-hoc release
build shows `flags=0x10002(adhoc,runtime)`, starts and loads the bundled core. `scripts/bundle_core_macos.sh` keeps the
runtime flag when it re-signs and uses a secure timestamp for non-ad-hoc
identities. `scripts/verify_macos_distribution.py` is the release gate: it
refuses to call a build distributable unless the app and the core are signed
with one team's Developer ID Application certificate with a secure timestamp,
the hardened runtime is on, only the reviewed entitlements are present, the
notarization ticket is stapled and Gatekeeper reports a notarized Developer ID
build. The CI macOS job checks the runtime flag and requires the gate to reject
its ad-hoc build, which is uploaded as `SingLinkVPN-macos-UNSIGNED-adhoc-ci`.

App Sandbox stays off: the system-proxy mode runs `/usr/sbin/networksetup`,
which a sandboxed app cannot. The planned path is a small privileged helper
that owns those calls so the app itself can be sandboxed; it is not part of
this change.

Remaining: Developer ID signing and notarization need the owner's Apple
Developer account in the protected release process; no credentials are in the
repository or CI.

### App F-06: packet tunnel logged core error text as public

Cause: `PacketTunnelProvider.swift` logged start failures and core-stop
reasons with `%{public}@`.

Fix: both log a fixed public category (`errorCategory`, for example
`node-unreachable`, `handshake`, `credentials-unavailable`) and the text as
`%{private}@`. A search of the Swift, Kotlin, Dart, Go and C++ sources found no
other system logging of hosts, links, tokens, SNI or subjects (the in-app
connection log stays in memory). A gate test rejects `%{public}@` in any
`os_log` call without `errorCategory(`, and `NSLog`/`print`/`Logger` in the
Apple sources.

Remaining: the extension still hands the core's error text to the app through
the App Group defaults (`lastError`, replaced at the next start) so the app can
show why the tunnel stopped; that is app-private storage, not a log.

### App F-07: server address, SNI and token subject in the ordinary settings file

Cause: `state.json` stored each profile's `server`, `sni` and `subject` in plain
JSON next to the protected-credential reference.

Fix: settings version 4 keeps display metadata (name, plan, expiry, limits),
the opaque `secretRef` and an opaque `matchKey` (HMAC-SHA-256 of server and
subject with a random per-installation key), never the server, SNI, subject or
link; a write that would contain them is refused. The details are known at
import and derived again from the protected link for display after a restart.
Re-importing a server whose protected record is unreadable still replaces the
broken entry, matched by `matchKey`. Migration of an older file reads back
every profile's protected record first; a locked or unavailable store aborts it
and leaves the file unchanged for a retry; a missing or corrupt record (a
profile that was already unusable) does not block it. The settings folder is
excluded from backups on iOS (`isExcludedFromBackup`) and macOS (Time Machine);
Android backup and device transfer stay disabled; on Windows settings and the
proxy journal moved from roaming `%APPDATA%` to `%LOCALAPPDATA%`, with the
earlier files moved at start-up (copy, rename into place, then delete).

Tests: `test/vpnlabs_followup_test.dart` (no server/SNI/subject/link in the
stored JSON after import, restart derivation, v3 migration with record
confirmation, locked store keeps the file, missing record then re-import in
place, per-install match keys, Windows move), `test/models_test.dart`,
`ios/RunnerTests` (backup exclusion).

Once local settings exist, roaming copies of the app's files (for example
written again by an older version) are removed at every start, and staging
files of an interrupted move are cleaned up.

Remaining: copies already in earlier backups, snapshots or roaming profiles
cannot be removed by the app. The match key's per-installation key is stored
in the same file, so the key hides server and subject only as far as the token
subject is not guessable.

### App F-08: build supply-chain hygiene

Cause: floating runner images (`macos-latest`, `ubuntu-latest`), an unpinned
Chocolatey MinGW fallback, no Gradle distribution checksum, checkouts that
persisted the job token.

Fix: `macos-26`, `ubuntu-26.04` and `windows-2022`; the Windows job always
installs the pinned Chocolatey `mingw` 14.2.0 package (its install script
verifies the download checksum), checks the version, logs the compiler's
SHA-256 and fails if another `gcc` is first on `PATH`;
`distributionSha256Sum` for `gradle-8.12-all.zip`, identical to
services.gradle.org's published `.sha256` and to a local download; every
checkout sets `persist-credentials: false`; actions stay pinned to commit SHAs.
`scripts/test_security_build_gates.py` enforces all of these.

Review follow-up: `flutter pub get --enforce-lockfile` everywhere, the Android
NDK pinned to the Makefile's version (installed with `sdkmanager` if the image
lacks it) instead of the image's latest, and govulncheck also scans the iOS,
Android and Windows builds of the core.

Remaining: the Gradle wrapper JAR comes from the pinned Flutter SDK; there is
no Gradle dependency-verification metadata; the JDK patch release and the
image's default Xcode are not pinned; runner image contents still change
within a pinned image name.

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
