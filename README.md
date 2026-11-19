# SingLinkVPN — first-generation client (`singlink_vpn`)

## Key facts

- **What:** the SingLinkVPN first-generation client for Windows, macOS,
  Android and iOS: one Flutter (Dart) codebase with a Go core built on the
  [SingLink Beta Protocol](https://github.com/SingLinkLabs/singlink-protocol),
  first generation. Device-wide VPN on mobile, system proxy on
  desktop.
- **License:** Apache-2.0, with a required NOTICE attribution.
  "SingLink", "SingLinkVPN", 星連/星连 and the logo are trademarks of
  SingLinkVPN (see [NOTICE](NOTICE)).
- **Attribution:** required. Any use or redistribution must keep "Software
  provided by the original author SingLinkVPN" (see [Attribution](#attribution)).
- **Version:** first generation (prototype status; per-platform status in the
  table below). **Released:** 2026-11-12, in phase 2 of the SingLinkVPN
  open-source plan.
- **Lineage:** the SingLink protocol has evolved from SingLinkVPN's early
  versions and SingLink Beta to today's SingLink 2.0; this first-generation client carries
  forward SingLinkVPN's design principles of account-based permissions,
  device binding and security by design.
- **Stays closed for now:** the latest versions (the current official
  SingLinkVPN apps and the SingLink 2.0 core), for security reasons.
- **Related:** open-source hub
  [singlink-vpn-open-source](https://github.com/SingLinkLabs/singlink-vpn-open-source) ·
  [singlinkvpn.com/en/tech/open-source](https://singlinkvpn.com/en/tech/open-source/)

## Attribution

Any use or redistribution must keep the attribution: **"Software provided by
the original author SingLinkVPN."** This app and the SingLink Beta Protocol
were originally developed and provided by SingLinkVPN, https://singlinkvpn.com.
Redistributions and derivative works (including app-store releases) must
reproduce the attribution in [NOTICE](NOTICE) in their own NOTICE file and
wherever they show third-party notices or an About screen, and must not
remove the source-file copyright headers, the main-screen footer
("Provided by the original author SingLinkVPN / Powered by the SingLink Beta
Protocol"), the attribution constants in `lib/legal.dart` or the attribution
returned by the native core (Apache License 2.0, section 4).

繁體中文：任何使用或轉發，都必須保留署名：軟件由原作者 SingLinkVPN 提供。

## Background

The SingLink protocol has evolved from SingLinkVPN's early versions and SingLink Beta to
today's SingLink 2.0. The open-source "SingLink Beta Protocol, first generation" and
"SingLinkVPN first-generation client" carry forward SingLinkVPN's
long-standing design principles (account-based permissions, device binding
and security by design) and were released after a security audit. The
official apps and protocol have since moved to a new-generation architecture
that is not yet fully public for security reasons; we release only code that
poses no security risk, and the open-source plan will continue.

## Overview

**The first-generation SingLinkVPN client.** A
consumer-VPN-style Flutter app for Windows, macOS, Android and iOS, built on
the open [SingLink Beta Protocol](https://github.com/SingLinkLabs/singlink-protocol)
core.

| Platform | Mode | Status |
|---|---|---|
| macOS 13+ (Apple silicon) | system proxy (SOCKS5 via `networksetup`) | built and tested end to end |
| Windows 10/11 x64 | system proxy (HTTP proxy via WinINet registry) | core DLL built; app builds in CI on Windows |
| Android 7+ (arm64, armv7, x86_64) | device-wide VPN (`VpnService` + core TUN) | built and tested end to end on the emulator |
| iOS 15+ | device-wide VPN (Network Extension packet tunnel) | builds; running on a device needs an Apple Developer team |

- `core/`: the app's Go module (SingLink Beta Protocol + the gVisor user-space
  TCP/IP stack for TUN mode) built into `libsinglink` for every platform
  (`make -C core macos|android|ios|windows`).
- Bundle id `com.singlinklabs.singlinkvpn`, display name "SingLinkVPN", UI in
  English only.
- Plugin-free (only `ffi` and the pure-Dart `crypto` package), so it builds
  without CocoaPods or Swift Package Manager.
- License: Apache-2.0 (see `LICENSE`, `NOTICE`). Redistributions and derivative
  works must keep the source-file copyright headers and the NOTICE attribution
  ("Software provided by the original author SingLinkVPN", "Based on the
  SingLinkVPN prototype and the SingLink Beta Protocol by SingLinkVPN"); the
  app shows it in the main-screen footer and under Settings > About > Licenses.
  "星連", "SingLink" and
  "SingLinkVPN" are trademarks of SingLinkVPN: forks must use their own name
  and icon.

Screenshots: `test/goldens/` (desktop), `docs/screenshots/android/`,
`docs/screenshots/ios/`.

## What the user sees

- **Main screen** (single ~420×760 window, light/dark): big power button
  (Connect → Connecting... pulsing → Disconnect glowing emerald/teal), status
  "Not protected / Connecting / Protected", connection timer `HH:MM:SS`,
  "Your IP: ..." from
  `SingLinkExitIP`, location card (flag + city derived from the server name,
  `lib/models/location.dart`), live download/upload speed and session usage
  (from `SingLinkStatus`, every second). No proxy jargon on this screen.
- **Choose location** sheet: "Quick connect (auto)" (last-used server, else the first) and
  every server. Latency is measured with `SingLinkProbe` for the connected
  server only; others show "—" (the core can only probe through the active
  tunnel). Picking another location while connected switches over.
- **Settings** (gear): Add server (paste / clipboard), server list with delete,
  "System-wide proxy" (default on), Advanced (local port, default 1080;
  "Local proxy": with the system proxy off, the host, port and this
  session's username and password with copy buttons; with it on, a note that
  the port has no password and is open to every local app and user account;
  Connection log), About (core version, protocol). Android adds "Always-on
  VPN" (opens the system VPN settings); iOS adds "Block traffic outside the
  VPN" (off by default).
- Errors from the core are shown as short English messages that say what to do
  (`lib/core/error_messages.dart`), with the original text under "Show details".
- Location names are always English. Chinese node names in server links are
  still recognised (match keys in `lib/models/location.dart`); names it does
  not know, and the raw node name under the city, are shown as the server sent
  them.

Screenshots (rendered by `test/golden_test.dart` with fake data):
`test/goldens/main_connected_{light,dark}.png`,
`main_disconnected_{light,dark}.png`, `location_sheet_light.png`,
`settings_light.png`.

## Desktop system-wide mode (macOS, Windows) — what it is and is not

On desktop this is **system proxy mode**, not a packet-level VPN (Android and
iOS use a real device-wide VPN, see their sections):

- When "System-wide proxy" is on, after the core starts, the app sets the macOS
  SOCKS proxy of every enabled network service to `127.0.0.1:<port>` with
  `/usr/sbin/networksetup`, after saving each service's previous SOCKS settings.
  On disconnect, on quit (⌘Q or closing the window) and when the core stops by
  itself, the previous settings are written back.
- The saved settings are also journaled to
  `~/Library/Application Support/com.singlinklabs.singlinkvpn/system-proxy-restore.json`;
  if the app is killed while connected, the next launch restores from it.
- **Local proxy login (VPN Labs App F-01):** with "System-wide proxy" off the
  core requires a username and password on the local port (SOCKS5 RFC 1929
  and HTTP `Proxy-Authorization`). The core generates both with `crypto/rand`
  for every connection; the app keeps them in memory only (never logged or
  saved) and shows them in Settings for manual proxy setup. OS proxy settings
  cannot carry credentials, so with "System-wide proxy" on the port has no
  password and Settings says that any app or user account on this computer
  can use it while connected. Changing the switch while connected reconnects.
  With the login, TCP works with any SOCKS5 or HTTP client; UDP needs a
  SOCKS5 client that declares its UDP port in UDP ASSOCIATE.
- If `networksetup` fails, the app stays connected and shows
  "Couldn't set the system proxy. Set SOCKS 127.0.0.1:1080 manually in System
  Settings."
- Limits: only TCP traffic of apps that honour the system SOCKS proxy goes
  through the tunnel (browsers and most apps do; many CLI tools, games, and
  anything using raw UDP do not). A service that already had an
  *authenticated* SOCKS proxy is left untouched (its password cannot be read
  back to restore it). If a service had no SOCKS server before, only its
  on/off state is restored (networksetup cannot write an empty server).
- Logic is in `lib/core/system_proxy.dart`; every command goes through a
  `ProcessRunner`, and the tests use a fake runner — the test suite never
  changes the machine's network settings.

**Next step on desktop:** a packet-level VPN that also covers apps ignoring the
proxy settings — a Network Extension on macOS (the iOS packet tunnel and the
core's TUN bridge can be reused; needs an Apple Developer team) and Wintun on
Windows.

## Build

```bash
flutter pub get --offline
flutter analyze
flutter test
flutter build macos --release
open build/macos/Build/Products/Release/SingLinkVPN.app
```

Build the app core first with `make -C core macos`; it is bundled automatically
(see below). Checkout the public protocol sibling at the exact commit in
`core/protocol-revision.txt` (the same commit `core/go.mod` requires as a
pseudo-version) before building. `python3 scripts/protocol_provenance.py verify`
rejects a different or dirty protocol tree, or a go.mod/record mismatch. All platform Make targets and packaging
steps validate the pin; generated native artifacts carry source/hash stamps and
stale artifacts must be rebuilt. Without it the app still starts and shows the banner
"Core library libsinglink.dylib not found" with the expected path.

Release builds keep `ARCHS = arm64` (Flutter 3.35's `lipo -verify_arch` with
two archs fails with the current lipo). Deployment target is macOS 13.0 (the
Go core needs it).

## How the core library is found (`lib/core/singlink_bindings.dart`)

Tried in order; the first file that opens and exports all `SingLink*` symbols
wins:

1. `SingLinkVPN.app/Contents/Frameworks/libsinglink.dylib` (bundled)
2. `$SINGLINK_LIB` — full path to a dylib (handy with `flutter run`)
3. Dev fallbacks: `<cwd>/../singlink-protocol/build/libsinglink.dylib`, and
   `singlink-protocol/build/libsinglink.dylib` under every ancestor of the
   executable (finds the sibling protocol repo from `build/`).

C ABI used (every call returns malloc'd JSON, freed with `SingLinkFree`):
`SingLinkVersion`, `SingLinkParseLink`, `SingLinkStart`, `SingLinkStop`,
`SingLinkStatus`, `SingLinkProbe`, `SingLinkExitIP`.

## Bundling (`scripts/bundle_core_macos.sh`)

- **Automatic:** the Runner target has a build phase *Bundle libsinglink core*
  that runs `scripts/bundle_core_macos.sh --xcode` during every
  `flutter build macos` / `flutter run -d macos`. It copies
  `core/build/macos/libsinglink.dylib` into `Contents/Frameworks/`
  and signs it with the build's identity. It then re-seals the .app with the
  entitlements Xcode generated, because on incremental builds where only Dart
  code changed Xcode skips its own final CodeSign while Flutter has already
  replaced `App.framework` (otherwise `codesign --verify` reports "nested code
  is modified or invalid"). If the dylib is missing it only warns.
- **Manual / post-build:** `scripts/bundle_core_macos.sh [debug|profile|release]`
  copies the dylib into an already built app and re-signs it (ad-hoc by
  default, `CODESIGN_IDENTITY=...` to override).

Options: `SINGLINK_CORE_LIB=/path/libsinglink.dylib` overrides the source,
`SINGLINK_REQUIRE_CORE=1` makes a missing core a build error.

A stale dylib stays in an incremental build's `Frameworks/` after the source is
deleted; `flutter clean` (or delete the .app) to drop it.

## iOS: device-wide VPN (Network Extension)

- `ios/PacketTunnel/` — packet tunnel app extension
  (`com.singlinklabs.singlinkvpn.tunnel`). `startTunnel` reads only an opaque
  `providerConfiguration["secretRef"]`, resolves its protected Keychain record,
  verifies configuration-bound warning consent, and applies 172.19.0.1/30 + fd66:6c69:6e6b::1/126,
  default routes v4/v6, DNS 172.19.0.2, MTU 1500, finds the utun descriptor
  (`getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME)`) and calls
  `SingLinkTunStart(fd, {"appleHeader":true,...})`. Go memory limit 30 MiB via
  `SingLinkSetMemoryLimit` (`core/ffi/memlimit.go`; `GOMEMLIMIT` cannot be set
  with setenv because a c-archive's Go runtime reads its environment at load).
  `handleAppMessage`: `status` / `probe` / `exitip` → core JSON. A watchdog
  cancels the tunnel when the core stops; the reason goes to the app group.
- `ios/Runner/SingLinkVpnPlugin.swift` — MethodChannel
  `com.singlinklabs.singlinkvpn/vpn` over `NETunnelProviderManager`
  (start/stop/status/probe/exitIP, `onStatus` pushes); `lib/platform/ios.dart`
  `IosTunnelCore` (`usesLocalProxy == false`). Version/link parsing use FFI:
  the Runner links `Singlink.xcframework` statically and keeps the exports
  with `-Wl,-u,_SingLink…` and `STRIP_STYLE = non-global`.
- Entitlements (`Runner/Runner.entitlements`, `PacketTunnel/PacketTunnel.entitlements`):
  `networkextension = [packet-tunnel-provider]`, app group
  `group.com.singlinklabs.singlinkvpn` and the shared Keychain access group
  `$(AppIdentifierPrefix)com.singlinklabs.singlinkvpn.credentials`. iOS 15+.
- The Xcode project changes are generated by `scripts/setup_ios_tunnel.rb`
  (xcodeproj gem, idempotent):
  `GEM_HOME=… ruby scripts/setup_ios_tunnel.rb`.
- The simulator cannot run a packet tunnel: connecting there shows
  "This device can't create a VPN (the simulator isn't supported)...". A
  denied VPN prompt shows "SingLinkVPN needs permission to add a VPN..."

```bash
make -C core ios        # core/build/apple/Singlink.xcframework
flutter build ios --config-only --release --no-codesign
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphoneos -derivedDataPath build/xcode CODE_SIGNING_ALLOWED=NO build
```

Running on an iPhone needs an Apple Developer team with the Network
Extensions capability: App IDs `com.singlinklabs.singlinkvpn` and
`com.singlinklabs.singlinkvpn.tunnel`, both with *Network Extensions* and
*App Groups* (`group.com.singlinklabs.singlinkvpn`), matching shared Keychain
access groups, and development /
distribution provisioning profiles for both; set `DEVELOPMENT_TEAM` on both
targets (automatic signing creates the profiles).

## Entitlements / sandbox

This is a direct-distribution app (not Mac App Store), so **App Sandbox is off
in all configurations** (`macos/Runner/DebugProfile.entitlements`,
`Release.entitlements`): the sandbox would block running `networksetup`, and
dev builds load the core from outside the bundle. Both keep
`com.apple.security.network.client` and `com.apple.security.network.server`
(the core opens a local SOCKS5 listener and outbound connections). The
planned way to sandbox the app is a small privileged helper that owns the
`networksetup` calls.

Release and Profile builds run with the **hardened runtime**
(`ENABLE_HARDENED_RUNTIME = YES`; the release build needs no runtime
exception entitlement). A build is distributable only when
`python3 scripts/verify_macos_distribution.py SingLinkVPN.app` passes:
Developer ID Application signature with a secure timestamp on the app and the
bundled core, hardened runtime, only the reviewed entitlements, a stapled
notarization ticket and Gatekeeper acceptance. CI builds are ad-hoc signed,
the gate rejects them, and their artifact is named UNSIGNED.

## Data

`~/Library/Application Support/com.singlinklabs.singlinkvpn/state.json`
(Windows: `%LOCALAPPDATA%\SingLinkLabs\SingLinkVPN\state.json`; display
names and other display metadata, opaque credential references and match
keys, selection, port and switches). Since settings version 4 (VPN Labs
App F-07) it no longer holds a profile's server address, SNI or token
subject: they are derived from the protected link when needed, and a keyed
per-installation hash (HMAC-SHA-256) lets a re-import replace a profile whose
protected record is unreadable. Older files are rewritten only after each
profile's protected record has been read back. The folder is excluded from
iCloud/Finder and Time Machine backups (iOS/macOS), Android backup is
disabled, and on Windows earlier versions' roaming `%APPDATA%` files are moved
to local AppData at start-up. Complete links and warning acknowledgements are stored in the native
secret store: Android Keystore AES-GCM ciphertext in no-backup storage, iOS shared
Keychain (`AfterFirstUnlockThisDeviceOnly`), macOS login Keychain, or Windows
current-user DPAPI. macOS does not claim iOS accessibility or hardware semantics.
These controls do not protect against an attacker already controlling the signed
app or the user's unlocked session.

Legacy state is migrated with protected write/readback before an atomic metadata
commit. If the native store is locked, missing or unavailable, migration fails
closed and keeps the original legacy data for retry; it never connects using a
plaintext fallback. After successful commit, only app-owned transaction references
and deleted-profile records are cleaned; interrupted cleanup retries at startup.
Existing external backups, filesystem snapshots and deleted SSD blocks cannot be
erased by this migration. Android OS backup is explicitly disabled.

Advanced profile warnings must be reviewed before import; acknowledgement is
stored with the exact protected link and rechecked before connecting. Re-import
is required if warnings change. iOS Settings-start follows the same policy.

A `state.json` from the old
`sl3_client` is not migrated automatically (different folder); its `listen`
field is understood if copied over.

## Tests

```bash
flutter test                                   # everything below
flutter test --update-goldens test/golden_test.dart   # after UI changes
```

- `models_test.dart` — core JSON replies, persistence, library search order
- `location_and_errors_test.dart` — flag/city mapping, error mapping, timer/speed formatting
- `system_proxy_test.dart` — networksetup command sequence, save/restore, partial failure, crash journal (fake runner)
- `controller_test.dart` — connect/disconnect with system proxy, warnings, quick connect, switching
- `widget_test.dart` — main screen (no jargon), location sheet, settings, missing-core banner
- `golden_test.dart` — screenshots in `test/goldens/` (loads Roboto/Material
  Icons from the Flutter cache and the emoji font from macOS)
- `ffi_mock_test.dart` — compiles `test/fixtures/mock_libsinglink.c` with `cc`
  and drives every binding (incl. `SingLinkExitIP`) through the real isolate + FFI path
- `real_core_test.dart` — end-to-end against the real core and a demo node;
  skipped unless both variables are set:

```bash
../singlink-protocol/build/singlink demo -link-only -node 127.0.0.1:18443 > /tmp/demo.log &
SINGLINK_LIB=../singlink-protocol/build/libsinglink.dylib \
SINGLINK_TEST_LINK="$(sed -n 3p /tmp/demo.log)" \
flutter test test/real_core_test.dart
kill %1
```

## Layout

```
lib/main.dart                        app, theme, English (en-US) locale, quit hook
lib/core/singlink_bindings.dart      raw FFI bindings, library search
lib/core/singlink_service.dart       VpnCore interface + Isolate.run implementation
lib/core/client_controller.dart      state: connect/disconnect, poll, exit IP, latency
lib/core/system_proxy.dart           networksetup system proxy (ProcessRunner, journal)
lib/core/error_messages.dart         core error -> plain English message
lib/core/app_store.dart              JSON persistence
lib/models/                          Profile, core replies, location mapping
lib/ui/home_page.dart                main screen
lib/ui/settings_page.dart            settings, add server, log
lib/ui/widgets/                      power button, location card/sheet, speed, notices
```

## Windows (`platform/windows`)

System-proxy mode, like macOS: the core (`singlink.dll`, loaded with
`dart:ffi`) opens the local SOCKS5 port and the app points the per-user
WinINet proxy at it.

- **Core:** `make -C core windows` → `core/build/windows/singlink.dll`
  (cgo `c-shared`, x86-64). The Makefile's default
  `WIN_CC = zig cc -target x86_64-windows-gnu` works from macOS once `zig` is
  on `PATH`, e.g. the official tarball unpacked to
  `$HOME/toolchains/zig` (tested with zig 0.17.1):
  `PATH="$HOME/toolchains/zig:$PATH" make -C core windows`.
  On Windows use MinGW-w64: `make -C core windows WIN_CC=gcc`.
- **App:** `flutter build windows --release` (Windows host with Visual Studio
  only) → `build\windows\x64\runner\Release\SingLinkVPN.exe`. The CMake
  install step copies `core/build/windows/singlink.dll` next to the .exe if it
  exists (`SINGLINK_REQUIRE_CORE=1` makes a missing core an error). Window:
  "SingLinkVPN", 420×760, minimum 380×620.
- **System proxy** (`lib/platform/windows.dart`), in
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`:
  `ProxyEnable=1`, `ProxyServer=127.0.0.1:<port>` (HTTP proxy),
  `ProxyOverride=<local>;localhost;127.*;10.*;172.16.*;192.168.*`, and
  `AutoConfigURL` (PAC) removed while connected. The previous values —
  including which did not exist — are journaled to
  `%LOCALAPPDATA%\SingLinkLabs\SingLinkVPN\system-proxy-restore.json` first and
  written back exactly (absent ones deleted) on disconnect, quit, or the next
  launch after a crash. Running programs are notified with
  `InternetSetOptionW` (SETTINGS_CHANGED, REFRESH). All registry access goes
  through `reg.exe` and a `ProcessRunner`; `test/windows_system_proxy_test.dart`
  uses a fake, `test/windows_registry_smoke_test.dart` runs against the real
  registry on Windows with `SINGLINK_WINDOWS_REGISTRY_TEST=1` (CI does).
- **Why HTTP:** WinINet (and Chromium reading a scheme-less `socks=` entry)
  only speaks SOCKS v4. The core's local port speaks both SOCKS5 and HTTP
  proxy (CONNECT for HTTPS), so Windows is pointed at it as an HTTP proxy,
  which every WinINet client supports. `WindowsProxyMode.socks5`
  (`socks=socks5://…`, Chromium only) remains available.

## CI (`.github/workflows/build.yml`)

Jobs: tests (go vet/test of `core` including the C ABI harness, pinned
`govulncheck`, `flutter analyze`, `flutter test`; goldens informational),
windows (pinned MinGW `singlink.dll`, real-registry test, `flutter build
windows`, zipped Release folder artifact), android (C ABI harness on Linux,
`make -C core android` with the runner's NDK, `flutter build apk`, Kotlin unit
tests), macos (`make -C core macos`, `flutter build macos`, hardened-runtime
check, distribution gate must reject the ad-hoc build), ios (`make -C core
ios`, `flutter build ios --no-codesign`). Runner images are pinned by name
(`macos-26`, `ubuntu-26.04`, `windows-2022`), every action is pinned to a
commit SHA, checkouts do not persist the token, Go comes from `core/go.mod`,
and the Gradle wrapper verifies the distribution's SHA-256. The app is checked out to
`singlink-vpn-app/` and `SingLinkLabs/singlink-protocol` to
`singlink-protocol/` so `core/go.mod`'s `../../singlink-protocol` resolves;
every job checks out the immutable approved protocol revision using the default
read-only repository token. Pull-request builds do not receive release signing
inputs; Android CI artifacts are explicitly named demo debug builds.

## Android (device-wide VPN)

- `lib/platform/android.dart` (`AndroidVpnCore`) asks Kotlin over the channel
  `com.singlinklabs.singlinkvpn/vpn` for VPN consent (`VpnService.prepare`),
  then establishes the TUN in `SingLinkVpnService` (172.19.0.1/30 +
  fdfe:dcba:9876::1/126, default routes, DNS 172.19.0.2, the app itself
  excluded so the core's own sockets bypass the VPN), and hands the detached
  fd to the core with `SingLinkTunStart`. The core works on its own duplicate
  of the fd and always consumes it; the bridge closes its original exactly
  once after the call returns, whatever the result.
- **Always-on VPN:** the service declares
  `android.net.VpnService.SUPPORTS_ALWAYS_ON`. When Android starts it without
  the app (always-on, also after boot) it goes foreground, starts the Dart
  side without an Activity if needed, and connects the saved profile (last
  used, else the selected or first one) from the protected store, with the
  same security-warning check as the power button. If that cannot happen
  (no server, locked storage, warnings to review) the service stops within
  90 seconds. Turn on "Block connections without VPN" in Android's VPN
  settings (Settings > Always-on VPN in the app opens them) to block traffic
  whenever no session is up; the app itself has no other kill switch.
- Foreground service with the notification "SingLinkVPN is connected" /
  "Device traffic goes through SingLinkVPN while connected"; a revoke
  by the system or another VPN stops the core and the app shows "The
  connection dropped. Connect again."
- Build: `make -C core android` (NDK; Gradle rebuilds missing or source-stale
  artifacts), then `flutter build apk --debug` for a demo. Libraries are
  16 KB-page aligned for Android 15+ devices. Release tasks fail closed unless
  an external private keystore and all four `SINGLINK_RELEASE_*` inputs are
  supplied. There is no debug-key release fallback. See [protected release
  signing](docs/security-remediation.md) before a distribution build.
- Known Flutter quirk: rebuilding in a path with a space can fail on the
  depfile; delete `build/app/intermediates/flutter/*/flutter_build.d` (or run
  `flutter clean`) first.
