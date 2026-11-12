# 星連VPN — macOS client (`singlink_vpn`)

Consumer-VPN-style Flutter app over the SingLink Protocol core `libsinglink`
(C ABI, loaded via `dart:ffi`). The protocol lives in its own repository,
`../singlink-protocol`; this repo only contains the app.

- Bundle: `SingLinkVPN.app`, id `com.singlinklabs.singlinkvpn`, display name 「星連VPN」
- UI language: Traditional Chinese (Hong Kong)
- macOS is the supported target; `android/` and `ios/` are scaffolding only.
- Plugin-free (only `ffi` + `flutter_localizations`), so it builds without
  CocoaPods or Swift Package Manager.

## What the user sees

- **Main screen** (single ~420×760 window, light/dark): big power button
  (未連線 → 連線中… pulsing → 已連線 glowing emerald/teal), status 「未受保護 /
  正在連線 / 已受保護」, connection timer `HH:MM:SS`, 「你的 IP：…」 from
  `SingLinkExitIP`, location card (flag + city derived from the server name,
  `lib/models/location.dart`), live download/upload speed and session usage
  (from `SingLinkStatus`, every second). No proxy jargon on this screen.
- **選擇地區** sheet: 「快速連線（自動）」 (last-used server, else the first) and
  every server. Latency is measured with `SingLinkProbe` for the connected
  server only; others show 「—」 (the core can only probe through the active
  tunnel). Picking another location while connected switches over.
- **設定** (gear): 新增伺服器 (paste / clipboard), server list with delete,
  「系統全局代理」 (default on), 進階 (local port, default 1080; read-only
  「本機代理 127.0.0.1:1080」; 連線紀錄), 關於 (core version, protocol).
- Errors from the core are shown as short Chinese messages
  (`lib/core/error_messages.dart`), with the original text under 「顯示詳細資訊」.

Screenshots (rendered by `test/golden_test.dart` with fake data):
`test/goldens/main_connected_{light,dark}.png`,
`main_disconnected_{light,dark}.png`, `location_sheet_light.png`,
`settings_light.png`.

## System-wide mode — what it is and is not

This is **system proxy mode**, not a packet-level VPN:

- When 「系統全局代理」 is on, after the core starts, the app sets the macOS
  SOCKS proxy of every enabled network service to `127.0.0.1:<port>` with
  `/usr/sbin/networksetup`, after saving each service's previous SOCKS settings.
  On disconnect, on quit (⌘Q or closing the window) and when the core stops by
  itself, the previous settings are written back.
- The saved settings are also journaled to
  `~/Library/Application Support/com.singlinklabs.singlinkvpn/system-proxy-restore.json`;
  if the app is killed while connected, the next launch restores from it.
- If `networksetup` fails, the app stays connected and shows
  「無法設定系統代理，請在系統設定手動設定 SOCKS 127.0.0.1:1080」.
- Limits: only TCP traffic of apps that honour the system SOCKS proxy goes
  through the tunnel (browsers and most apps do; many CLI tools, games, and
  anything using raw UDP do not). A service that already had an
  *authenticated* SOCKS proxy is left untouched (its password cannot be read
  back to restore it). If a service had no SOCKS server before, only its
  on/off state is restored (networksetup cannot write an empty server).
- Logic is in `lib/core/system_proxy.dart`; every command goes through a
  `ProcessRunner`, and the tests use a fake runner — the test suite never
  changes the machine's network settings.

**Next step (not implemented): a real VPN.** Capturing all traffic (TCP + UDP,
including apps that ignore proxy settings) needs a packet tunnel:
a Network Extension `NEPacketTunnelProvider` on macOS/iOS (requires an Apple
Developer team and the Network Extension entitlement, plus a tun2socks-style
layer in the core) or `VpnService` on Android.

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
「找不到核心元件 libsinglink.dylib」 with the expected path.

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
  Icons from the Flutter cache and CJK/emoji fonts from macOS)
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
lib/main.dart                        app, theme, zh-Hant-HK locale, quit hook
lib/core/singlink_bindings.dart      raw FFI bindings, library search
lib/core/singlink_service.dart       VpnCore interface + Isolate.run implementation
lib/core/client_controller.dart      state: connect/disconnect, poll, exit IP, latency
lib/core/system_proxy.dart           networksetup system proxy (ProcessRunner, journal)
lib/core/error_messages.dart         core error -> Chinese message
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
  「星連VPN」, 420×760, minimum 380×620.
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
