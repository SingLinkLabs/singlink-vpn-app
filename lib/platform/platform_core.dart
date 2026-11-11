// Chooses the protocol core and system integration for the running
// platform. Each platform's details live in its own file in this folder:
//
//   macOS    SingLinkService (FFI, local SOCKS5) + networksetup system proxy
//   Windows  SingLinkService (FFI, singlink.dll) + registry system proxy
//   Android  VpnService TUN + FFI core            (android.dart)
//   iOS      Network Extension packet tunnel      (ios.dart)

import 'dart:io';

import '../core/singlink_service.dart';
import '../core/system_proxy.dart';
import 'android.dart';
import 'ios.dart';
import 'windows.dart';

/// Runs first in main(): platform channels that must answer early (for
/// example Android's files directory).
Future<void> initPlatform() async {
  if (Platform.isAndroid) await initAndroid();
}

VpnCore createPlatformCore() {
  if (Platform.isAndroid) return createAndroidCore();
  if (Platform.isIOS) return createIosCore();
  return SingLinkService.locate();
}

/// Null where the core is a device-wide VPN (mobile) or unsupported.
SystemProxy? createSystemProxy(String appSupportDir) {
  if (Platform.isMacOS) {
    return SystemProxyManager(
      runner: const IoProcessRunner(),
      journal: ProxyJournal(File('$appSupportDir/system-proxy-restore.json')),
    );
  }
  if (Platform.isWindows) return createWindowsSystemProxy(appSupportDir);
  return null;
}
