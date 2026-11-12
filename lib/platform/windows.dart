// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// Windows: system proxy through the per-user WinINet settings in the registry
// (HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings), the
// same switches as Settings > Network & Internet > Proxy.
//
// While connected:
//   ProxyEnable   = 1                            (REG_DWORD)
//   ProxyServer   = 127.0.0.1:<port>             (REG_SZ; HTTP proxy for all
//                                                 schemes, see below)
//   ProxyOverride = <local>;localhost;127.*;...  (REG_SZ)
//   AutoConfigURL is removed (a PAC script would take precedence)
//
// The previous values, including which ones did not exist, are journaled
// before anything is changed and written back exactly afterwards. Every
// registry access goes through `reg.exe` and a [ProcessRunner], so the logic
// is unit-tested on any OS with a fake runner. After each change running
// programs are told to re-read the settings with InternetSetOptionW
// (INTERNET_OPTION_SETTINGS_CHANGED, INTERNET_OPTION_REFRESH).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../core/system_proxy.dart';

const internetSettingsKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

const proxyEnableValue = 'ProxyEnable';
const proxyServerValue = 'ProxyServer';
const proxyOverrideValue = 'ProxyOverride';
const autoConfigUrlValue = 'AutoConfigURL';

/// The values this class changes, in the order they are restored (proxy off
/// first, PAC back last).
const managedProxyValues = [
  proxyEnableValue,
  proxyServerValue,
  proxyOverrideValue,
  autoConfigUrlValue,
];

/// Addresses that never go through the tunnel. `<local>` means host names
/// without a dot.
const defaultProxyOverride = '<local>;localhost;127.*;10.*;172.16.*;192.168.*';

/// One registry value as printed by `reg query`.
class RegValue {
  const RegValue(this.type, this.data);

  /// `REG_SZ`, `REG_DWORD`, ...
  final String type;

  /// As `reg query` prints it (REG_DWORD in hex, e.g. `0x1`).
  final String data;

  Map<String, dynamic> toJson() => {'type': type, 'data': data};

  static RegValue? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final type = j['type'];
    final data = j['data'];
    if (type is! String || data is! String || !type.startsWith('REG_')) {
      return null;
    }
    return RegValue(type, data);
  }

  /// The `/d` argument for `reg add`. REG_DWORD/REG_QWORD are printed in hex
  /// by `reg query` but written in decimal.
  String get addData {
    if (type == 'REG_DWORD' || type == 'REG_QWORD') {
      final n = int.tryParse(data);
      if (n != null) return '$n';
    }
    return data;
  }

  @override
  bool operator ==(Object other) =>
      other is RegValue && other.type == type && other.data == data;

  @override
  int get hashCode => Object.hash(type, data);

  @override
  String toString() => '$type $data';
}

final _valueLine = RegExp(r'^ {4}(.+?) {4}(REG_[A-Z0-9_]+)(?: {4}(.*))?$');

/// Parses the output of `reg query <key>`:
/// ```
///
/// HKEY_CURRENT_USER\Software\...\Internet Settings
///     ProxyEnable    REG_DWORD    0x0
///     ProxyServer    REG_SZ    10.0.0.2:3128
///
/// HKEY_CURRENT_USER\Software\...\Internet Settings\Connections
/// ```
/// Only the values directly under the key are returned (sub-key lines are
/// not indented). Data is kept verbatim (no trimming).
Map<String, RegValue> parseRegQuery(String out) {
  final values = <String, RegValue>{};
  for (final line in const LineSplitter().convert(out)) {
    final m = _valueLine.firstMatch(line);
    if (m == null) continue;
    values[m[1]!] = RegValue(m[2]!, m[3] ?? '');
  }
  return values;
}

/// Tells running programs that the WinINet proxy settings changed. Returns
/// false if the notification could not be sent (the settings are still
/// written; programs then pick them up when they next start).
typedef ProxySettingsNotifier = bool Function();

typedef _InternetSetOptionC =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32);
typedef _InternetSetOptionDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int);

const _internetOptionSettingsChanged = 39;
const _internetOptionRefresh = 37;

/// InternetSetOptionW(NULL, INTERNET_OPTION_SETTINGS_CHANGED / _REFRESH).
/// Windows only.
bool notifyWinInetSettingsChanged() {
  try {
    final setOption = DynamicLibrary.open('wininet.dll')
        .lookupFunction<_InternetSetOptionC, _InternetSetOptionDart>(
          'InternetSetOptionW',
        );
    final changed = setOption(
      nullptr,
      _internetOptionSettingsChanged,
      nullptr,
      0,
    );
    final refreshed = setOption(nullptr, _internetOptionRefresh, nullptr, 0);
    return changed != 0 && refreshed != 0;
  } catch (_) {
    return false;
  }
}

/// Where the previous registry values are kept while the proxy is applied.
/// A value name mapped to null did not exist before.
class WindowsProxyJournal {
  WindowsProxyJournal(this.file);
  final File file;

  Future<Map<String, RegValue?>> load() async {
    try {
      if (!await file.exists()) return {};
      final v = jsonDecode(await file.readAsString());
      if (v is! Map<String, dynamic> || v['kind'] != 'wininet') return {};
      final values = v['values'];
      if (values is! Map<String, dynamic>) return {};
      return {
        for (final e in values.entries)
          if (managedProxyValues.contains(e.key) &&
              (e.value == null || RegValue.fromJson(e.value) != null))
            e.key: RegValue.fromJson(e.value),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Map<String, RegValue?> saved) async {
    if (saved.isEmpty) return clear();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'kind': 'wininet',
        'key': internetSettingsKey,
        'values': {for (final e in saved.entries) e.key: e.value?.toJson()},
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Windows implementation of [SystemProxy] (per-user WinINet settings).
///
/// [ProxyResult.changed] lists the registry values written or deleted, and
/// [ProxyResult.failed] maps a value name (or `*` when the key could not be
/// read) to the error.
/// How [WindowsSystemProxy] announces the local port in `ProxyServer`.
enum WindowsProxyMode {
  /// `127.0.0.1:<port>`: HTTP proxy (CONNECT for HTTPS) for every scheme.
  http,

  /// `socks=socks5://127.0.0.1:<port>`: understood by Chromium only.
  socks5,
}

class WindowsSystemProxy implements SystemProxy {
  WindowsSystemProxy({
    required this.runner,
    this.journal,
    this.notify,
    this.regExe = 'reg.exe',
    this.host = '127.0.0.1',
    this.proxyOverride = defaultProxyOverride,
    this.mode = WindowsProxyMode.http,
  });

  final ProcessRunner runner;
  final WindowsProxyJournal? journal;
  final ProxySettingsNotifier? notify;
  final String regExe;
  final String host;
  final String proxyOverride;

  /// How the local port is announced. WinINet (and Edge/Chrome reading a
  /// scheme-less `socks=` entry) only speak SOCKS v4, which the core does not
  /// serve; the core's local port also speaks HTTP proxy, which every
  /// WinINet client supports, so [WindowsProxyMode.http] is the default.
  final WindowsProxyMode mode;

  /// The ProxyServer value written by [enable].
  String proxyServerFor(int port) => switch (mode) {
    WindowsProxyMode.http => '$host:$port',
    WindowsProxyMode.socks5 => 'socks=socks5://$host:$port',
  };

  /// Original value of every registry value we changed (null: it did not
  /// exist). Entries are removed once restored.
  final Map<String, RegValue?> _saved = {};

  /// Whether the last notification to running programs failed.
  bool notifyFailed = false;

  Future<void> _queue = Future.value();

  @override
  bool get isApplied => _saved.isNotEmpty;
  Map<String, RegValue?> get saved => Map.unmodifiable(_saved);

  Future<T> _locked<T>(Future<T> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  String _err(RunResult r) {
    final s = '${r.stderr}${r.stdout}'.trim();
    return s.isEmpty ? 'exit ${r.exitCode}' : s;
  }

  Future<RunResult> _query() =>
      runner.run(regExe, ['query', internetSettingsKey]);

  Future<RunResult> _add(String name, RegValue v) => runner.run(regExe, [
    'add',
    internetSettingsKey,
    '/v',
    name,
    '/t',
    v.type,
    '/d',
    v.addData,
    '/f',
  ]);

  Future<RunResult> _delete(String name) =>
      runner.run(regExe, ['delete', internetSettingsKey, '/v', name, '/f']);

  void _notify() {
    final n = notify;
    if (n != null) notifyFailed = !n();
  }

  /// Points WinINet at the local port, saving the previous values first.
  /// Partial failure keeps what was written (and remembered for [restore]).
  @override
  Future<ProxyResult> enable(int port) => _locked(() async {
    final q = await _query();
    if (!q.ok) return ProxyResult(failed: {'*': _err(q)});
    final current = parseRegQuery(q.stdout);

    // Re-enabling (e.g. after a port change) must not overwrite the
    // original values with our own.
    var journalChanged = false;
    for (final name in managedProxyValues) {
      if (!_saved.containsKey(name)) {
        _saved[name] = current[name];
        journalChanged = true;
      }
    }
    if (journalChanged) await journal?.save(_saved);

    final changed = <String>[];
    final failed = <String, String>{};
    final writes = <String, RegValue>{
      proxyServerValue: RegValue('REG_SZ', proxyServerFor(port)),
      proxyOverrideValue: RegValue('REG_SZ', proxyOverride),
      proxyEnableValue: const RegValue('REG_DWORD', '1'),
    };
    for (final e in writes.entries) {
      final r = await _add(e.key, e.value);
      if (r.ok) {
        changed.add(e.key);
      } else {
        failed[e.key] = _err(r);
      }
    }
    // A PAC script takes precedence over the manual proxy.
    if (current.containsKey(autoConfigUrlValue)) {
      final r = await _delete(autoConfigUrlValue);
      if (r.ok) {
        changed.add(autoConfigUrlValue);
      } else {
        failed[autoConfigUrlValue] = _err(r);
      }
    }
    if (changed.isNotEmpty) _notify();
    return ProxyResult(changed: changed, failed: failed);
  });

  /// Writes every saved value back (deleting the ones that did not exist).
  /// Values that fail stay remembered (and journaled) for a retry.
  @override
  Future<ProxyResult> restore() => _locked(_restoreSaved);

  /// Restores values left in the journal by a previous run that did not
  /// shut down cleanly. Call once at startup.
  @override
  Future<ProxyResult> recover() => _locked(() async {
    final j = journal;
    if (j == null) return const ProxyResult();
    final pending = await j.load();
    for (final e in pending.entries) {
      _saved.putIfAbsent(e.key, () => e.value);
    }
    if (_saved.isEmpty) return const ProxyResult();
    return _restoreSaved();
  });

  Future<ProxyResult> _restoreSaved() async {
    if (_saved.isEmpty) return const ProxyResult();
    // Knowing what exists avoids deleting a value that is already gone
    // (reg.exe reports that as an error). If the key cannot be read, try
    // the deletes anyway.
    final q = await _query();
    final current = q.ok ? parseRegQuery(q.stdout) : null;

    final changed = <String>[];
    final failed = <String, String>{};
    for (final name in managedProxyValues) {
      if (!_saved.containsKey(name)) continue;
      final prev = _saved[name];
      RunResult? r;
      if (prev != null) {
        r = await _add(name, prev);
      } else if (current == null || current.containsKey(name)) {
        r = await _delete(name);
      }
      if (r == null || r.ok) {
        changed.add(name);
        _saved.remove(name);
      } else {
        failed[name] = _err(r);
      }
    }
    await journal?.save(_saved);
    if (changed.isNotEmpty) _notify();
    return ProxyResult(changed: changed, failed: failed);
  }
}

/// `%SystemRoot%\System32\reg.exe` (an absolute path, so a `reg.exe` in the
/// working directory is never picked up).
String windowsRegExe([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final root = env['SystemRoot'] ?? env['SYSTEMROOT'] ?? r'C:\Windows';
  return '$root\\System32\\reg.exe';
}

SystemProxy? createWindowsSystemProxy(String appSupportDir) =>
    WindowsSystemProxy(
      runner: const IoProcessRunner(),
      journal: WindowsProxyJournal(
        File('$appSupportDir\\system-proxy-restore.json'),
      ),
      notify: notifyWinInetSettingsChanged,
      regExe: windowsRegExe(),
    );
