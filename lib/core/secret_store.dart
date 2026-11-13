// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';

/// Secrets never pass through application JSON or diagnostic text.
abstract interface class SecretStore {
  Future<String?> read(String reference);
  Future<void> write(String reference, String value);
  Future<void> delete(String reference);
}

class SecretStoreException implements Exception {
  const SecretStoreException(this.code);
  final String code;
  @override
  String toString() => 'Secret storage unavailable ($code)';
}

String newSecretReference() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return 'slk_v1_${base64UrlEncode(bytes).replaceAll('=', '')}';
}

bool isSecretReference(String value) =>
    RegExp(r'^slk_v1_[A-Za-z0-9_-]{43}$').hasMatch(value);

/// Native adapters: Apple Keychain, Android Keystore + AEAD, Windows DPAPI.
/// A missing/locked adapter fails closed; there is no file/plaintext fallback.
class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore({
    this.channel = const MethodChannel('com.singlinklabs.singlinkvpn/secrets'),
  });
  final MethodChannel channel;

  Future<T?> _call<T>(String method, String reference, [String? value]) async {
    if (!isSecretReference(reference)) {
      throw const SecretStoreException('invalid-reference');
    }
    // UIScene may register an implicit engine's native channel just after
    // Dart starts. Retry only the missing-handler case, with a strict bound.
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        return await channel.invokeMethod<T>(method, {
          'reference': reference,
          if (value != null) 'value': value,
        });
      } on MissingPluginException {
        if (attempt == 19) throw const SecretStoreException('unavailable');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } on PlatformException catch (e) {
        const safeCodes = {
          'locked',
          'unavailable',
          'corrupt',
          'permission',
          'io',
        };
        throw SecretStoreException(
          safeCodes.contains(e.code) ? e.code : 'unavailable',
        );
      }
    }
    throw const SecretStoreException('unavailable');
  }

  @override
  Future<String?> read(String reference) => _call<String>('read', reference);
  @override
  Future<void> write(String reference, String value) async {
    await _call<Object?>('write', reference, value);
  }

  @override
  Future<void> delete(String reference) async {
    await _call<Object?>('delete', reference);
  }
}
