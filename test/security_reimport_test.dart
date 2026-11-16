// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
//
// APP-01 recovery paths: restored state without its protected record, and
// app-owned plaintext residue from older versions. Synthetic data only.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/models/profile.dart';
import 'support/fakes.dart';
import 'support/secret_store.dart';

/// Gives each synthetic link its own server so it is a different profile.
class PerLinkServerCore extends FakeCore {
  @override
  Future<ParseLinkResult> parseLink(String link) async {
    final name = link.split('#').last;
    return ParseLinkResult.fromJson(link, {
      'ok': true,
      'profile': {'name': name, 'server': '$name.example.invalid:443'},
    });
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('synthetic-reimport-');
    file = File('${dir.path}/state.json');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('stale legacy plaintext temp is removed on load', () async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('{"profiles":[{"link":"singlink://synthetic"}]}');
    final store = AppStore(file, secrets: MemorySecretStore());
    await store.load();
    expect(await tmp.exists(), isFalse);
    // Also when a committed state already exists.
    await store.commit(AppState());
    await tmp.writeAsString('singlink://synthetic-residue');
    await store.load();
    expect(await tmp.exists(), isFalse);
  });

  test(
    'missing protected record blocks connect and re-import repairs in place',
    () async {
      final secrets = MemorySecretStore();
      final store = AppStore(file, secrets: secrets);
      final core = FakeCore();
      final c = ClientController(core: core, store: store);
      addTearDown(c.dispose);
      await c.init();
      expect(await c.importLink('singlink://synthetic#A'), isNull);
      final before = c.profiles.single;

      // Restored on another device / OS key reset: the reference is dangling.
      secrets.values.clear();
      await c.connect();
      expect(c.isConnected, isFalse);
      expect(c.error?.message, contains('re-import'));
      expect(core.calls.where((e) => e.startsWith('start')), isEmpty);

      // Re-importing the same server is accepted and replaces the entry.
      expect(await c.importLink('singlink://synthetic#A'), isNull);
      expect(c.profiles, hasLength(1));
      final after = c.profiles.single;
      expect(after.id, before.id);
      expect(after.secretRef, isNot(before.secretRef));
      expect((await store.readCredential(after)).link, 'singlink://synthetic#A');
      expect(await file.readAsString(), isNot(contains('singlink://')));
      await c.connect();
      expect(c.isConnected, isTrue);
      await c.shutdown();
    },
  );

  test('a broken profile does not block importing a different one', () async {
    final secrets = MemorySecretStore();
    final store = AppStore(file, secrets: secrets);
    final c = ClientController(core: PerLinkServerCore(), store: store);
    addTearDown(c.dispose);
    await c.init();
    expect(await c.importLink('singlink://synthetic#a'), isNull);
    secrets.values.clear();
    expect(await c.importLink('singlink://synthetic#b'), isNull);
    expect(c.profiles.map((p) => p.name), ['a', 'b']);
  });

  test('a locked store still refuses import without any fallback', () async {
    final secrets = MemorySecretStore();
    final store = AppStore(file, secrets: secrets);
    final c = ClientController(core: FakeCore(), store: store);
    addTearDown(c.dispose);
    await c.init();
    expect(await c.importLink('singlink://synthetic#A'), isNull);
    final committed = await file.readAsString();
    secrets.locked = true;
    expect(await c.importLink('singlink://synthetic#A'), isNotNull);
    expect(await c.importLink('singlink://synthetic#B'), isNotNull);
    expect(await file.readAsString(), committed);
    expect(c.profiles, hasLength(1));
  });
}
