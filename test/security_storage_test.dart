// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/secret_store.dart';
import 'package:singlink_vpn/models/profile.dart';
import 'support/secret_store.dart';

Profile profile(String id) => Profile.fromCore('singlink://synthetic-$id', {
  'name': 'Synthetic $id',
  'server': '127.0.0.1:9',
}, id: id);

class HeldSecrets extends MemorySecretStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String ref, String value) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.write(ref, value);
  }
}

class DeleteFailureSecrets extends MemorySecretStore {
  bool failDelete = false;
  @override
  Future<void> delete(String ref) async {
    if (failDelete) throw const SecretStoreException('locked');
    await super.delete(ref);
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('synthetic-store-');
    file = File('${dir.path}/state.json');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  Future<String> legacy() async {
    final data = AppState(profiles: [profile('a')]).toJson()..['version'] = 2;
    (data['profiles'] as List).single['link'] = profile('a').link;
    final raw = jsonEncode(data);
    await file.writeAsString(raw);
    return raw;
  }

  test(
    'legacy migration commits metadata only after protected readback',
    () async {
      final secrets = MemorySecretStore();
      await legacy();
      final store = AppStore(file, secrets: secrets);
      final state = await store.load();
      expect(state.profiles.single.link, isEmpty);
      expect(
        (await store.readCredential(state.profiles.single)).link,
        profile('a').link,
      );
      expect(await file.readAsString(), isNot(contains('singlink://')));
      expect(await File('${file.path}.tmp').exists(), isFalse);
      expect(await File('${file.path}.credential-txn').exists(), isFalse);
    },
  );
  test('locked migration preserves legacy file and never falls back', () async {
    final before = await legacy();
    final secrets = MemorySecretStore()..locked = true;
    final store = AppStore(file, secrets: secrets);
    await expectLater(store.load(), throwsA(isA<SecretStoreException>()));
    expect(await file.readAsString(), before);
    expect(secrets.values, isEmpty);
    secrets.locked = false;
    expect((await store.load()).profiles.single.link, isEmpty);
  });
  test(
    'readback failure rolls back staged reference without erasing legacy',
    () async {
      final before = await legacy();
      final secrets = MemorySecretStore()..corruptReadback = true;
      await expectLater(
        AppStore(file, secrets: secrets).load(),
        throwsA(isA<SecretStoreException>()),
      );
      expect(await file.readAsString(), before);
      expect(secrets.values, isEmpty);
    },
  );
  test(
    'metadata write failure preserves old file and removes staged secret',
    () async {
      final before = await legacy();
      final secrets = MemorySecretStore();
      await Directory('${file.path}.tmp').create();
      await expectLater(
        AppStore(file, secrets: secrets).load(),
        throwsA(isA<AppStoreException>()),
      );
      expect(await file.readAsString(), before);
      expect(secrets.values, isEmpty);
    },
  );
  test('mixed legacy bookkeeping never writes a new plaintext temp', () async {
    await legacy();
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    json['pendingSecretDeletes'] = [newSecretReference()];
    await file.writeAsString(jsonEncode(json));
    final before = await file.readAsString();
    final secrets = MemorySecretStore()..locked = true;
    await expectLater(
      AppStore(file, secrets: secrets).load(),
      throwsA(isA<SecretStoreException>()),
    );
    expect(await file.readAsString(), before);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });
  test('missing protected record fails closed', () async {
    final secrets = MemorySecretStore();
    final store = AppStore(file, secrets: secrets);
    final state = await store.commit(AppState(profiles: [profile('a')]));
    secrets.values.clear();
    await expectLater(
      store.readCredential(state.profiles.single),
      throwsA(isA<SecretStoreException>()),
    );
    expect(await file.readAsString(), isNot(contains('singlink://')));
  });
  test('snapshot is immutable across an awaiting protected write', () async {
    final secrets = HeldSecrets();
    final store = AppStore(file, secrets: secrets);
    final state = AppState(profiles: [profile('a')]);
    final commit = store.commit(state);
    await secrets.entered.future;
    state.profiles.add(profile('b'));
    secrets.release.complete();
    expect((await commit).profiles.map((p) => p.id), ['a']);
    expect((await store.load()).profiles.map((p) => p.id), ['a']);
  });
  test(
    'deleted secret cleanup retries only after metadata is committed',
    () async {
      final secrets = DeleteFailureSecrets();
      final store = AppStore(file, secrets: secrets);
      final state = await store.commit(AppState(profiles: [profile('a')]));
      final ref = state.profiles.single.secretRef;
      secrets.failDelete = true;
      await store.commit(AppState());
      expect(
        (jsonDecode(await file.readAsString())['profiles'] as List),
        isEmpty,
      );
      expect(store.cleanupPending, isTrue);
      expect(secrets.values.containsKey(ref), isTrue);
      secrets.failDelete = false;
      await store.load();
      expect(secrets.values, isEmpty);
      expect(store.cleanupPending, isFalse);
    },
  );
  test(
    'crashed first transaction removes only recorded orphan references',
    () async {
      final secrets = MemorySecretStore();
      final orphan = newSecretReference();
      final other = newSecretReference();
      secrets.values.addAll({
        orphan: 'synthetic orphan',
        other: 'unrelated synthetic item',
      });
      await File(
        '${file.path}.credential-txn',
      ).writeAsString(jsonEncode([orphan]));
      await AppStore(file, secrets: secrets).load();
      expect(secrets.values.keys, [other]);
    },
  );
  test('post-commit journal recovery retains active credential', () async {
    final secrets = MemorySecretStore();
    final store = AppStore(file, secrets: secrets);
    final state = await store.commit(AppState(profiles: [profile('a')]));
    final ref = state.profiles.single.secretRef;
    await File('${file.path}.credential-txn').writeAsString(jsonEncode([ref]));
    await store.load();
    expect(secrets.values.containsKey(ref), isTrue);
  });
}
