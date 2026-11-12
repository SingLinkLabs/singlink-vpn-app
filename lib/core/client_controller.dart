// App state + orchestration: servers, connect/disconnect, system proxy,
// 1 s status poll, exit IP, latency, log. The UI only listens to this
// ChangeNotifier.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/core_status.dart';
import '../models/profile.dart';
import 'app_store.dart';
import 'error_messages.dart';
import 'singlink_service.dart';
import 'system_proxy.dart';

enum ConnState { disconnected, connecting, connected, disconnecting }

enum LogLevel { info, success, error }

class LogEntry {
  LogEntry(this.time, this.message, this.level);
  final DateTime time;
  final String message;
  final LogLevel level;
}

const probeUrl = 'https://www.gstatic.com/generate_204';
const probeTimeoutMs = 8000;
const exitIpTimeoutMs = 8000;
const linkScheme = 'singlink://';

class ClientController extends ChangeNotifier {
  ClientController({
    required this.core,
    required this.store,
    this.systemProxy,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final VpnCore core;
  final AppStore store;

  /// Null where system-wide mode is unsupported (non-macOS, tests).
  final SystemProxy? systemProxy;

  /// Injectable for deterministic tests / goldens.
  final DateTime Function() clock;

  AppState _state = AppState();
  bool loaded = false;
  CoreVersion? coreVersion;

  ConnState conn = ConnState.disconnected;
  CoreStatus status = CoreStatus.idle;
  double upRate = 0; // bytes/s
  double downRate = 0;
  DateTime? connectedAt;

  /// Last connection error, shown until dismissed or the next attempt.
  FriendlyError? error;

  /// Connected, but the system proxy could not be (fully) set.
  String? proxyWarning;

  /// Public IP seen through the tunnel; null until known.
  String? exitIp;
  bool exitIpLoading = false;

  /// Latency of the connected server (SingLinkProbe), null until measured.
  int? latencyMs;
  bool measuring = false;

  final List<LogEntry> logs = [];

  String? _connectedId;
  Timer? _poll;
  bool _pollInFlight = false;
  DateTime? _sampleAt;
  int _sampleUp = 0;
  int _sampleDown = 0;
  bool _disposed = false;

  List<Profile> get profiles => List.unmodifiable(_state.profiles);
  int get port => _state.port;
  String get listen => _state.listen;
  bool get systemProxyEnabled => _state.systemProxy;
  bool get systemProxySupported => systemProxy != null;
  bool get autoSelect => _state.autoSelect;
  bool get coreAvailable => core.available;
  bool get busy =>
      conn == ConnState.connecting || conn == ConnState.disconnecting;
  bool get isConnected => conn == ConnState.connected;
  int get totalBytes => status.up + status.down;

  Duration get elapsed {
    final t = connectedAt;
    if (t == null) return Duration.zero;
    final d = clock().difference(t);
    return d.isNegative ? Duration.zero : d;
  }

  Profile? _byId(String? id) {
    if (id == null) return null;
    for (final p in _state.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Server "Quick connect" would use: last used, else the first one.
  Profile? get autoProfile =>
      _byId(_state.lastUsedId) ??
      (_state.profiles.isEmpty ? null : _state.profiles.first);

  /// Server currently in use, or the one the power button would connect to.
  Profile? get target {
    if (conn != ConnState.disconnected) {
      final p = _byId(_connectedId);
      if (p != null) return p;
    }
    if (_state.autoSelect) return autoProfile;
    return _byId(_state.selectedId) ?? autoProfile;
  }

  String? get connectedId => isConnected ? _connectedId : null;

  Future<void> init() async {
    _state = await store.load();
    loaded = true;
    final sp = systemProxy;
    if (sp != null) {
      // A previous run that crashed while connected left the system proxy on.
      final r = await sp.recover();
      if (r.changed.isNotEmpty) {
        log('Restored the system proxy settings left from an unexpected exit');
      }
      if (!r.ok) {
        log('Could not restore the system proxy: ${r.failed}', LogLevel.error);
      }
    }
    if (core.available) {
      log('Core loaded: ${core.location.path}');
      try {
        coreVersion = await core.version();
        log('Core version $coreVersion');
      } catch (e) {
        log('Could not read the core version: $e', LogLevel.error);
      }
    } else {
      log('Core library libsinglink.dylib not found', LogLevel.error);
    }
    _notify();
  }

  void log(String message, [LogLevel level = LogLevel.info]) {
    logs.add(LogEntry(clock(), message, level));
    if (logs.length > 300) logs.removeRange(0, logs.length - 300);
    _notify();
  }

  void dismissError() {
    error = null;
    _notify();
  }

  // ---- servers ------------------------------------------------------------

  /// Parses and stores [link]. Returns null on success.
  Future<FriendlyError?> importLink(String link) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) {
      return const FriendlyError('Paste a server link first.');
    }
    if (!trimmed.toLowerCase().startsWith(linkScheme)) {
      return const FriendlyError(
        'This is not a SingLinkVPN server link. It should start with $linkScheme',
      );
    }
    for (final p in _state.profiles) {
      if (p.link == trimmed) {
        return const FriendlyError('This server is already in your list.');
      }
    }
    final res = await core.parseLink(trimmed);
    if (!res.ok) {
      log('Could not add server: ${res.error}', LogLevel.error);
      return friendlyLinkError(res.error ?? '');
    }
    final profile = res.profile!;
    _state.profiles.add(profile);
    await _save();
    log('Added server "${profile.displayName}"', LogLevel.success);
    return null;
  }

  Future<void> deleteProfile(String id) async {
    final idx = _state.profiles.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    if (conn != ConnState.disconnected && _connectedId == id) {
      await disconnect();
    }
    final removed = _state.profiles.removeAt(idx);
    if (_state.selectedId == id) {
      _state.selectedId = null;
      _state.autoSelect = true;
    }
    if (_state.lastUsedId == id) _state.lastUsedId = null;
    await _save();
    log('Deleted server "${removed.displayName}"');
  }

  /// "Quick connect (auto)".
  Future<void> chooseAuto() => _choose(auto: true, id: null);

  Future<void> chooseServer(String id) => _choose(auto: false, id: id);

  Future<void> _choose({required bool auto, required String? id}) async {
    if (busy) return;
    final before = target?.id;
    _state.autoSelect = auto;
    if (!auto) _state.selectedId = id;
    final wasConnected = isConnected;
    final after = (auto ? autoProfile : _byId(id))?.id;
    await _save();
    // Like a VPN app: picking another location while connected switches.
    if (wasConnected && after != null && after != before) {
      await disconnect();
      await connect();
    }
  }

  // ---- settings -----------------------------------------------------------

  Future<void> setSystemProxy(bool on) async {
    _state.systemProxy = on;
    await _save();
    if (!isConnected) return;
    if (on) {
      await _applySystemProxy();
    } else {
      await _restoreSystemProxy();
      proxyWarning = null;
    }
    _notify();
  }

  /// Only while disconnected. Returns an error message or null.
  Future<String?> setPort(int port) async {
    if (conn != ConnState.disconnected) return 'Disconnect first to change it';
    final err = validatePort('$port');
    if (err != null) return err;
    _state.port = port;
    await _save();
    log('Local port set to $port');
    return null;
  }

  // ---- connection ---------------------------------------------------------

  Future<void> toggle() async {
    if (busy) return;
    if (conn == ConnState.connected) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> connect() async {
    final profile = target;
    if (busy || conn == ConnState.connected) return;
    if (!core.available) {
      error = const FriendlyError(msgCoreMissing);
      _notify();
      return;
    }
    if (profile == null) {
      error = const FriendlyError(
        'No servers yet. Go to Settings → Add server.',
      );
      _notify();
      return;
    }
    conn = ConnState.connecting;
    _connectedId = profile.id;
    error = null;
    proxyWarning = null;
    exitIp = null;
    latencyMs = null;
    _notify();
    log('Connecting to "${profile.displayName}"...');

    final res = await core.start(link: profile.link, listen: _state.listen);
    if (_disposed) return;
    if (!res.ok) {
      conn = ConnState.disconnected;
      _connectedId = null;
      error = friendlyError(res.error);
      log('Connection failed: ${res.error}', LogLevel.error);
      return;
    }

    if (_state.systemProxy) await _applySystemProxy();
    if (_disposed) return;

    conn = ConnState.connected;
    connectedAt = clock();
    status = CoreStatus.idle;
    upRate = downRate = 0;
    _sampleAt = null;
    _state.lastUsedId = profile.id;
    await _save();
    log(
      core.usesLocalProxy
          ? 'Connected to "${profile.displayName}" (local proxy ${_state.listen})'
          : 'Connected to "${profile.displayName}" (device-wide VPN)',
      LogLevel.success,
    );
    _startPolling();
    unawaited(_fetchExitIp());
    unawaited(measureLatency());
  }

  Future<void> disconnect() async {
    if (busy || conn == ConnState.disconnected) return;
    conn = ConnState.disconnecting;
    _stopPolling();
    _notify();
    // Restore first so traffic never points at a closed port.
    await _restoreSystemProxy();
    final res = await core.stop();
    if (_disposed) return;
    if (!res.ok) log('Error while stopping: ${res.error}', LogLevel.error);
    _resetDisconnected();
    log('Disconnected');
  }

  /// Called when the app quits: undo the system proxy and stop the core.
  Future<void> shutdown() async {
    _stopPolling();
    await _restoreSystemProxy();
    if (conn != ConnState.disconnected) {
      await core.stop();
      _resetDisconnected();
    }
  }

  Future<void> _applySystemProxy() async {
    final sp = systemProxy;
    if (sp == null) return;
    final r = await sp.enable(_state.port);
    if (r.ok) {
      proxyWarning = null;
      log('System proxy set (${r.changed.join(', ')})', LogLevel.success);
    } else {
      proxyWarning = systemProxyFailedMessage(_state.port);
      log('Could not set the system proxy: ${r.failed}', LogLevel.error);
    }
  }

  Future<void> _restoreSystemProxy() async {
    final sp = systemProxy;
    if (sp == null || !sp.isApplied) return;
    final r = await sp.restore();
    if (r.ok) {
      log('System proxy settings restored');
    } else {
      log('Could not restore the system proxy: ${r.failed}', LogLevel.error);
    }
  }

  Future<void> _fetchExitIp() async {
    exitIpLoading = true;
    _notify();
    final r = await core.exitIP(timeoutMs: exitIpTimeoutMs);
    if (_disposed) return;
    exitIpLoading = false;
    if (!isConnected) return _notify();
    exitIp = r.ok ? r.ip : null;
    if (!r.ok) log('IP lookup failed: ${r.error}', LogLevel.error);
    _notify();
  }

  /// Measures the connected server with SingLinkProbe. Other servers have no
  /// figure: the core can only probe through the active tunnel.
  Future<void> measureLatency() async {
    if (measuring || !isConnected) return;
    measuring = true;
    _notify();
    final r = await core.probe(probeUrl, timeoutMs: probeTimeoutMs);
    if (_disposed) return;
    measuring = false;
    if (isConnected) latencyMs = r.ok ? r.latencyMs : null;
    if (!r.ok) log('Latency test failed: ${r.error}', LogLevel.error);
    _notify();
  }

  void _resetDisconnected() {
    conn = ConnState.disconnected;
    _connectedId = null;
    connectedAt = null;
    upRate = downRate = 0;
    _sampleAt = null;
    exitIp = null;
    exitIpLoading = false;
    latencyMs = null;
    proxyWarning = null;
    status = CoreStatus.idle;
    _notify();
  }

  void _startPolling() {
    _stopPolling();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollOnce());
    _pollOnce();
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    if (_pollInFlight || conn != ConnState.connected) return;
    _pollInFlight = true;
    try {
      final s = await core.status();
      if (_disposed || conn != ConnState.connected) return;
      final now = clock();
      if (_sampleAt != null) {
        final dt = now.difference(_sampleAt!).inMicroseconds / 1e6;
        if (dt > 0) {
          upRate = (s.up - _sampleUp).clamp(0, 1 << 52) / dt;
          downRate = (s.down - _sampleDown).clamp(0, 1 << 52) / dt;
        }
      }
      _sampleAt = now;
      _sampleUp = s.up;
      _sampleDown = s.down;
      if (s.lastError.isNotEmpty && s.lastError != status.lastError) {
        log('Core: ${s.lastError}', LogLevel.error);
      }
      status = s;
      if (!s.running) {
        _stopPolling();
        await _restoreSystemProxy();
        final err = s.lastError.isEmpty
            ? const FriendlyError(msgDropped)
            : friendlyError(s.lastError);
        _resetDisconnected();
        error = err;
        log(
          'Connection dropped: ${err.detail.isEmpty ? err.message : err.detail}',
          LogLevel.error,
        );
      }
      _notify();
    } catch (e) {
      log('Could not read status: $e', LogLevel.error);
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _save() async {
    try {
      await store.save(_state);
    } catch (e) {
      logs.add(
        LogEntry(clock(), 'Could not save settings: $e', LogLevel.error),
      );
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    super.dispose();
  }
}
