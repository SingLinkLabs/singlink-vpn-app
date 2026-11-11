// Persists servers and settings as one JSON file.
//
// Plugin-free on purpose (shared_preferences on macOS would need CocoaPods or
// SwiftPM). The app is not sandboxed, so on macOS this is
//   ~/Library/Application Support/com.singlinklabs.singlinkvpn/state.json

import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';

const defaultPort = 1080;
const localHost = '127.0.0.1';

/// Returns an error message, or null if [s] is a usable local port.
String? validatePort(String s) {
  final port = int.tryParse(s.trim());
  if (port == null) return '請輸入數字';
  if (port < 1 || port > 65535) return '埠號須介於 1–65535';
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

  /// Server picked in 「選擇地區」 (ignored while [autoSelect] is on).
  String? selectedId;

  /// 「快速連線（自動）」: use the last-used server, else the first one.
  bool autoSelect;

  /// Server of the last successful connection.
  String? lastUsedId;

  /// Local SOCKS port the core listens on (always on 127.0.0.1).
  int port;

  /// 「系統全局代理」: set the macOS system SOCKS proxy while connected.
  bool systemProxy;

  String get listen => '$localHost:$port';

  Map<String, dynamic> toJson() => {
    'version': 2,
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
                .where((p) => p.link.isNotEmpty)
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

class AppStore {
  AppStore(this.file);

  /// Default per-user location (see file header).
  factory AppStore.standard() =>
      AppStore(File('${appSupportDir()}/state.json'));

  final File file;

  Future<AppState> load() async {
    try {
      if (!await file.exists()) return AppState();
      final v = jsonDecode(await file.readAsString());
      return v is Map<String, dynamic> ? AppState.fromJson(v) : AppState();
    } catch (_) {
      // Corrupt or unreadable file: start fresh rather than fail to launch.
      return AppState();
    }
  }

  /// Atomic write (temp file + rename).
  Future<void> save(AppState state) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
