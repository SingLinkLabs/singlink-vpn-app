// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
//
// APP-01 recovery paths: restored state without its protected record, and
// app-owned plaintext residue from older versions. Synthetic data only.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/models/profile.dart';
import 'package:singlink_vpn/ui/settings_page.dart';
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

  test('unreadable settings block use until retry succeeds', () async {
    // Legacy plaintext state while the native store is locked.
    final legacy = AppState().toJson()
      ..['version'] = 2
      ..['profiles'] = [
        {'id': 'a', 'link': 'singlink://synthetic#A', 'server': 'x:1'},
      ];
    await file.writeAsString(jsonEncode(legacy));
    final secrets = MemorySecretStore()..locked = true;
    final c = ClientController(
      core: FakeCore(),
      store: AppStore(file, secrets: secrets),
    );
    addTearDown(c.dispose);
    await c.init();
    expect(c.storageBlocked, isTrue);
    expect(c.error?.message, msgStorageBlocked);
    expect(await c.importLink('singlink://synthetic#B'), isNotNull);
    expect(await c.retryStorage(), isFalse);
    expect(await file.readAsString(), contains('singlink://')); // kept for retry
    secrets.locked = false; // device unlocked
    expect(await c.retryStorage(), isTrue);
    expect(c.storageBlocked, isFalse);
    expect(c.profiles.single.link, isEmpty);
    expect(await file.readAsString(), isNot(contains('singlink://')));
  });

  test('confirmed reset recovers from corrupt or unmigratable state', () async {
    final secrets = MemorySecretStore();
    final store = AppStore(file, secrets: secrets);
    final committed = await store.commit(
      AppState(
        profiles: [
          Profile.fromCore('singlink://synthetic#A', {'server': 'x:1'}),
        ],
      ),
    );
    final ref = committed.profiles.single.secretRef;
    await file.writeAsString('{not json'); // corrupt metadata
    final c = ClientController(core: FakeCore(), store: store);
    addTearDown(c.dispose);
    await c.init();
    expect(c.storageBlocked, isTrue);
    expect(await c.resetStorage(), isTrue);
    expect(c.storageBlocked, isFalse);
    expect(c.profiles, isEmpty);
    expect(await file.exists(), isFalse);
    expect(await c.importLink('singlink://synthetic#A'), isNull);
    expect(c.profiles, hasLength(1));
    // The corrupt file could not name its reference: the orphan stays only in
    // the protected store, never in ordinary files.
    expect(secrets.values.containsKey(ref), isTrue);
    expect(await file.readAsString(), isNot(contains('singlink://')));
  });

  testWidgets('blocked settings offer Retry and a confirmed reset', (
    tester,
  ) async {
    late ClientController c;
    await tester.runAsync(() async {
      await file.writeAsString('{not json');
      c = ClientController(
        core: FakeCore(),
        store: AppStore(file, secrets: MemorySecretStore()),
      );
      await c.init();
    });
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(home: SettingsPage(c: c)));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Reset and add servers again'));
    await tester.pumpAndSettle();
    expect(find.text('Reset protected settings'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.storageBlocked, isTrue);
  });
}
