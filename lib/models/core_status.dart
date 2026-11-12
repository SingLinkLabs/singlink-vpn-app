// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

/// Parsed replies of the libsinglink C ABI (everything except `SingLinkParseLink`,
/// which lives in `profile.dart`).
library;

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(Object? v) => v == null ? '' : v.toString();

/// `{"ok":true}` | `{"ok":false,"error":".."}` from `SingLinkStart` / `SingLinkStop`.
class OpResult {
  const OpResult(this.ok, [this.error = '']);

  final bool ok;
  final String error;

  factory OpResult.fromJson(Map<String, dynamic> json) =>
      OpResult(json['ok'] == true, _str(json['error']));
}

/// `SingLinkVersion`: `{"version":"1.0.0-draft","protocol":"SingLink/1"}`.
class CoreVersion {
  const CoreVersion(this.version, this.protocol);

  final String version;
  final String protocol;

  factory CoreVersion.fromJson(Map<String, dynamic> json) =>
      CoreVersion(_str(json['version']), _str(json['protocol']));

  @override
  String toString() => protocol.isEmpty ? version : '$version · $protocol';
}

/// `SingLinkStatus`.
class CoreStatus {
  const CoreStatus({
    required this.running,
    required this.listen,
    required this.up,
    required this.down,
    required this.conns,
    required this.since,
    required this.lastError,
  });

  static const idle = CoreStatus(
    running: false,
    listen: '',
    up: 0,
    down: 0,
    conns: 0,
    since: null,
    lastError: '',
  );

  final bool running;
  final String listen;

  /// Total bytes sent / received since start.
  final int up;
  final int down;
  final int conns;
  final DateTime? since;
  final String lastError;

  factory CoreStatus.fromJson(Map<String, dynamic> json) {
    final since = _int(json['since']);
    return CoreStatus(
      running: json['running'] == true,
      listen: _str(json['listen']),
      up: _int(json['up']),
      down: _int(json['down']),
      conns: _int(json['conns']),
      since: since <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(since * 1000),
      lastError: _str(json['lastError']),
    );
  }
}

/// `SingLinkProbe`: `{"ok":true,"status":204,"latencyMs":123}` |
/// `{"ok":false,"error":".."}`.
class ProbeResult {
  const ProbeResult({
    required this.ok,
    this.status = 0,
    this.latencyMs = 0,
    this.error = '',
  });

  final bool ok;
  final int status;
  final int latencyMs;
  final String error;

  factory ProbeResult.fromJson(Map<String, dynamic> json) => ProbeResult(
    ok: json['ok'] == true,
    status: _int(json['status']),
    latencyMs: _int(json['latencyMs']),
    error: _str(json['error']),
  );
}

/// `SingLinkExitIP`: `{"ok":true,"ip":"203.0.113.7"}` |
/// `{"ok":false,"error":".."}` — the public IP websites see through the tunnel.
class ExitIpResult {
  const ExitIpResult({required this.ok, this.ip = '', this.error = ''});

  final bool ok;
  final String ip;
  final String error;

  factory ExitIpResult.fromJson(Map<String, dynamic> json) {
    final ip = _str(json['ip']).trim();
    final ok = json['ok'] == true && ip.isNotEmpty;
    return ExitIpResult(
      ok: ok,
      ip: ok ? ip : '',
      error: ok
          ? ''
          : (_str(json['error']).isEmpty ? 'no ip' : _str(json['error'])),
    );
  }
}
