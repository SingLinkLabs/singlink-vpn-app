// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// Android: device-wide VPN through VpnService.
//
// Kotlin (android/app/src/main/kotlin/.../SingLinkVpnService.kt) asks for the
// user's consent, runs the foreground VpnService and establishes the TUN
// interface; it hands the detached TUN file descriptor to Dart. Dart then
// passes the descriptor to the Go core with SingLinkTunStart, which relays
// every IP packet through the SingLink node. The core and the app share one
// process, so Status / Probe / ExitIP work over FFI exactly as on desktop.
//
// Descriptor ownership (A-04) never depends on whether a start succeeded:
// SingLinkTunStart never takes the descriptor it is given. The core works on
// its own duplicate and always consumes it (closes it on any failure,
// including a Stop that cancels the start after the tunnel took it; keeps it
// while the session runs). The bridge keeps the original and closes it
// exactly once: Dart sends `closeFd` once SingLinkTunStart has returned,
// whatever it returned, or without calling the core at all when the start
// is abandoned first. Nothing ever closes the original while the core call
// is in progress.
//
// Channel `com.singlinklabs.singlinkvpn/vpn`
//   Dart → Kotlin  filesDir                 → String
//                  prepare                  → bool (false: user declined)
//                  establish {mtu}          → int (detached TUN fd)
//                  closeFd {fd}             → null (close the bridge's own
//                                            descriptor; once per establish)
//                  stop                     → null
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
/// system VPN dialog (shown as msgVpnPermission in error_messages.dart).
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
  int _generation = 0;
  int? _owner;
  Future<void>? _pendingStart;
  Future<void>? _pendingStop;
  bool _current(int generation) => generation == _generation;

  @override
  bool get available => location.found;

  @override
  bool get usesLocalProxy => false;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'revoked') {
      // The system already tore the VPN down; stop relaying. The next status
      // poll then reports running:false and the UI shows msgDropped.
      await stop();
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
    final generation = ++_generation;
    // A status poll during this start must not mistake the new session for
    // an earlier one that ended by itself and stop its service.
    _active = false;
    final previousStart = _pendingStart;
    final previousStop = _pendingStop;
    final done = Completer<void>();
    _pendingStart = done.future;
    const cancelled = OpResult(false, 'Connection cancelled.');
    try {
      if (previousStart != null) await previousStart;
      if (previousStop != null) await previousStop;
      if (!_current(generation)) return cancelled;
      final s = CoreStatus.fromJson(await _json(calls.status));
      if (!_current(generation)) return cancelled;
      if (s.running) {
        await calls.tunStop();
        if (!_current(generation)) return cancelled;
        await _stopService();
      }
      if (!_current(generation)) return cancelled;
      final granted = await channel.invokeMethod<bool>('prepare') ?? false;
      if (!_current(generation)) return cancelled;
      if (!granted) return const OpResult(false, vpnPermissionDenied);
      final fd = await channel.invokeMethod<int>('establish', {'mtu': mtu});
      if (!_current(generation)) {
        // A stop landed after Kotlin handed over the descriptor: the core
        // never saw it, so close it here or the VPN interface stays up.
        if (fd != null && fd >= 0) await _releaseFd(fd);
        return cancelled;
      }
      if (fd == null || fd < 0) {
        await _stopService();
        return const OpResult(false, 'cannot establish the VPN interface');
      }
      _owner = generation;
      final cfg = jsonEncode({
        'link': link,
        'mtu': mtu,
        'dns': dnsUpstream,
        'appleHeader': false,
      });
      OpResult res;
      var threw = false;
      try {
        res = OpResult.fromJson(await _json(() => calls.tunStart(fd, cfg)));
      } catch (_) {
        threw = true;
        res = const OpResult(false, 'The native tunnel could not start.');
      } finally {
        // The core call has returned (or never ran): it only ever used its
        // own duplicate, so the bridge's original is closed now, exactly
        // once, on success, failure and cancellation alike. A running
        // session keeps the interface up through the core's duplicate.
        await _releaseFd(fd);
      }
      if (threw) {
        // The reply was lost, so the core may have started after all: stop
        // it (a no-op when nothing runs) so it closes its duplicate.
        try {
          await calls.tunStop();
        } catch (_) {}
      }
      if (!_current(generation)) {
        if (_owner == generation) {
          // The core closes its duplicate on stop (a failed start already
          // closed it).
          if (res.ok) await calls.tunStop();
          await _stopService();
          _owner = null;
        }
        return cancelled;
      }
      if (!res.ok) {
        await _stopService();
        return res;
      }
      _active = true;
      return res;
    } on PlatformException catch (e) {
      if (_current(generation)) await _stopService();
      return OpResult(false, e.message ?? e.code);
    } on MissingPluginException {
      return const OpResult(false, 'VPN service unavailable.');
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  @override
  Future<OpResult> stop() async {
    ++_generation;
    _active = false;
    final previous = _pendingStop;
    final done = Completer<void>();
    _pendingStop = done.future;
    try {
      if (previous != null) await previous;
      OpResult res;
      try {
        res = OpResult.fromJson(await _json(calls.tunStop));
      } catch (_) {
        res = const OpResult(false, 'The native tunnel could not stop.');
      }
      await _stopService();
      return res;
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  @override
  Future<CoreStatus> status() async {
    final s = CoreStatus.fromJson(await _json(calls.status));
    if (!s.running && _active) {
      // The tunnel ended on its own (node gone, TUN failed, revoked): the
      // core closed its descriptor; take the notification down too.
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

  /// Asks Kotlin to close the bridge's original descriptor for [fd] (the core
  /// never owns it). Kotlin closes each established descriptor at most once
  /// and ignores numbers it did not hand out.
  Future<void> _releaseFd(int fd) async {
    try {
      await channel.invokeMethod<void>('closeFd', {'fd': fd});
    } catch (_) {
      // The activity is gone; the process owns nothing else to clean up.
    }
  }

  Future<void> _stopService() async {
    try {
      await channel.invokeMethod<void>('stop');
    } catch (_) {
      // Nothing more to do: the service may already be gone.
    }
  }

  Future<Map<String, dynamic>> _json(Future<String> Function() call) async {
    if (!available) throw const CoreUnavailableException();
    return decodeCoreJson(await call());
  }
}
