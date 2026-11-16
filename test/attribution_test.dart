// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/legal.dart';

// The original-author attribution is required by NOTICE (Apache License 2.0,
// s. 4(d)). Redistributions and derivative works must keep it in NOTICE, in
// the main-screen footer, in the registered license entry and in every
// source-file header. Removing or weakening any of them fails these tests.
const _originalAuthorLine =
    'Originally developed and provided by SingLinkVPN — https://singlinkvpn.com';
const _providedBy = 'Software provided by the original author SingLinkVPN.';

void main() {
  test('attribution constants name the original author', () {
    expect(kOriginalAuthor, 'SingLinkVPN');
    expect(
      kMadeBy,
      'Provided by the original author SingLinkVPN\n'
      'Powered by the SingLink Beta Protocol',
    );
    expect(kAttribution, contains(_providedBy));
    expect(kAttribution, contains(_originalAuthorLine));
    expect(
      kAttribution,
      contains(
        'Based on the SingLinkVPN prototype and the SingLink Beta Protocol by SingLinkVPN',
      ),
    );
    expect(kCopyright, '© 2026 SingLinkVPN · Apache-2.0');
  });

  test('NOTICE carries the same attribution the app shows', () {
    final notice = File('NOTICE').readAsStringSync();
    for (final line in kAttribution.split('\n')) {
      expect(notice, contains(line.trim()));
    }
    expect(notice, contains(_providedBy));
    expect(notice, contains(_originalAuthorLine));
    expect(notice, contains('Copyright 2026 SingLinkVPN'));
  });

  test('the main screen shows the attribution footer', () {
    final home = File('lib/ui/home_page.dart').readAsStringSync();
    expect(RegExp(r'Text\(\s*kMadeBy\b').hasMatch(home), isTrue);
  });

  test('the registered license entry carries the attribution', () async {
    registerAppLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final ours = entries.where((e) => e.packages.contains('SingLinkVPN'));
    expect(ours, isNotEmpty);
    final text = ours.expand((e) => e.paragraphs).map((p) => p.text).join('\n');
    expect(text, contains(_providedBy));
    expect(text, contains(_originalAuthorLine));
    expect(text, contains('Copyright 2026 SingLinkVPN'));
  });

  test('the native core reports the original author', () {
    final ffi = File('core/ffi/main.go').readAsStringSync();
    expect(
      ffi,
      contains(
        '"SingLinkVPN client, software provided by the original author '
        'SingLinkVPN · " + singlink.Attribution',
      ),
    );
  });

  test('every first-party source file keeps its copyright header', () {
    final roots = [
      'lib',
      'core',
      'test',
      'scripts',
      'android/app/src',
      'ios/PacketTunnel',
      'apple',
    ];
    final files = <String>[
      'ios/Runner/SecretStorePlugin.swift',
      'ios/Runner/SingLinkVpnPlugin.swift',
      'macos/Runner/SecretStorePlugin.swift',
      'windows/runner/credential_store.cpp',
      'windows/runner/credential_store.h',
      'android/app/src/main/res/xml/backup_rules.xml',
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ];
    for (final root in roots) {
      final dir = Directory(root);
      expect(dir.existsSync(), isTrue, reason: root);
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!RegExp(r'\.(dart|go|kt|swift|py|sh|rb|h)$').hasMatch(f.path)) {
          continue;
        }
        if (f.path.contains('/build/') || f.path.contains('/.dart_tool/')) {
          continue;
        }
        files.add(f.path);
      }
    }
    final missing = <String>[];
    for (final path in files) {
      final head = File(path).readAsLinesSync().take(4).join('\n');
      if (!head.contains('Copyright 2026 SingLinkVPN')) missing.add(path);
      if (!head.contains('SPDX-License-Identifier: Apache-2.0')) {
        missing.add(path);
      }
    }
    expect(files.length, greaterThan(50));
    expect(missing, isEmpty);
  });
}
