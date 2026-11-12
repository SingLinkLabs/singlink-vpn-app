// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/legal.dart';

// The attribution shown in the app must match NOTICE, which redistributions
// and derivative works are required to keep (Apache License 2.0, s. 4(d)).
void main() {
  test('NOTICE carries the same attribution the app shows', () {
    final notice = File('NOTICE').readAsStringSync();
    for (final line in kAttribution.split('\n')) {
      expect(notice, contains(line.trim()));
    }
    expect(notice, contains('Copyright 2026 SingLinkLabs'));
  });

  test('every first-party source file keeps its copyright header', () {
    final roots = [
      'lib',
      'core',
      'test',
      'android/app/src/main/kotlin',
      'ios/PacketTunnel',
    ];
    final missing = <String>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!RegExp(r'\.(dart|go|kt|swift)$').hasMatch(f.path)) continue;
        if (f.path.contains('/build/')) continue;
        final head = f.readAsLinesSync().take(3).join('\n');
        if (!head.contains('SingLinkLabs')) missing.add(f.path);
      }
    }
    expect(missing, isEmpty);
  });
}
