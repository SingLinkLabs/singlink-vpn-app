# SingLinkVPN — first-generation client (`singlink_vpn`)

**The first-generation SingLinkVPN client.** A
consumer-VPN-style Flutter app for Windows, macOS, Android and iOS, built on
the open [SingLink Protocol](https://github.com/SingLinkLabs/singlink-protocol)
core.

SingLinkLabs released its first-generation protocol and client code after a
security audit. The latest versions (the SingLink 2.0 core and the current
SingLinkVPN apps) are not yet fully public for security reasons, so only code
that poses no security risk was released. The open-source plan continues, and
more will be released in later phases after security review.

| Platform | Mode | Status |
|---|---|---|
| macOS 13+ (Apple silicon) | system proxy (SOCKS5 via `networksetup`) | built and tested end to end |
| Windows 10/11 x64 | system proxy (HTTP proxy via WinINet registry) | core DLL built; app builds in CI on Windows |
| Android 7+ (arm64, armv7, x86_64) | device-wide VPN (`VpnService` + core TUN) | built and tested end to end on the emulator |
| iOS 15+ | device-wide VPN (Network Extension packet tunnel) | builds; running on a device needs an Apple Developer team |

- `core/`: the app's Go module (SingLink Protocol + the gVisor user-space
  TCP/IP stack for TUN mode) built into `libsinglink` for every platform
  (`make -C core macos|android|ios|windows`).
- Bundle id `com.singlinklabs.singlinkvpn`, display name "SingLinkVPN", UI in
  English only.
- Plugin-free (only `ffi`), so it builds without
  CocoaPods or Swift Package Manager.
- License: Apache-2.0 (see `LICENSE`, `NOTICE`). Redistributions and derivative
  works must keep the source-file copyright headers and the NOTICE attribution
  ("Based on the SingLinkVPN prototype and the SingLink Protocol by
  SingLinkLabs"); the app shows it under Settings > About > Licenses.
  "星連", "SingLink" and
  "SingLinkVPN" are trademarks of SingLinkLabs: forks must use their own name
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
  read-only "Local proxy 127.0.0.1:1080"; Connection log), About (core
  version, protocol).
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

Build the core first (`make -C ../singlink-protocol lib` →
`../singlink-protocol/build/libsinglink.dylib`); it is bundled automatically
(see below). Without it the app still starts and shows the banner
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
  `../singlink-protocol/build/libsinglink.dylib` into `Contents/Frameworks/`
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
  (`com.singlinklabs.singlinkvpn.tunnel`). `startTunnel` reads the link from
  `providerConfiguration["link"]`, applies 172.19.0.1/30 + fd66:6c69:6e6b::1/126,
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
  `group.com.singlinklabs.singlinkvpn`. iOS 15+.
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
*App Groups* (`group.com.singlinklabs.singlinkvpn`), and development /
distribution provisioning profiles for both; set `DEVELOPMENT_TEAM` on both
targets (automatic signing creates the profiles).

## Entitlements / sandbox

This is a direct-distribution app (not Mac App Store), so **App Sandbox is off
in all configurations** (`macos/Runner/DebugProfile.entitlements`,
`Release.entitlements`): the sandbox would block running `networksetup`, and
dev builds load the core from outside the bundle. Both keep
`com.apple.security.network.client` and `com.apple.security.network.server`
(the core opens a local SOCKS5 listener and outbound connections). For public
distribution, sign with a Developer ID certificate and notarize.

## Data

`~/Library/Application Support/com.singlinklabs.singlinkvpn/state.json`
(servers, selection, port, system-proxy switch). A `state.json` from the old
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
  `%APPDATA%\SingLinkLabs\SingLinkVPN\system-proxy-restore.json` first and
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

Jobs: tests (go vet/test of `core`, `flutter analyze`, `flutter test`;
goldens informational), windows (MinGW `singlink.dll`, real-registry test,
`flutter build windows`, zipped Release folder artifact), android
(`make -C core android` with the runner's NDK, `flutter build apk`), macos
(`make -C core macos`, `flutter build macos`), ios (`make -C core ios`,
`flutter build ios --no-codesign`). The app is checked out to
`singlink-vpn-app/` and `SingLinkLabs/singlink-protocol` to
`singlink-protocol/` so `core/go.mod`'s `../../singlink-protocol` resolves;
the `PROTOCOL_REPO_TOKEN` secret is needed only while that repo is private.

## Android (device-wide VPN)

- `lib/platform/android.dart` (`AndroidVpnCore`) asks Kotlin over the channel
  `com.singlinklabs.singlinkvpn/vpn` for VPN consent (`VpnService.prepare`),
  then establishes the TUN in `SingLinkVpnService` (172.19.0.1/30 +
  fdfe:dcba:9876::1/126, default routes, DNS 172.19.0.2, the app itself
  excluded so the core's own sockets bypass the VPN), and hands the detached
  fd to the core with `SingLinkTunStart`.
- Foreground service with the notification "SingLinkVPN is connected"; a revoke
  by the system or another VPN stops the core and the app shows "The
  connection dropped. Connect again."
- Build: `make -C core android` (NDK; the Gradle build runs it if the `.so`
  files are missing), then `flutter build apk --release`. Libraries are
  16 KB-page aligned for Android 15+ devices. Release builds are signed with
  the debug key until a release keystore is configured.
- Known Flutter quirk: rebuilding in a path with a space can fail on the
  depfile; delete `build/app/intermediates/flutter/*/flutter_build.d` (or run
  `flutter clean`) first.
