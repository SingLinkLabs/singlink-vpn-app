// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

/// Native warnings remain visible even when a newer core adds unknown codes.
class SecurityWarning {
  const SecurityWarning(this.message);
  final String message;

  static List<SecurityWarning> parse(Object? value) {
    if (value == null) return const [];
    if (value is! List) {
      return const [
        SecurityWarning('The core returned an unknown security warning.'),
      ];
    }
    return List.unmodifiable(
      value.map(
        (item) => SecurityWarning(
          item is String && item.isNotEmpty
              ? item
              : 'The core returned an unknown security warning.',
        ),
      ),
    );
  }
}
