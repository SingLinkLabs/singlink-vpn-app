// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// App state + orchestration: servers, connect/disconnect, system proxy,
// 1 s status poll, exit IP, latency, log. The UI only listens to this
// ChangeNotifier.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/core_status.dart';
import '../models/profile.dart';
import '../models/security_warning.dart';
import 'secret_store.dart';
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
const msgStorageBlocked =
    'Protected settings are unavailable. Unlock this device and tap Retry in '
    'Settings, or reset them there and add your servers again.';

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

  /// App F-01: login the core generated for this session's local proxy port,
  /// in memory only (never logged or saved). Null while disconnected and in
  /// system-proxy mode, where the port has no password.
  ProxyCredentials? proxyCredentials;

  /// Whether the running session's local port requires [proxyCredentials].
  bool? _sessionAuth;
  bool measuring = false;

  final List<LogEntry> logs = [];

  String? _connectedId;
  Timer? _poll;
  bool _pollInFlight = false;
  DateTime? _sampleAt;
  int _sampleUp = 0;
  int _sampleDown = 0;
  bool _disposed = false;
  bool _shutdown = false;
  bool _storageBlocked = false;
  int _generation = 0;
  int? _nativeOwner;
  Future<void>? _connectCompletion;
  Future<void> _stateQueue = Future<void>.value();
  Future<void> _proxyQueue = Future<void>.value();
  Future<void>? _shutdownCompletion;

  bool _current(int generation) =>
      !_disposed && !_shutdown && generation == _generation;

  List<Profile> get profiles => List.unmodifiable(_state.profiles);
  int get port => _state.port;
  String get listen => _state.listen;
  bool get systemProxyEnabled => _state.systemProxy;
  bool get systemProxySupported => systemProxy != null;

  /// App F-01: the local port gets a per-session username and password
  /// unless the OS system proxy uses it (OS proxy settings cannot carry
  /// credentials). Device-wide VPN cores have no local port.
  bool get localProxyNeedsAuth =>
      core.usesLocalProxy && !(systemProxySupported && _state.systemProxy);

  /// True while connected with a local port that has no password: every
  /// process and user account on this computer can use it.
  bool get localProxyOpen =>
      isConnected && core.usesLocalProxy && _sessionAuth == false;

  /// iOS "Block traffic outside the VPN" (App F-04).
  bool get blockOutsideTunnel => _state.blockOutsideTunnel;
  bool get blockOutsideTunnelSupported {
    final c = core;
    return c is RoutingPolicyCore &&
        (c as RoutingPolicyCore).supportsBlockOutsideTunnel;
  }

  /// Android: the OS can start the VPN (always-on), see [SystemStartCore].
  bool get systemStartSupported => core is SystemStartCore;
  bool get autoSelect => _state.autoSelect;
  bool get coreAvailable => core.available;
  bool get busy =>
      conn == ConnState.connecting || conn == ConnState.disconnecting;
  bool get isConnected => conn == ConnState.connected;

  /// Headline and subtitle for the connected state, worded for what this
  /// platform actually routes (A-H03): a device-wide VPN on mobile; on
  /// desktop only apps that use the system proxy (or the local proxy port).
  (String, String) get connectedSummary {
    if (!core.usesLocalProxy) {
      // App F-04: routed while connected; no claim of leak-proof protection
      // (that needs Android's "Block connections without VPN" or the iOS
      // option, and is not something the app can verify from here).
      return (
        'Connected',
        'Device traffic goes through SingLinkVPN while connected',
      );
    }
    if (systemProxySupported && systemProxyEnabled && proxyWarning == null) {
      return ('Protected', 'System proxy on — apps using it are protected');
    }
    return ('Connected', 'Apps set to use proxy $listen are protected');
  }

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
    try {
      _state = await store.load();
    } catch (_) {
      _storageBlocked = true;
      error = const FriendlyError(msgStorageBlocked);
    }
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
    if (!_storageBlocked) unawaited(_hydrateDetails());
    final c = core;
    if (c is SystemStartCore) {
      final starts = c as SystemStartCore;
      _systemStarts = starts.systemStartRequests.listen(
        (_) => unawaited(_handleSystemStart()),
      );
      unawaited(_handleSystemStart());
    }
  }

  StreamSubscription<void>? _systemStarts;

  /// Android always-on VPN (App F-04): the OS started the VPN service without
  /// the app. Connect the saved profile exactly like the power button would
  /// (protected credential, warning re-check); if that cannot happen, tell
  /// the platform so it takes its placeholder service down.
  Future<void> _handleSystemStart() async {
    final c = core;
    if (c is! SystemStartCore) return;
    final starts = c as SystemStartCore;
    if (!await starts.takeSystemStart()) return;
    if (_disposed || _shutdown) return;
    if (isConnected) return; // the running session satisfies it
    if (busy) {
      // A user connect or disconnect is in progress and decides the state;
      // release the placeholder (Android keeps it if a session is set up).
      await starts.systemStartFailed();
      return;
    }
    log('Started by Android (always-on VPN)');
    await connect();
    if (!isConnected) await starts.systemStartFailed();
  }

  /// F-07: connection details are no longer kept in the settings file. Derive
  /// them for display (server host, unnamed profiles) from each protected
  /// link, in memory only. Profiles whose record cannot be read keep showing
  /// their name; connecting them reports the problem.
  Future<void> _hydrateDetails() async {
    if (!core.available) return;
    for (final p in List.of(_state.profiles)) {
      if (_disposed || _shutdown) return;
      if (p.server.isNotEmpty) continue;
      try {
        final credential = await store.readCredential(p);
        final parsed = await core.parseLink(credential.link);
        final details = parsed.profile;
        if (!parsed.ok || details == null) continue;
        await _withState(() async {
          final i = _state.profiles.indexWhere(
            (q) => q.id == p.id && q.secretRef == p.secretRef,
          );
          if (i < 0 || _state.profiles[i].server.isNotEmpty) return;
          _state.profiles[i] = _state.profiles[i].withDetails(
            server: details.server,
            sni: details.sni,
            subject: details.subject,
          );
        });
      } catch (_) {
        // Locked or missing record: shown by name; connect explains.
      }
    }
    _notify();
  }

  /// Settings could not be loaded; connecting and editing stay blocked until
  /// [retryStorage] succeeds or the user confirms [resetStorage].
  bool get storageBlocked => _storageBlocked;

  /// Loads protected settings again, for example after unlocking the device.
  Future<bool> retryStorage() => _withState(() async {
    if (!_storageBlocked) return true;
    if (_shutdown || _disposed) return false;
    try {
      _state = await store.load();
      _storageBlocked = false;
      error = null;
      log('Protected settings loaded');
      unawaited(_hydrateDetails());
    } catch (_) {
      error = const FriendlyError(msgStorageBlocked);
    }
    _notify();
    return !_storageBlocked;
  });

  /// User-confirmed recovery: discards the unreadable settings (never by
  /// downgrading to plaintext) so servers can be re-imported.
  Future<bool> resetStorage() => _withState(() async {
    if (!_storageBlocked) return true;
    if (_shutdown || _disposed || conn != ConnState.disconnected) return false;
    try {
      await store.reset();
      _state = AppState();
      _storageBlocked = false;
      error = null;
      log('Protected settings were reset. Add your servers again.');
    } catch (_) {
      error = const FriendlyError(
        'Protected settings could not be reset. Try again.',
      );
    }
    _notify();
    return !_storageBlocked;
  });

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
  Future<FriendlyError?> importLink(
    String link, {
    Future<bool> Function(List<SecurityWarning>)? confirmWarnings,
  }) async {
    if (_storageBlocked || _shutdown || _disposed) {
      return const FriendlyError(msgStorageBlocked);
    }
    final trimmed = link.trim();
    if (trimmed.isEmpty) {
      return const FriendlyError('Paste a server link first.');
    }
    if (!trimmed.toLowerCase().startsWith(linkScheme)) {
      return const FriendlyError(
        'This is not a SingLinkVPN server link. It should start with $linkScheme',
      );
    }
    final res = await core.parseLink(trimmed);
    if (!res.ok) {
      log('Could not add server: ${res.error}', LogLevel.error);
      return friendlyLinkError(res.error ?? '');
    }
    if (res.warnings.isNotEmpty) {
      if (confirmWarnings == null || !await confirmWarnings(res.warnings)) {
        return const FriendlyError(
          'This advanced profile requires explicit security-warning confirmation.',
        );
      }
    }
    if (_shutdown || _disposed) {
      return const FriendlyError('Import was cancelled.');
    }
    final profile = res.profile!.withCredential(
      reference: '',
      value: trimmed,
      acceptedWarnings: res.warnings.map((w) => w.message).toList(),
    );
    return _withState(() async {
      if (_shutdown || _disposed) {
        return const FriendlyError('Import was cancelled.');
      }
      try {
        // A profile whose protected record is gone (restored backup, reset
        // OS key, wiped Keychain) can only be repaired by re-importing. An
        // unreadable record therefore never blocks an import; re-importing the
        // same server replaces the broken entry in place. A locked store still
        // fails below, because the new protected write cannot succeed.
        String? replaces;
        final key = matchKeyFor(
          _state.matchSalt,
          profile.server,
          profile.subject,
        );
        for (final existing in _state.profiles) {
          final String? existingLink;
          try {
            existingLink = (await store.readCredential(existing)).link;
          } on SecretStoreException {
            // F-07: matched by the opaque key, not a stored address.
            if (replaces == null &&
                key.isNotEmpty &&
                existing.matchKey == key) {
              replaces = existing.id;
            }
            continue;
          }
          if (existingLink == trimmed) {
            return const FriendlyError('This server is already in your list.');
          }
        }
        final candidate = _state.copy();
        final index = replaces == null
            ? -1
            : candidate.profiles.indexWhere((p) => p.id == replaces);
        if (index < 0) {
          candidate.profiles.add(profile);
        } else {
          final old = candidate.profiles[index];
          candidate.profiles[index] = Profile(
            id: old.id,
            matchKey: key,
            link: profile.link,
            name: profile.name,
            server: profile.server,
            transport: profile.transport,
            sni: profile.sni,
            subject: profile.subject,
            plan: profile.plan,
            expiresAt: profile.expiresAt,
            caps: profile.caps,
            rateKbps: profile.rateKbps,
            maxConns: profile.maxConns,
            addedAt: old.addedAt,
            acknowledgedWarnings: profile.acknowledgedWarnings,
          );
        }
        if (!await _commitCandidate(candidate)) {
          return error ?? const FriendlyError('Import was cancelled.');
        }
        log(
          index < 0
              ? 'Added server "${profile.displayName}"'
              : 'Re-imported server "${profile.displayName}"',
          LogLevel.success,
        );
        return null;
      } catch (_) {
        return const FriendlyError(
          'Protected credentials are unavailable. Unlock the device and try again.',
        );
      }
    });
  }

  Future<void> deleteProfile(String id) async {
    final idx = _state.profiles.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    if (conn != ConnState.disconnected && _connectedId == id) {
      await disconnect();
    }
    final removed = _byId(id);
    if (removed == null) return;
    if (!await _editState((next) {
      next.profiles.removeWhere((p) => p.id == id);
      if (next.selectedId == id) {
        next.selectedId = null;
        next.autoSelect = true;
      }
      if (next.lastUsedId == id) next.lastUsedId = null;
    })) {
      return;
    }
    log('Deleted server "${removed.displayName}"');
  }

  /// "Quick connect (auto)".
  Future<void> chooseAuto() => _choose(auto: true, id: null);

  Future<void> chooseServer(String id) => _choose(auto: false, id: id);

  Future<void> _choose({required bool auto, required String? id}) async {
    if (busy) return;
    final before = target?.id;
    final wasConnected = isConnected;
    if (!await _editState((next) {
      next.autoSelect = auto;
      if (!auto) next.selectedId = id;
    })) {
      return;
    }
    final after = (auto ? autoProfile : _byId(id))?.id;
    // Like a VPN app: picking another location while connected switches.
    if (wasConnected && after != null && after != before) {
      await disconnect();
      await connect();
    }
  }

  // ---- settings -----------------------------------------------------------

  Future<void> setSystemProxy(bool on) async {
    final generation = _generation;
    if (!await _editState((next) => next.systemProxy = on)) return;
    if (!_current(generation) || !isConnected) return;
    if (core.usesLocalProxy && _sessionAuth != localProxyNeedsAuth) {
      // App F-01: the port's authentication is fixed when the core starts.
      // Reconnect so turning the system proxy off never leaves an open port
      // (and turning it on gets a port the OS proxy settings can use).
      log('Reconnecting to apply the local proxy setting');
      await disconnect();
      await connect();
      return;
    }
    if (on) {
      await _applySystemProxy();
    } else {
      await _restoreSystemProxy();
      proxyWarning = null;
    }
    _notify();
  }

  /// iOS: applies from the next connect (the OS reads it when the tunnel
  /// configuration is saved).
  Future<void> setBlockOutsideTunnel(bool on) async {
    if (!await _editState((next) => next.blockOutsideTunnel = on)) return;
    log(
      on
          ? 'Traffic outside the VPN will be blocked from the next connection'
          : 'Traffic outside the VPN will no longer be blocked from the next connection',
    );
  }

  /// Android: opens the system VPN settings (always-on, kill switch).
  Future<bool> openVpnSettings() async {
    final c = core;
    if (c is! SystemStartCore) return false;
    return (c as SystemStartCore).openVpnSettings();
  }

  /// Only while disconnected. Returns an error message or null.
  Future<String?> setPort(int port) async {
    if (conn != ConnState.disconnected) return 'Disconnect first to change it';
    final err = validatePort('$port');
    if (err != null) return err;
    if (!await _editState((next) => next.port = port)) {
      return 'Protected settings could not be saved';
    }
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
    if (_disposed || _shutdown || _storageBlocked || busy || isConnected) {
      return;
    }
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
    final generation = ++_generation;
    final previous = _connectCompletion;
    final completed = Completer<void>();
    _connectCompletion = completed.future;
    conn = ConnState.connecting;
    _connectedId = profile.id;
    error = null;
    proxyWarning = null;
    exitIp = null;
    latencyMs = null;
    _notify();
    try {
      // A newer start never overtakes an obsolete start's scoped cleanup.
      if (previous != null) await previous;
      if (!_current(generation)) return;
      final credential = await store.readCredential(profile);
      if (!_current(generation)) return;
      final parsed = await core.parseLink(credential.link);
      if (!_current(generation)) return;
      if (!parsed.ok) {
        error = friendlyLinkError(parsed.error ?? '');
        _resetDisconnected();
        return;
      }
      final warnings = parsed.warnings.map((w) => w.message).toList();
      if (!listEquals(warnings, credential.acknowledgedWarnings)) {
        error = const FriendlyError(
          'Security warnings changed. Re-import this profile and review them before connecting.',
        );
        _resetDisconnected();
        return;
      }
      log('Connecting to "${profile.displayName}"...');
      _nativeOwner = generation;
      final native = core;
      final auth = localProxyNeedsAuth;
      final res = native is ProtectedProfileCore
          ? await (native as ProtectedProfileCore).startProtected(
              reference: profile.secretRef,
              listen: _state.listen,
              blockOutsideTunnel: _state.blockOutsideTunnel,
            )
          : await native.start(
              link: credential.link,
              listen: _state.listen,
              auth: auth,
            );
      if (!_current(generation)) {
        await _cleanupObsolete(generation);
        return;
      }
      if (!res.ok) {
        conn = ConnState.disconnected;
        _connectedId = null;
        error = friendlyError(res.error);
        log('Connection failed', LogLevel.error);
        return;
      }
      if (native.usesLocalProxy && auth && res.credentials == null) {
        // Fail closed: never present an unauthenticated port as the
        // password-protected one the user asked for.
        await _cleanupObsolete(generation);
        if (_current(generation)) {
          error = const FriendlyError(
            'The local proxy could not be protected with a password. Try again.',
          );
          _resetDisconnected();
        }
        return;
      }
      _sessionAuth = native.usesLocalProxy ? auth : null;
      proxyCredentials = auth ? res.credentials : null;
      // The OS proxy is pointed only at an unauthenticated port started for
      // it, and not if the switch changed while starting (reconciled below).
      final useSystemProxy = native.usesLocalProxy
          ? !auth && !localProxyNeedsAuth
          : _state.systemProxy;
      if (useSystemProxy) await _applySystemProxy();
      if (!_current(generation)) {
        await _cleanupObsolete(generation);
        return;
      }
      conn = ConnState.connected;
      connectedAt = clock();
      status = CoreStatus.idle;
      upRate = downRate = 0;
      _sampleAt = null;
      await _editState((next) => next.lastUsedId = profile.id);
      if (!_current(generation)) {
        await _cleanupObsolete(generation);
        return;
      }
      log(
        core.usesLocalProxy
            ? 'Connected to "${profile.displayName}" (local proxy ${_state.listen})'
            : 'Connected to "${profile.displayName}" (device-wide VPN)',
        LogLevel.success,
      );
      _startPolling();
      unawaited(_fetchExitIp());
      unawaited(measureLatency());
      if (native.usesLocalProxy && auth != localProxyNeedsAuth) {
        // The system-proxy switch changed while the core was starting.
        unawaited(_reconcileProxyMode(completed.future));
      }
    } on SecretStoreException {
      if (_current(generation)) {
        error = const FriendlyError(
          'Protected credentials are missing or locked. Unlock the device or re-import the profile.',
        );
        _resetDisconnected();
      }
    } catch (_) {
      if (_current(generation)) {
        error = const FriendlyError(
          'The connection could not be started safely.',
        );
        _resetDisconnected();
      }
      await _cleanupObsolete(generation);
    } finally {
      if (!completed.isCompleted) completed.complete();
      _notify();
    }
  }

  /// App F-01: restarts a session whose local-port authentication no longer
  /// matches the system-proxy switch (changed during the start).
  Future<void> _reconcileProxyMode(Future<void> started) async {
    await started;
    if (_disposed || _shutdown || !isConnected || !core.usesLocalProxy) return;
    if (_sessionAuth == localProxyNeedsAuth) return;
    log('Reconnecting to apply the local proxy setting');
    await disconnect();
    await connect();
  }

  Future<void> _cleanupObsolete(int generation) async {
    // New starts wait for this operation to finish. Never globally stop a
    // different generation that has already acquired the core.
    if (_nativeOwner != generation) return;
    await core.stop();
    if (_nativeOwner == generation) {
      await _restoreSystemProxy();
      _nativeOwner = null;
    }
  }

  Future<void> disconnect() async {
    if (_disposed ||
        conn == ConnState.disconnecting ||
        conn == ConnState.disconnected) {
      return;
    }
    final generation = ++_generation;
    conn = ConnState.disconnecting;
    _stopPolling();
    _notify();
    await _restoreSystemProxy();
    final res = await core.stop();
    if (_disposed || generation != _generation) return;
    if (!res.ok) {
      log('Error while stopping the connection', LogLevel.error);
      // A failed stop (for example iOS not reporting the tunnel down in
      // time) is not shown as disconnected while the tunnel still runs.
      bool stillRunning;
      try {
        stillRunning = (await core.status()).running;
      } catch (_) {
        stillRunning = false;
      }
      if (_disposed || generation != _generation) return;
      if (stillRunning) {
        conn = ConnState.connected;
        error = FriendlyError(msgStopFailed, res.error);
        _startPolling();
        _notify();
        return;
      }
    }
    _resetDisconnected();
    log('Disconnected');
  }

  /// Terminal for this controller. Completion is a barrier: an older start or
  /// proxy operation cannot create a new side effect after this returns.
  Future<void> shutdown() {
    final pending = _shutdownCompletion;
    if (pending != null) return pending;
    final guarded = _shutdownSafely().catchError((
      Object error,
      StackTrace stack,
    ) {
      _shutdownCompletion = null; // A cancelled quit may retry cleanup safely.
      Error.throwWithStackTrace(error, stack);
    });
    _shutdownCompletion = guarded;
    return guarded;
  }

  Future<void> _shutdownSafely() async {
    _shutdown = true;
    ++_generation;
    _stopPolling();
    // Native stop cancels pending consent/start before waiting for its result.
    try {
      await core.stop();
    } catch (_) {
      /* Final stop below verifies cleanup. */
    }
    final pending = _connectCompletion;
    if (pending != null) await pending;
    await _restoreSystemProxy(requireSuccess: true);
    final stopped = await core.stop();
    if (!stopped.ok) throw StateError('Connection cleanup could not complete');
    _nativeOwner = null;
    _resetDisconnected();
  }

  Future<void> _proxyOperation(Future<void> Function() action) {
    final done = Completer<void>();
    _proxyQueue = _proxyQueue.then((_) async {
      try {
        await action();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<void> _applySystemProxy() {
    final generation = _generation;
    final port = _state.port;
    return _proxyOperation(() async {
      final sp = systemProxy;
      if (sp == null || !_current(generation)) return;
      final r = await sp.enable(port);
      if (!_current(generation)) {
        // The enable was already in flight when stop invalidated this owner.
        await sp.restore();
        return;
      }
      if (r.ok) {
        proxyWarning = null;
        log('System proxy set (${r.changed.join(', ')})', LogLevel.success);
      } else {
        proxyWarning = systemProxyFailedMessage(port);
        log('Could not set the system proxy', LogLevel.error);
      }
    });
  }

  Future<void> _restoreSystemProxy({
    bool requireSuccess = false,
  }) => _proxyOperation(() async {
    final sp = systemProxy;
    if (sp == null) return;
    // Queue even while isApplied is still false: an in-flight enable may not
    // have captured its previous settings yet.
    final r = await sp.restore();
    if (r.changed.isNotEmpty && r.ok) {
      log('System proxy settings restored');
    } else if (!r.ok) {
      log('Could not restore the system proxy', LogLevel.error);
      if (requireSuccess) throw StateError('Proxy cleanup could not complete');
    }
  });

  Future<void> _fetchExitIp() async {
    final generation = _generation;
    exitIpLoading = true;
    _notify();
    final r = await core.exitIP(timeoutMs: exitIpTimeoutMs);
    if (!_current(generation)) return;
    exitIpLoading = false;
    if (!isConnected) return _notify();
    exitIp = r.ok ? r.ip : null;
    if (!r.ok) log('IP lookup failed: ${r.error}', LogLevel.error);
    _notify();
  }

  /// Measures the connected server with SingLinkProbe. Other servers have no
  /// figure: the core can only probe through the active tunnel.
  Future<void> measureLatency() async {
    final generation = _generation;
    if (measuring || !isConnected) return;
    measuring = true;
    _notify();
    final r = await core.probe(probeUrl, timeoutMs: probeTimeoutMs);
    if (!_current(generation)) return;
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
    measuring = false;
    proxyWarning = null;
    proxyCredentials = null;
    _sessionAuth = null;
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
    final generation = _generation;
    if (_pollInFlight || conn != ConnState.connected) return;
    _pollInFlight = true;
    try {
      final s = await core.status();
      if (!_current(generation) || _disposed || conn != ConnState.connected) {
        return;
      }
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
        if (!_current(generation) || conn != ConnState.connected) return;
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

  Future<T> _withState<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _stateQueue = _stateQueue.then((_) async {
      try {
        result.complete(await operation());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<bool> _editState(void Function(AppState) edit) => _withState(() async {
    if (_disposed || _shutdown || _storageBlocked) return false;
    final next = _state.copy();
    edit(next);
    return _commitCandidate(next);
  });

  Future<bool> _commitCandidate(AppState candidate) async {
    try {
      final committed = await store.commit(candidate);
      if (!_disposed && !_shutdown) _state = committed;
      if (store.cleanupPending) {
        error = const FriendlyError(
          'Profile changes were saved. Protected credential cleanup is pending; unlock and restart the app.',
        );
      }
      _notify();
      return !_disposed && !_shutdown;
    } catch (_) {
      error = const FriendlyError(
        'Protected settings could not be saved. Unlock the device and try again.',
      );
      logs.add(
        LogEntry(
          clock(),
          'Protected settings could not be saved',
          LogLevel.error,
        ),
      );
      _notify();
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_systemStarts?.cancel());
    _disposed = true;
    _shutdown = true;
    ++_generation;
    _stopPolling();
    unawaited(
      shutdown().catchError((Object _) {
        /* Best effort after disposal. */
      }),
    );
    super.dispose();
  }
}
