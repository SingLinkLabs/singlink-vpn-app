// macOS "system-wide" mode: points the SOCKS proxy of every enabled network
// service at the core's local port with /usr/sbin/networksetup, and puts the
// previous settings back afterwards.
//
// All command execution goes through [ProcessRunner] so the logic can be
// unit-tested with a fake runner; nothing here touches the real network
// configuration unless an [IoProcessRunner] is passed in.
//
// Before anything is changed, the previous settings are written to a journal
// file. If the app is killed while connected, the next launch restores from
// the journal (see [SystemProxyManager.recover]).

import 'dart:convert';
import 'dart:io';

/// Result of running one command.
class RunResult {
  const RunResult(this.exitCode, [this.stdout = '', this.stderr = '']);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

abstract class ProcessRunner {
  Future<RunResult> run(String executable, List<String> args);
}

/// Runs real processes. Only used by the app itself, never by tests.
class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();

  @override
  Future<RunResult> run(String executable, List<String> args) async {
    try {
      final r = await Process.run(executable, args);
      return RunResult(r.exitCode, '${r.stdout}', '${r.stderr}');
    } on ProcessException catch (e) {
      return RunResult(127, '', e.toString());
    }
  }
}

const networksetup = '/usr/sbin/networksetup';

/// One service's SOCKS proxy settings as reported by
/// `networksetup -getsocksfirewallproxy <service>`.
class SocksSetting {
  const SocksSetting({
    required this.enabled,
    required this.server,
    required this.port,
    this.authenticated = false,
  });

  final bool enabled;
  final String server;
  final int port;
  final bool authenticated;

  /// Parses
  /// ```
  /// Enabled: No
  /// Server: 127.0.0.1
  /// Port: 7897
  /// Authenticated Proxy Enabled: 0
  /// ```
  /// Returns null when the output does not look like that.
  static SocksSetting? parse(String out) {
    final fields = <String, String>{};
    for (final line in const LineSplitter().convert(out)) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      fields[line.substring(0, i).trim().toLowerCase()] = line
          .substring(i + 1)
          .trim();
    }
    final enabled = fields['enabled'];
    if (enabled == null) return null;
    return SocksSetting(
      enabled: enabled.toLowerCase() == 'yes',
      server: fields['server'] ?? '',
      port: int.tryParse(fields['port'] ?? '') ?? 0,
      authenticated: (fields['authenticated proxy enabled'] ?? '0') == '1',
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'server': server,
    'port': port,
    'authenticated': authenticated,
  };

  factory SocksSetting.fromJson(Map<String, dynamic> j) => SocksSetting(
    enabled: j['enabled'] == true,
    server: '${j['server'] ?? ''}',
    port: j['port'] is int ? j['port'] as int : 0,
    authenticated: j['authenticated'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is SocksSetting &&
      other.enabled == enabled &&
      other.server == server &&
      other.port == port &&
      other.authenticated == authenticated;

  @override
  int get hashCode => Object.hash(enabled, server, port, authenticated);

  @override
  String toString() =>
      'SocksSetting(${enabled ? 'on' : 'off'} $server:$port'
      '${authenticated ? ' auth' : ''})';
}

/// Parses `networksetup -listallnetworkservices`: skips the legend line and
/// services marked disabled with a leading `*`.
List<String> parseEnabledServices(String out) {
  final services = <String>[];
  for (final raw in const LineSplitter().convert(out)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('*')) continue;
    if (line.startsWith('An asterisk')) continue;
    services.add(line);
  }
  return services;
}

/// Where the previous settings are kept while the system proxy is applied.
class ProxyJournal {
  ProxyJournal(this.file);
  final File file;

  Future<Map<String, SocksSetting>> load() async {
    try {
      if (!await file.exists()) return {};
      final v = jsonDecode(await file.readAsString());
      if (v is! Map<String, dynamic>) return {};
      final services = v['services'];
      if (services is! Map<String, dynamic>) return {};
      return {
        for (final e in services.entries)
          if (e.value is Map<String, dynamic>)
            e.key: SocksSetting.fromJson(e.value as Map<String, dynamic>),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Map<String, SocksSetting> saved) async {
    if (saved.isEmpty) return clear();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'services': {for (final e in saved.entries) e.key: e.value.toJson()},
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

/// Outcome of [SystemProxyManager.enable] / [SystemProxyManager.restore].
class ProxyResult {
  const ProxyResult({this.changed = const [], this.failed = const {}});

  /// Services handled successfully.
  final List<String> changed;

  /// Service (or `*` for the service listing) -> error text.
  final Map<String, String> failed;

  bool get ok => failed.isEmpty;

  @override
  String toString() => 'ProxyResult(changed: $changed, failed: $failed)';
}

/// Points the operating system's proxy settings at the local SOCKS5 port and
/// puts the previous settings back. One implementation per desktop OS:
/// [SystemProxyManager] (macOS, networksetup) and the Windows one in
/// lib/platform/windows.dart.
abstract class SystemProxy {
  /// Whether settings are currently changed by us (and need [restore]).
  bool get isApplied;

  /// Sets the system proxy to the local SOCKS5 port.
  Future<ProxyResult> enable(int port);

  /// Puts back what [enable] replaced.
  Future<ProxyResult> restore();

  /// Restores settings left behind by a previous run that was killed.
  Future<ProxyResult> recover();
}

/// macOS implementation using `networksetup`.
class SystemProxyManager implements SystemProxy {
  SystemProxyManager({
    required this.runner,
    this.journal,
    this.host = '127.0.0.1',
  });

  final ProcessRunner runner;
  final ProxyJournal? journal;
  final String host;

  /// Previous settings of every service we changed (or tried to change).
  final Map<String, SocksSetting> _saved = {};

  Future<void> _queue = Future.value();

  @override
  bool get isApplied => _saved.isNotEmpty;
  Map<String, SocksSetting> get saved => Map.unmodifiable(_saved);

  /// Serialises enable/restore so a quick connect → disconnect can't interleave.
  Future<T> _locked<T>(Future<T> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<RunResult> _ns(List<String> args) => runner.run(networksetup, args);

  String _err(RunResult r) {
    final s = '${r.stderr}${r.stdout}'.trim();
    return s.isEmpty ? 'exit ${r.exitCode}' : s;
  }

  /// Sets SOCKS proxy `host:port` on every enabled service, saving what was
  /// there before. Partial failure leaves the successful services applied
  /// (and remembered for [restore]).
  @override
  Future<ProxyResult> enable(int port) => _locked(() async {
    final list = await _ns(['-listallnetworkservices']);
    if (!list.ok) {
      return ProxyResult(failed: {'*': _err(list)});
    }
    final services = parseEnabledServices(list.stdout);
    if (services.isEmpty) {
      return const ProxyResult(failed: {'*': 'no enabled network service'});
    }

    final changed = <String>[];
    final failed = <String, String>{};
    for (final svc in services) {
      // Re-enabling (e.g. after a port change) must not overwrite the
      // original settings with our own.
      if (!_saved.containsKey(svc)) {
        final get = await _ns(['-getsocksfirewallproxy', svc]);
        final prev = get.ok ? SocksSetting.parse(get.stdout) : null;
        if (prev == null) {
          failed[svc] = get.ok ? 'unreadable settings' : _err(get);
          continue;
        }
        if (prev.authenticated && prev.enabled) {
          // Its password cannot be read back, so we could not restore it.
          failed[svc] = 'existing authenticated SOCKS proxy left unchanged';
          continue;
        }
        _saved[svc] = prev;
        await journal?.save(_saved);
      }

      final set = await _ns(['-setsocksfirewallproxy', svc, host, '$port']);
      if (!set.ok) {
        failed[svc] = _err(set);
        continue;
      }
      final on = await _ns(['-setsocksfirewallproxystate', svc, 'on']);
      if (!on.ok) {
        failed[svc] = _err(on);
        continue;
      }
      changed.add(svc);
    }
    return ProxyResult(changed: changed, failed: failed);
  });

  /// Puts back every saved service's previous settings. Services that fail
  /// stay remembered (and journaled) so a later call can retry.
  @override
  Future<ProxyResult> restore() => _locked(() => _restoreSaved());

  /// Restores settings left in the journal by a previous run that did not
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
    final changed = <String>[];
    final failed = <String, String>{};
    for (final e in Map.of(_saved).entries) {
      final err = await _apply(e.key, e.value);
      if (err == null) {
        changed.add(e.key);
        _saved.remove(e.key);
      } else {
        failed[e.key] = err;
      }
    }
    await journal?.save(_saved);
    return ProxyResult(changed: changed, failed: failed);
  }

  /// Writes [s] back to [svc]. An empty previous server cannot be written
  /// back with networksetup, so only the state is restored in that case.
  Future<String?> _apply(String svc, SocksSetting s) async {
    if (s.server.isNotEmpty) {
      final set = await _ns([
        '-setsocksfirewallproxy',
        svc,
        s.server,
        '${s.port}',
      ]);
      if (!set.ok) return _err(set);
    }
    final st = await _ns([
      '-setsocksfirewallproxystate',
      svc,
      s.enabled ? 'on' : 'off',
    ]);
    if (!st.ok) return _err(st);
    return null;
  }
}
