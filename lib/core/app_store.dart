// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// Persists credential references, display metadata and settings as JSON.
//
// Plugin-free on purpose (shared_preferences on macOS would need CocoaPods or
// SwiftPM). The app is not sandboxed, so on macOS this is
//   ~/Library/Application Support/com.singlinklabs.singlinkvpn/state.json

import 'dart:convert';
import 'dart:async';
import 'credential_migration.dart';
import 'secret_store.dart';
import 'dart:io';

import '../models/profile.dart';
import '../models/protected_credential.dart';

const defaultPort = 1080;
const localHost = '127.0.0.1';

/// Returns an error message, or null if [s] is a usable local port.
String? validatePort(String s) {
  final port = int.tryParse(s.trim());
  if (port == null) return 'Enter a number';
  if (port < 1 || port > 65535) return 'The port must be between 1 and 65535';
  return null;
}

class AppState {
  AppState({
    List<Profile>? profiles,
    this.selectedId,
    this.autoSelect = true,
    this.lastUsedId,
    this.port = defaultPort,
    this.systemProxy = true,
  }) : profiles = profiles ?? <Profile>[];

  final List<Profile> profiles;

  /// Server picked in "Choose location" (ignored while [autoSelect] is on).
  String? selectedId;

  /// "Quick connect (auto)": use the last-used server, else the first one.
  bool autoSelect;

  /// Server of the last successful connection.
  String? lastUsedId;

  /// Local SOCKS port the core listens on (always on 127.0.0.1).
  int port;

  /// "System-wide proxy": set the macOS system SOCKS proxy while connected.
  bool systemProxy;

  String get listen => '$localHost:$port';

  AppState copy() => AppState(
    profiles: List.of(profiles),
    selectedId: selectedId,
    autoSelect: autoSelect,
    lastUsedId: lastUsedId,
    port: port,
    systemProxy: systemProxy,
  );

  Map<String, dynamic> toJson() => {
    'version': 3,
    'profiles': profiles.map((p) => p.toJson()).toList(),
    'selectedId': selectedId,
    'autoSelect': autoSelect,
    'lastUsedId': lastUsedId,
    'port': port,
    'systemProxy': systemProxy,
  };

  factory AppState.fromJson(Map<String, dynamic> json) {
    final list = json['profiles'];
    var port = json['port'] is int ? json['port'] as int : 0;
    // v1 stored "listen": "127.0.0.1:1080".
    final listen = json['listen'];
    if (port == 0 && listen is String) {
      port = int.tryParse(listen.substring(listen.lastIndexOf(':') + 1)) ?? 0;
    }
    if (port < 1 || port > 65535) port = defaultPort;
    return AppState(
      profiles: list is List
          ? list
                .whereType<Map<String, dynamic>>()
                .map(Profile.fromJson)
                .where(
                  (p) => p.link.isNotEmpty || isSecretReference(p.secretRef),
                )
                .toList()
          : null,
      selectedId: json['selectedId'] as String?,
      autoSelect: json['autoSelect'] is bool
          ? json['autoSelect'] as bool
          : json['selectedId'] == null,
      lastUsedId: json['lastUsedId'] as String?,
      port: port,
      systemProxy: json['systemProxy'] is bool
          ? json['systemProxy'] as bool
          : true,
    );
  }
}

/// Set by platform start-up code where HOME is not meaningful (Android
/// passes its files directory over a platform channel).
String? appSupportDirOverride;

/// Base directory for the app's files.
String appSupportDir() {
  final override = appSupportDirOverride;
  if (override != null) return override;
  final home = Platform.environment['HOME'];
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null) return '$appData\\SingLinkLabs\\SingLinkVPN';
  }
  if ((Platform.isMacOS || Platform.isIOS) && home != null) {
    return '$home/Library/Application Support/com.singlinklabs.singlinkvpn';
  } else if (home != null) {
    return '$home/.config/singlink_vpn';
  }
  return '${Directory.systemTemp.path}/singlink_vpn';
}

class AppStoreException implements Exception {
  const AppStoreException(this.code);
  final String code;
  @override
  String toString() => 'Protected settings could not be accessed ($code)';
}

class AppStore {
  AppStore(this.file, {this.secrets = const PlatformSecretStore()});
  factory AppStore.standard() =>
      AppStore(File('${appSupportDir()}/state.json'));
  final File file;
  final SecretStore secrets;
  Future<void> _queue = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<AppState> load() => _exclusive(() async {
    cleanupPending = false;
    await _discardStaleMetadataTemp();
    if (!await file.exists()) {
      await _recoverJournal({});
      return AppState();
    }
    Map<String, dynamic> json;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) throw const FormatException();
      json = raw;
    } on FormatException {
      throw const AppStoreException('corrupt');
    } on FileSystemException {
      throw const AppStoreException('io');
    }
    final state = AppState.fromJson(json);
    await _recoverJournal(state.profiles.map((p) => p.secretRef).toSet());
    if ((json['version'] as num? ?? 1) < 3 ||
        state.profiles.any((p) => p.link.isNotEmpty)) {
      // Do not erase legacy credentials until protected write+readback and
      // metadata rename both succeed. A failure is visible, never a fallback.
      return await _save(state);
    }
    await _retryCleanup(json);
    return state;
  });

  Future<ProtectedCredential> readCredential(Profile profile) async {
    if (profile.link.isNotEmpty) {
      return ProtectedCredential(profile.link, profile.acknowledgedWarnings);
    }
    if (!isSecretReference(profile.secretRef)) {
      throw const SecretStoreException('missing');
    }
    final value = await secrets.read(profile.secretRef);
    if (value == null) throw const SecretStoreException('missing');
    try {
      return ProtectedCredential.decode(value);
    } on FormatException {
      throw const SecretStoreException('corrupt');
    }
  }

  Future<AppState> commit(AppState state) {
    final snapshot = state.copy(); // capture before queuing or awaiting
    return _exclusive(() => _save(snapshot));
  }

  Future<void> save(AppState state) async {
    await commit(state);
  }

  File get _journal => File('${file.path}.credential-txn');
  bool cleanupPending = false;

  Set<String> _references(Map<String, dynamic> json) =>
      (json['profiles'] is List ? json['profiles'] as List : const [])
          .whereType<Map>()
          .map((p) => p['secretRef'])
          .whereType<String>()
          .where(isSecretReference)
          .toSet();

  Future<List<String>> _journalReferences() async {
    if (!await _journal.exists()) return [];
    try {
      final value = jsonDecode(await _journal.readAsString());
      if (value is! List ||
          value.any((e) => e is! String || !isSecretReference(e))) {
        throw const AppStoreException('corrupt-transaction');
      }
      return List<String>.from(value);
    } on FormatException {
      throw const AppStoreException('corrupt-transaction');
    }
  }

  Future<void> _writeJournal(List<String> refs) async {
    final tmp = File('${_journal.path}.tmp');
    await tmp.writeAsString(jsonEncode(refs), flush: true);
    await tmp.rename(_journal.path);
  }

  Future<void> _recoverJournal(Set<String> active) async {
    final remaining = <String>[];
    for (final ref in await _journalReferences()) {
      if (active.contains(ref)) continue;
      try {
        await secrets.delete(ref);
      } catch (_) {
        remaining.add(ref);
      }
    }
    if (remaining.isEmpty) {
      if (await _journal.exists()) await _journal.delete();
    } else {
      await _writeJournal(remaining);
      cleanupPending = true;
    }
  }

  /// Older versions wrote complete links to `state.json.tmp` before renaming
  /// it. The rename is the only commit point, so a leftover temp file is never
  /// authoritative: it is app-owned residue from an interrupted write and may
  /// hold a plaintext link. Remove it (regular files only, never follow a
  /// directory or link) before anything else runs.
  Future<void> _discardStaleMetadataTemp() async {
    final tmp = File('${file.path}.tmp');
    try {
      final type = await FileSystemEntity.type(tmp.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await tmp.delete();
      }
    } on FileSystemException {
      // The next metadata write replaces it atomically; never block start-up.
    }
  }

  Future<void> _writeMetadata(Map<String, dynamic> metadata) async {
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(metadata),
        flush: true,
      );
      await tmp.rename(file.path);
    } on FileSystemException {
      throw const AppStoreException('io');
    }
  }

  Future<void> _retryCleanup(Map<String, dynamic> metadata) async {
    final active = _references(metadata);
    final remaining = <String>[];
    final refs = metadata['pendingSecretDeletes'];
    for (final ref
        in refs is List ? refs.whereType<String>() : const <String>[]) {
      if (!isSecretReference(ref) || active.contains(ref)) continue;
      try {
        await secrets.delete(ref);
      } catch (_) {
        remaining.add(ref);
      }
    }
    cleanupPending = cleanupPending || remaining.isNotEmpty;
    if (refs is List && jsonEncode(refs) != jsonEncode(remaining)) {
      metadata['pendingSecretDeletes'] = remaining;
      // The primary transaction already committed. Cleanup bookkeeping failure
      // must not claim that committed profile data was rolled back.
      try {
        await _writeMetadata(metadata);
      } catch (_) {
        cleanupPending = true;
      }
    }
  }

  Future<AppState> _save(AppState state) async {
    cleanupPending = false;
    await file.parent.create(recursive: true);
    Map<String, dynamic> old = {};
    if (await file.exists()) {
      try {
        final value = jsonDecode(await file.readAsString());
        if (value is Map<String, dynamic>) {
          old = value;
        } else {
          throw const AppStoreException('corrupt');
        }
      } on FormatException {
        throw const AppStoreException('corrupt');
      }
    }
    final oldRefs = _references(old);
    final staged = <Profile>[];
    final allocated = await _journalReferences();
    final migration = CredentialMigration(
      secrets,
      onAllocate: (ref) async {
        allocated.add(ref);
        await _writeJournal(allocated);
      },
    );
    try {
      for (final profile in state.profiles) {
        staged.add(await migration.protect(profile));
      }
      final nextRefs = staged.map((p) => p.secretRef).toSet();
      final pending = {
        ...oldRefs.difference(nextRefs),
        if (old['pendingSecretDeletes'] is List)
          ...(old['pendingSecretDeletes'] as List).whereType<String>(),
      };
      final metadata = state.toJson()
        ..['profiles'] = staged.map((p) => p.toJson()).toList()
        ..['pendingSecretDeletes'] = pending.where(isSecretReference).toList();
      await _writeMetadata(metadata);
      try {
        await _recoverJournal(nextRefs);
      } catch (_) {
        cleanupPending = true;
      }
      await _retryCleanup(metadata);
    } catch (_) {
      try {
        await _recoverJournal(oldRefs);
      } catch (_) {
        cleanupPending = true;
      }
      rethrow;
    }
    return AppState(
      profiles: staged,
      selectedId: state.selectedId,
      autoSelect: state.autoSelect,
      lastUsedId: state.lastUsedId,
      port: state.port,
      systemProxy: state.systemProxy,
    );
  }
}
