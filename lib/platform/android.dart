// Android: device-wide VPN through VpnService.
//
// Kotlin (android/app/src/main/kotlin/.../SingLinkVpnService.kt) asks for the
// user's consent, runs the foreground VpnService and establishes the TUN
// interface; it hands the detached TUN file descriptor to Dart. Dart then
// passes the descriptor to the Go core with SingLinkTunStart, which relays
// every IP packet through the SingLink node. The core and the app share one
// process, so Status / Probe / ExitIP work over FFI exactly as on desktop.
//
// Channel `com.singlinklabs.singlinkvpn/vpn`
//   Dart → Kotlin  filesDir                 → String
//                  prepare                  → bool (false: user declined)
//                  establish {mtu}          → int (detached TUN fd)
//                  stop {closeFd}           → null
//   Kotlin → Dart  revoked                  (onRevoke: another VPN took
//                                            over or the user turned it off)

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../core/app_store.dart';
import '../core/singlink_bindings.dart';
import '../core/singlink_service.dart';
import '../models/core_status.dart';
import '../models/profile.dart';

const vpnChannel = MethodChannel('com.singlinklabs.singlinkvpn/vpn');

/// Error returned by [AndroidVpnCore.start] when the user declines the
/// system VPN dialog (shown as 「需要允許建立 VPN 連線」).
const vpnPermissionDenied = 'vpn permission denied';

VpnCore createAndroidCore() {
  final location = locateSingLinkLib();
  return AndroidVpnCore(
    location: location,
    calls: FfiTunCalls(location.path ?? libFileName),
  );
}

/// Called once at start-up, before the app state is loaded: the app's files
/// live in Context.getFilesDir() (HOME is not meaningful on Android).
Future<void> initAndroid({MethodChannel channel = vpnChannel}) async {
  try {
    final dir = await channel.invokeMethod<String>('filesDir');
    if (dir != null && dir.isNotEmpty) appSupportDirOverride = dir;
  } on PlatformException {
    // Fall back to the default directory rather than fail to launch.
  } on MissingPluginException {
    // Same.
  }
}

/// The core calls [AndroidVpnCore] makes, each returning the core's raw JSON
/// reply. [FfiTunCalls] is the real one; tests substitute a fake.
abstract class TunCalls {
  Future<String> version();
  Future<String> parseLink(String link);
  Future<String> tunStart(int fd, String configJson);
  Future<String> tunStop();
  Future<String> status();
  Future<String> probe(String url, int timeoutMs);
  Future<String> exitIP(int timeoutMs);
}

/// Runs every call in a short-lived background isolate (several block), like
/// [SingLinkService]. [path] is `libsinglink.so`, resolved by the loader from
/// the APK's native library directory.
class FfiTunCalls implements TunCalls {
  const FfiTunCalls(this.path);

  final String path;

  @override
  Future<String> version() => _run(path, (b) => b.version());
  @override
  Future<String> parseLink(String link) => _run(path, (b) => b.parseLink(link));
  @override
  Future<String> tunStart(int fd, String configJson) =>
      _run(path, (b) => b.tunStart(fd, configJson));
  @override
  Future<String> tunStop() => _run(path, (b) => b.tunStop());
  @override
  Future<String> status() => _run(path, (b) => b.status());
  @override
  Future<String> probe(String url, int timeoutMs) =>
      _run(path, (b) => b.probe(url, timeoutMs));
  @override
  Future<String> exitIP(int timeoutMs) =>
      _run(path, (b) => b.exitIP(timeoutMs));
}

/// Top-level so the isolate closure captures only [path] and [call].
Future<String> _run(String path, String Function(SingLinkBindings b) call) =>
    Isolate.run(() => call(SingLinkBindings.open(path)));

class AndroidVpnCore implements VpnCore {
  AndroidVpnCore({
    required this.location,
    required this.calls,
    this.channel = vpnChannel,
    this.mtu = 1500,
    this.dnsUpstream = '1.1.1.1:53',
  }) {
    channel.setMethodCallHandler(_onNativeCall);
  }

  @override
  final SingLinkLibLocation location;
  final TunCalls calls;
  final MethodChannel channel;
  final int mtu;

  /// Where the core sends the device's DNS queries (DNS-over-TCP through
  /// the tunnel; the TUN advertises 172.19.0.2 and the core answers any
  /// UDP/53 address).
  final String dnsUpstream;

  /// True between a successful [start] and the matching [stop] / drop:
  /// the foreground service is up and must be stopped with the session.
  bool _active = false;

  @override
  bool get available => location.found;

  @override
  bool get usesLocalProxy => false;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'revoked') {
      // The system already tore the VPN down; stop relaying. The next status
      // poll then reports running:false and the UI shows 「連線已中斷」.
      _active = false;
      try {
        await calls.tunStop();
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<CoreVersion> version() async =>
      CoreVersion.fromJson(await _json(calls.version));

  @override
  Future<ParseLinkResult> parseLink(String link) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return ParseLinkResult.failure('empty link');
    try {
      final json = await _json(() => calls.parseLink(trimmed));
      return ParseLinkResult.fromJson(trimmed, json);
    } catch (e) {
      return ParseLinkResult.failure(e.toString());
    }
  }

  /// [listen] is ignored: there is no local proxy port on Android.
  @override
  Future<OpResult> start({required String link, required String listen}) async {
    if (!available) {
      return OpResult(false, const CoreUnavailableException().toString());
    }
    try {
      // A session the UI no longer knows about would make TunStart fail
      // with "already running"; end it first.
      final s = CoreStatus.fromJson(await _json(calls.status));
      if (s.running) {
        await calls.tunStop();
        await _stopService();
      }

      final granted = await channel.invokeMethod<bool>('prepare') ?? false;
      if (!granted) return const OpResult(false, vpnPermissionDenied);

      final fd = await channel.invokeMethod<int>('establish', {'mtu': mtu});
      if (fd == null || fd < 0) {
        await _stopService();
        return const OpResult(false, 'cannot establish the VPN interface');
      }

      final cfg = jsonEncode({
        'link': link,
        'mtu': mtu,
        'dns': dnsUpstream,
        'appleHeader': false,
      });
      OpResult res;
      try {
        res = OpResult.fromJson(await _json(() => calls.tunStart(fd, cfg)));
      } catch (e) {
        res = OpResult(false, e.toString());
      }
      if (!res.ok) {
        // The core did not take the descriptor: Kotlin closes it, which
        // removes the VPN interface, and stops the service.
        await _stopService(closeFd: true);
        return res;
      }
      _active = true;
      return res;
    } on PlatformException catch (e) {
      await _stopService();
      return OpResult(false, e.message ?? e.code);
    } on MissingPluginException catch (e) {
      return OpResult(false, e.toString());
    }
  }

  @override
  Future<OpResult> stop() async {
    _active = false;
    OpResult res;
    try {
      res = OpResult.fromJson(await _json(calls.tunStop));
    } catch (e) {
      res = OpResult(false, e.toString());
    }
    await _stopService();
    return res;
  }

  @override
  Future<CoreStatus> status() async {
    final s = CoreStatus.fromJson(await _json(calls.status));
    if (!s.running && _active) {
      // The tunnel ended on its own (node gone, TUN failed, revoked): the
      // core closed the descriptor; take the notification down too.
      _active = false;
      await _stopService();
    }
    return s;
  }

  @override
  Future<ProbeResult> probe(String url, {int timeoutMs = 8000}) async {
    try {
      return ProbeResult.fromJson(
        await _json(() => calls.probe(url, timeoutMs)),
      );
    } catch (e) {
      return ProbeResult(ok: false, error: e.toString());
    }
  }

  @override
  Future<ExitIpResult> exitIP({int timeoutMs = 8000}) async {
    try {
      return ExitIpResult.fromJson(await _json(() => calls.exitIP(timeoutMs)));
    } catch (e) {
      return ExitIpResult(ok: false, error: e.toString());
    }
  }

  Future<void> _stopService({bool closeFd = false}) async {
    try {
      await channel.invokeMethod<void>('stop', {'closeFd': closeFd});
    } catch (_) {
      // Nothing more to do: the service may already be gone.
    }
  }

  Future<Map<String, dynamic>> _json(Future<String> Function() call) async {
    if (!available) throw const CoreUnavailableException();
    return decodeCoreJson(await call());
  }
}
