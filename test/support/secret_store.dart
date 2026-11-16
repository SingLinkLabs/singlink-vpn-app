// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/secret_store.dart';

/// Test-only fixture; never selected by production storage.
class MemorySecretStore implements SecretStore {
  final values = <String, String>{};
  bool locked = false;
  bool corruptReadback = false;
  void _check() {
    if (locked) throw const SecretStoreException('locked');
  }

  @override
  Future<String?> read(String ref) async {
    _check();
    return corruptReadback && values.containsKey(ref) ? 'corrupt' : values[ref];
  }

  @override
  Future<void> write(String ref, String value) async {
    _check();
    values[ref] = value;
  }

  @override
  Future<void> delete(String ref) async {
    _check();
    values.remove(ref);
  }
}

class TestAppStore extends AppStore {
  TestAppStore(super.file, {SecretStore? secrets})
    : super(secrets: secrets ?? MemorySecretStore());
}
