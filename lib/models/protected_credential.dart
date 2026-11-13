// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

/// Warning consent travels with the exact protected credential, never with
/// attacker-editable ordinary profile metadata.
class ProtectedCredential {
  const ProtectedCredential(this.link, this.acknowledgedWarnings);
  final String link;
  final List<String> acknowledgedWarnings;
  String encode() => jsonEncode({
    'version': 1,
    'link': link,
    'acknowledgedWarnings': acknowledgedWarnings,
  });
  factory ProtectedCredential.decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map ||
          json['version'] != 1 ||
          json['link'] is! String ||
          !(json['link'] as String).startsWith('singlink://') ||
          json['acknowledgedWarnings'] is! List ||
          (json['acknowledgedWarnings'] as List).any((e) => e is! String)) {
        throw const FormatException('Protected credential is invalid');
      }
      return ProtectedCredential(
        json['link'] as String,
        List<String>.from(json['acknowledgedWarnings'] as List),
      );
    } catch (_) {
      throw const FormatException('Protected credential is invalid');
    }
  }
}
