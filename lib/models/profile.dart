// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'security_warning.dart';

/// An imported `singlink://` server profile.
///
/// The fields mirror the `profile` object returned by `SingLinkParseLink`; the
/// raw [link] exists only during import/migration. Committed profiles hold an
/// opaque [secretRef]; native start receives the protected value when needed.
class Profile {
  Profile({
    required this.id,
    required this.link,
    required this.name,
    required this.server,
    required this.transport,
    required this.sni,
    required this.subject,
    required this.plan,
    required this.expiresAt,
    required this.caps,
    this.rateKbps = 0,
    this.maxConns = 0,
    required this.addedAt,
    this.secretRef = '',
    this.acknowledgedWarnings = const [],
  });

  final String id;
  final String link;
  final String secretRef;
  final List<String> acknowledgedWarnings;

  Profile withCredential({
    required String reference,
    String value = '',
    List<String>? acceptedWarnings,
  }) => Profile(
    id: id,
    link: value,
    secretRef: reference,
    name: name,
    server: server,
    transport: transport,
    sni: sni,
    subject: subject,
    plan: plan,
    expiresAt: expiresAt,
    caps: caps,
    rateKbps: rateKbps,
    maxConns: maxConns,
    addedAt: addedAt,
    acknowledgedWarnings: acceptedWarnings ?? acknowledgedWarnings,
  );
  final String name;

  /// `host:port`.
  final String server;

  /// `tls` or `tcp`.
  final String transport;
  final String sni;

  /// Hex-encoded subject identifier.
  final String subject;
  final int plan;

  /// Null when the link carries no expiry (`expiresAt` missing or 0).
  final DateTime? expiresAt;
  final List<String> caps;

  /// Token limits; 0 means unlimited.
  final int rateKbps;
  final int maxConns;
  final DateTime addedAt;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  /// Display name; falls back to the server address when the link has none.
  String get displayName => name.trim().isEmpty ? server : name.trim();

  /// Builds a profile from the `profile` object of an `SingLinkParseLink` reply.
  factory Profile.fromCore(
    String link,
    Map<String, dynamic> json, {
    String? id,
    DateTime? addedAt,
    String secretRef = '',
  }) {
    final now = DateTime.now();
    return Profile(
      id: id ?? newProfileId(),
      link: link.trim(),
      secretRef: secretRef,
      name: _str(json['name']),
      server: _str(json['server']),
      transport: _str(json['transport']),
      sni: _str(json['sni']),
      subject: _str(json['subject']),
      plan: _int(json['plan']),
      expiresAt: _unix(json['expiresAt']),
      caps: _strList(json['caps']),
      rateKbps: _int(json['rateKbps']),
      maxConns: _int(json['maxConns']),
      addedAt: addedAt ?? now,
    );
  }

  /// Persistence format (superset of the core's profile object).
  Map<String, dynamic> toJson() => {
    'id': id,
    'secretRef': secretRef,
    'name': name,
    'server': server,
    'transport': transport,
    'sni': sni,
    'subject': subject,
    'plan': plan,
    'expiresAt': expiresAt == null
        ? 0
        : expiresAt!.millisecondsSinceEpoch ~/ 1000,
    'caps': caps,
    'rateKbps': rateKbps,
    'maxConns': maxConns,
    'addedAt': addedAt.millisecondsSinceEpoch ~/ 1000,
  };

  factory Profile.fromJson(Map<String, dynamic> json) => Profile.fromCore(
    _str(json['link']),
    json,
    id: _str(json['id']).isEmpty ? null : _str(json['id']),
    addedAt: _unix(json['addedAt']),
    secretRef: _str(json['secretRef']),
  );
}

final _idRandom = Random.secure();

/// A new profile ID: 128 random bits from the platform CSPRNG as 32 lowercase
/// hex digits. Unlike the earlier timestamp IDs it reveals nothing about when
/// a profile was added and cannot collide for profiles created together.
/// IDs already stored (including legacy timestamp IDs) are kept unchanged.
String newProfileId() {
  final b = StringBuffer();
  for (var i = 0; i < 16; i++) {
    b.write(_idRandom.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// Result of `SingLinkParseLink`: `{"ok":true,"profile":{...}}` or
/// `{"ok":false,"error":".."}`.
class ParseLinkResult {
  const ParseLinkResult._(this.profile, this.error, [this.warnings = const []]);

  final Profile? profile;
  final String? error;
  final List<SecurityWarning> warnings;

  bool get ok => profile != null;

  factory ParseLinkResult.failure(String error) =>
      ParseLinkResult._(null, error);

  factory ParseLinkResult.fromJson(String link, Map<String, dynamic> json) {
    final profile = json['profile'];
    if (json['ok'] == true && profile is Map<String, dynamic>) {
      return ParseLinkResult._(
        Profile.fromCore(link, profile),
        null,
        SecurityWarning.parse(json['warnings']),
      );
    }
    final err = _str(json['error']);
    return ParseLinkResult._(null, err.isEmpty ? 'cannot parse link' : err);
  }
}

String _str(Object? v) => v == null ? '' : v.toString();

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

DateTime? _unix(Object? v) {
  final s = _int(v);
  return s <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);
}

List<String> _strList(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList() : const <String>[];
