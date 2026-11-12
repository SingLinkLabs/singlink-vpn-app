// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// iOS: device-wide VPN through a Network Extension packet tunnel.
//
// The tunnel itself runs in the PacketTunnel app extension
// (ios/PacketTunnel/PacketTunnelProvider.swift), which owns the Go core while
// connected. The app drives it over the MethodChannel implemented in
// ios/Runner/SingLinkVpnPlugin.swift (NETunnelProviderManager):
//
//   start {link, server}   stop   status   probe {url, timeoutMs}
//   exitIP {timeoutMs}                     -> JSON strings in the core format
//   onStatus (native -> Dart)              {"state":"connected","running":true}
//
// Version and link parsing do not need the tunnel: the core is also linked
// statically into the app, so they go through FFI (DynamicLibrary.process()).

import 'dart:async';

import 'package:flutter/services.dart';

import '../core/singlink_bindings.dart';
import '../core/singlink_service.dart';
import '../models/core_status.dart';
import '../models/profile.dart';

const iosVpnChannel = MethodChannel('com.singlinklabs.singlinkvpn/vpn');

VpnCore createIosCore() => IosTunnelCore(ffi: SingLinkService.locate());

class IosTunnelCore implements VpnCore {
  /// [ffi] answers version / parseLink (the core linked into the app).
  IosTunnelCore({required VpnCore ffi, MethodChannel channel = iosVpnChannel})
    : _ffi = ffi,
      _channel = channel {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final VpnCore _ffi;
  final MethodChannel _channel;
  final _states = StreamController<String>.broadcast();

  /// Last NEVPNStatus reported by iOS ("connected", "disconnected", ...).
  String? vpnState;

  /// NEVPNStatus changes, also when the VPN is switched in iOS Settings.
  Stream<String> get vpnStates => _states.stream;

  @override
  bool get available => _ffi.available;

  @override
  bool get usesLocalProxy => false;

  @override
  SingLinkLibLocation get location => _ffi.location;

  @override
  Future<CoreVersion> version() => _ffi.version();

  @override
  Future<ParseLinkResult> parseLink(String link) => _ffi.parseLink(link);

  /// [listen] is ignored: there is no local proxy port on iOS.
  @override
  Future<OpResult> start({required String link, required String listen}) async {
    var server = '';
    try {
      final parsed = await _ffi.parseLink(link);
      if (parsed.ok) server = parsed.profile?.server ?? '';
    } catch (_) {
      // The extension parses the link again and reports a bad one.
    }
    return OpResult.fromJson(
      await _call('start', {'link': link, 'server': server}),
    );
  }

  @override
  Future<OpResult> stop() async => OpResult.fromJson(await _call('stop'));

  /// `running` follows iOS's VPN status: false once the tunnel is gone,
  /// with the reason in `lastError` unless the app stopped it.
  @override
  Future<CoreStatus> status() async =>
      CoreStatus.fromJson(await _invoke('status', null, rethrowErrors: true));

  @override
  Future<ProbeResult> probe(String url, {int timeoutMs = 8000}) async =>
      ProbeResult.fromJson(
        await _call('probe', {'url': url, 'timeoutMs': timeoutMs}),
      );

  @override
  Future<ExitIpResult> exitIP({int timeoutMs = 8000}) async =>
      ExitIpResult.fromJson(await _call('exitIP', {'timeoutMs': timeoutMs}));

  /// Calls the native side; failures become `{"ok":false,"error":..}` so
  /// the controller shows a friendly message instead of crashing.
  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, Object?>? args,
  ]) => _invoke(method, args, rethrowErrors: false);

  Future<Map<String, dynamic>> _invoke(
    String method,
    Map<String, Object?>? args, {
    required bool rethrowErrors,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method, args);
      if (raw is String) return decodeCoreJson(raw);
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return {'ok': false, 'error': 'malformed reply from the VPN service'};
    } on MissingPluginException {
      if (rethrowErrors) rethrow;
      return {'ok': false, 'error': vpnUnavailableError};
    } on PlatformException catch (e) {
      if (rethrowErrors) rethrow;
      return {'ok': false, 'error': e.message ?? e.code};
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'onStatus') return null;
    final args = call.arguments;
    Map<String, dynamic> m = const {};
    if (args is String) m = decodeCoreJson(args);
    if (args is Map) m = Map<String, dynamic>.from(args);
    final state = m['state'];
    if (state is String) {
      vpnState = state;
      _states.add(state);
    }
    return null;
  }

  /// Stops listening to native status pushes (tests).
  void dispose() {
    _channel.setMethodCallHandler(null);
    _states.close();
  }
}

/// The app was built without the VPN service (no native handler).
const vpnUnavailableError = 'vpn unsupported: VPN service not available';
