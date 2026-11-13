// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0

import '../models/profile.dart';
import '../models/protected_credential.dart';
import 'secret_store.dart';

/// Stages immutable credential references before the metadata transaction.
/// Failure leaves the previous ordinary state untouched. An interrupted
/// transaction may leave an orphan protected item, never a plaintext backup.
class CredentialMigration {
  const CredentialMigration(this.secrets, {this.onAllocate});
  final SecretStore secrets;
  final Future<void> Function(String)? onAllocate;

  Future<Profile> protect(Profile profile) async {
    if (profile.link.isEmpty) {
      if (!isSecretReference(profile.secretRef)) {
        throw const SecretStoreException('missing');
      }
      return profile;
    }
    final encoded = ProtectedCredential(
      profile.link,
      profile.acknowledgedWarnings,
    ).encode();
    var ref = profile.secretRef;
    if (!isSecretReference(ref) || await secrets.read(ref) != encoded) {
      ref = newSecretReference();
      await onAllocate?.call(ref);
      await secrets.write(ref, encoded);
    }
    if (await secrets.read(ref) != encoded) {
      throw const SecretStoreException('verification');
    }
    return profile.withCredential(reference: ref);
  }
}
