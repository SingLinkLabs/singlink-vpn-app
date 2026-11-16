// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/singlink_service.dart';
import 'support/secret_store.dart';

void main() {
  final library =
      Platform.environment['SINGLINK_SYNTHETIC_ABI_LIB'] ??
      'core/build/macos/libsinglink.dylib';
  test(
    'real ABI parses four fresh signed profiles and protected import binds warning consent',
    () async {
      final generated = await Process.run('go', [
        'run',
        './testfixture',
      ], workingDirectory: 'core');
      expect(
        generated.exitCode,
        0,
        reason: 'Runtime synthetic fixture generation must succeed',
      );
      final links = Map<String, String>.from(
        jsonDecode(generated.stdout as String) as Map,
      );
      final core = SingLinkService.at(File(library).absolute.path);
      expect(
        core.available,
        isTrue,
        reason: 'Synthetic test requires the rebuilt core ABI',
      );
      final expected = {
        'defaultTLS': 0,
        'rawTCP': 1,
        'insecureTLS': 1,
        'pinnedTLS': 0,
      };
      for (final entry in expected.entries) {
        final parsed = await core.parseLink(links[entry.key]!);
        expect(parsed.ok, isTrue, reason: 'Fresh synthetic profile must parse');
        expect(parsed.warnings.length, entry.value, reason: entry.key);
      }
      final dir = await Directory.systemTemp.createTemp(
        'synthetic-valid-vault-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');
      final secrets = MemorySecretStore();
      final store = AppStore(file, secrets: secrets);
      final c = ClientController(core: core, store: store);
      await c.init();
      addTearDown(() => c.dispose());
      expect(await c.importLink(links['rawTCP']!), isNotNull);
      expect(c.profiles, isEmpty);
      expect(
        await c.importLink(
          links['rawTCP']!,
          confirmWarnings: (warnings) async => warnings.length == 1,
        ),
        isNull,
      );
      final saved = await file.readAsString();
      final credential = await store.readCredential(c.profiles.single);
      expect(credential.link == links['rawTCP'], isTrue);
      expect(credential.acknowledgedWarnings.length, 1);
      expect(c.profiles.single.link, isEmpty);
      final uri = Uri.parse(links['rawTCP']!);
      final parts = uri.userInfo.split('.');
      expect(saved.contains(links['rawTCP']!), isFalse);
      expect(
        parts.every((part) => !saved.contains(part)),
        isTrue,
        reason: 'Metadata must not contain token or device seed',
      );
      await c.shutdown();
    },
    skip: !File(library).existsSync()
        ? 'Build the reviewed core macOS ABI to run the synthetic integration test'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
