// High-level async wrapper over libsinglink.
//
// Every core call runs in a short-lived background isolate (Isolate.run) that
// re-opens the DynamicLibrary by path, so blocking calls such as SingLinkStart
// or SingLinkExitIP never freeze the UI. The Go runtime is process-wide, so
// state set by SingLinkStart in one isolate is visible to SingLinkStatus in
// another.

import 'dart:convert';
import 'dart:isolate';

import '../models/core_status.dart';
import '../models/profile.dart';
import 'singlink_bindings.dart';

/// What the app needs from the protocol core. [SingLinkService] is the real
/// implementation; tests and previews substitute a fake.
abstract class VpnCore {
  bool get available;
  SingLinkLibLocation get location;

  Future<CoreVersion> version();
  Future<ParseLinkResult> parseLink(String link);
  Future<OpResult> start({required String link, required String listen});
  Future<OpResult> stop();
  Future<CoreStatus> status();
  Future<ProbeResult> probe(String url, {int timeoutMs = 8000});
  Future<ExitIpResult> exitIP({int timeoutMs = 8000});
}

/// Thrown when a call is made while the core library is not loaded.
class CoreUnavailableException implements Exception {
  const CoreUnavailableException();
  @override
  String toString() => 'core unavailable';
}

class SingLinkService implements VpnCore {
  SingLinkService._(this.location);

  /// Searches for libsinglink and verifies it exposes the full ABI. Never
  /// throws: check [available] / [location] to show a banner instead.
  factory SingLinkService.locate() => SingLinkService._(locateSingLinkLib());

  /// Binds to a specific library file (tests, custom launchers).
  factory SingLinkService.at(String path) =>
      SingLinkService._(locateSingLinkLib(candidates: [path]));

  /// For tests / previews: a service with no core.
  factory SingLinkService.unavailable({List<String> searched = const []}) =>
      SingLinkService._(
        SingLinkLibLocation(path: null, searched: searched, errors: const []),
      );

  @override
  final SingLinkLibLocation location;

  @override
  bool get available => location.found;

  @override
  Future<CoreVersion> version() async =>
      CoreVersion.fromJson(await _json((b) => b.version()));

  @override
  Future<ParseLinkResult> parseLink(String link) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return ParseLinkResult.failure('empty link');
    try {
      final json = await _json((b) => b.parseLink(trimmed));
      return ParseLinkResult.fromJson(trimmed, json);
    } on CoreUnavailableException catch (e) {
      return ParseLinkResult.failure(e.toString());
    }
  }

  @override
  Future<OpResult> start({required String link, required String listen}) =>
      _op(() {
        final cfg = jsonEncode({'link': link, 'listen': listen});
        return _json((b) => b.start(cfg));
      });

  @override
  Future<OpResult> stop() => _op(() => _json((b) => b.stop()));

  @override
  Future<CoreStatus> status() async =>
      CoreStatus.fromJson(await _json((b) => b.status()));

  @override
  Future<ProbeResult> probe(String url, {int timeoutMs = 8000}) async {
    try {
      return ProbeResult.fromJson(await _json((b) => b.probe(url, timeoutMs)));
    } catch (e) {
      return ProbeResult(ok: false, error: e.toString());
    }
  }

  @override
  Future<ExitIpResult> exitIP({int timeoutMs = 8000}) async {
    try {
      return ExitIpResult.fromJson(await _json((b) => b.exitIP(timeoutMs)));
    } catch (e) {
      return ExitIpResult(ok: false, error: e.toString());
    }
  }

  Future<OpResult> _op(Future<Map<String, dynamic>> Function() call) async {
    try {
      return OpResult.fromJson(await call());
    } catch (e) {
      return OpResult(false, e.toString());
    }
  }

  Future<Map<String, dynamic>> _json(
    String Function(SingLinkBindings b) call,
  ) async {
    final path = location.path;
    if (path == null) throw const CoreUnavailableException();
    final raw = await _runInIsolate(path, call);
    return decodeCoreJson(raw);
  }
}

/// Top-level so the isolate closure captures only [path] and [call]
/// (both sendable), never a SingLinkService instance.
Future<String> _runInIsolate(
  String path,
  String Function(SingLinkBindings b) call,
) => Isolate.run(() => call(SingLinkBindings.open(path)));

/// Decodes a core reply; malformed output becomes an `{"ok":false}` object.
Map<String, dynamic> decodeCoreJson(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is Map<String, dynamic>) return v;
    return {'ok': false, 'error': 'malformed core reply: $raw'};
  } on FormatException {
    return {'ok': false, 'error': 'core reply is not JSON: $raw'};
  }
}
