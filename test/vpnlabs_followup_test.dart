// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// VPN Labs follow-up (2026-11-19): App F-01 (local proxy authentication),
// App F-04 (wording, Android always-on start path) and App F-07 (connection
// details kept out of the settings file, migration, Windows local storage).
// Synthetic data only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/singlink_service.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/main.dart';
import 'package:singlink_vpn/models/core_status.dart';
import 'package:singlink_vpn/models/profile.dart';
import 'package:singlink_vpn/models/protected_credential.dart';

import 'support/fakes.dart';
import 'support/secret_store.dart';

const _server = 'node.example.invalid:443';
const _sni = 'cdn.example.invalid';
const _subject = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';

/// FakeCore whose parser reports SNI and subject like the real core.
class DetailedCore extends FakeCore {
  @override
  Future<ParseLinkResult> parseLink(String link) async {
    calls.add('parse');
    if (!link.startsWith('singlink://')) {
      return ParseLinkResult.failure('not a singlink link');
    }
    return ParseLinkResult.fromJson(link, {
      'ok': true,
      'profile': {
        'name': link.contains('#') ? link.split('#').last : '',
        'server': _server,
        'transport': 'tls',
        'sni': _sni,
        'subject': _subject,
        'plan': 1,
        'expiresAt': 0,
        'caps': ['tcp'],
      },
    });
  }
}

/// FakeCore whose next start waits until [gate] completes.
class GatedCore extends FakeCore {
  Completer<void>? gate;
  @override
  Future<OpResult> start({
    required String link,
    required String listen,
    bool auth = true,
  }) async {
    final g = gate;
    gate = null;
    if (g != null) await g.future;
    return super.start(link: link, listen: listen, auth: auth);
  }
}

/// Android-like device-wide core that the OS can start (always-on).
class SystemStartFakeCore extends DetailedCore implements SystemStartCore {
  SystemStartFakeCore() {
    usesLocalProxy = false;
  }
  bool pending = false;
  int failedCalls = 0;
  int takes = 0;
  final requests = StreamController<void>.broadcast();

  @override
  Stream<void> get systemStartRequests => requests.stream;

  @override
  Future<bool> takeSystemStart() async {
    takes++;
    final was = pending;
    pending = false;
    return was;
  }

  @override
  Future<void> systemStartFailed() async => failedCalls++;

  @override
  Future<bool> openVpnSettings() async => true;
}

void main() {
  late Directory dir;
  late MemorySecretStore secrets;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('singlink_vpnl');
    secrets = MemorySecretStore();
  });
  tearDown(() async {
    // A disposed controller may still finish a last atomic write; retry.
    for (var attempt = 0; await dir.exists(); attempt++) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 5) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  File stateFile() => File('${dir.path}/state.json');
  TestAppStore store() => TestAppStore(stateFile(), secrets: secrets);

  group('App F-01: local proxy authentication', () {
    late FakeCore core;
    late ClientController c;

    setUp(() async {
      core = FakeCore();
      c = ClientController(
        core: core,
        store: store(),
        systemProxy: SystemProxyManager(
          runner: FakeRunner(services: 'Wi-Fi\n'),
        ),
      );
      await c.init();
      await c.importLink('singlink://a#Tokyo');
    });
    tearDown(() => c.dispose());

    test(
      'system proxy off: the port requires a fresh per-session login',
      () async {
        await c.setSystemProxy(false);
        expect(c.localProxyNeedsAuth, isTrue);
        await c.connect();
        expect(c.isConnected, isTrue);
        expect(core.authRequests.last, isTrue);
        final first = c.proxyCredentials!;
        expect(first.username, 'synthetic-user-1');
        expect(c.localProxyOpen, isFalse);

        await c.disconnect();
        expect(c.proxyCredentials, isNull, reason: 'dropped with the session');
        await c.connect();
        expect(c.proxyCredentials!.password, isNot(first.password));

        // Never logged, never written to settings.
        final logs = c.logs.map((e) => e.message).join('\n');
        final saved = await stateFile().readAsString();
        for (final value in [
          first.username,
          first.password,
          c.proxyCredentials!.password,
        ]) {
          expect(logs, isNot(contains(value)));
          expect(saved, isNot(contains(value)));
        }
        await c.disconnect();
      },
    );

    test('system proxy on: no auth, and the open port is reported', () async {
      expect(c.systemProxyEnabled, isTrue);
      expect(c.localProxyNeedsAuth, isFalse);
      await c.connect();
      expect(core.authRequests.last, isFalse);
      expect(c.proxyCredentials, isNull);
      expect(c.localProxyOpen, isTrue);
      await c.disconnect();
      expect(c.localProxyOpen, isFalse);
    });

    test(
      'toggling the system proxy while connected restarts with matching auth',
      () async {
        await c.connect();
        expect(core.authRequests.last, isFalse);
        core.calls.clear();
        await c.setSystemProxy(false);
        expect(core.calls, ['stop', 'parse', 'start 127.0.0.1:1080']);
        expect(core.authRequests.last, isTrue);
        expect(c.isConnected, isTrue);
        expect(c.proxyCredentials, isNotNull);
        expect(c.localProxyOpen, isFalse);

        await c.setSystemProxy(true);
        expect(core.authRequests.last, isFalse);
        expect(c.proxyCredentials, isNull);
        expect(c.localProxyOpen, isTrue);
        await c.disconnect();
      },
    );

    test(
      'turning the system proxy off during a start ends with a password',
      () async {
        final gated = GatedCore();
        final runner = FakeRunner(services: 'Wi-Fi\n');
        final g = ClientController(
          core: gated,
          store: TestAppStore(File('${dir.path}/gated.json'), secrets: secrets),
          systemProxy: SystemProxyManager(runner: runner),
        );
        await g.init();
        await g.importLink('singlink://a#Tokyo');
        final gate = gated.gate = Completer<void>();
        final connecting = g.connect(); // system proxy on: no auth requested
        await pumpEventQueue();
        expect(g.busy, isTrue);
        await g.setSystemProxy(false); // switched while the core starts
        gate.complete();
        await connecting;
        await pumpEventQueue();
        expect(g.isConnected, isTrue);
        expect(gated.authRequests, [
          false,
          true,
        ], reason: 'restarted with auth');
        expect(g.proxyCredentials, isNotNull);
        expect(g.localProxyOpen, isFalse);
        expect(
          runner.writes.where((w) => w.endsWith(' on')),
          isEmpty,
          reason: 'the OS proxy is never pointed at the port',
        );
        await g.disconnect();
        await g.shutdown();
        g.dispose();
      },
    );

    test('a start that returns no login fails closed', () async {
      await c.setSystemProxy(false);
      core.withholdCredentials = true;
      await c.connect();
      expect(c.isConnected, isFalse);
      expect(core.running, isFalse, reason: 'the open port was stopped');
      expect(c.error!.message, contains('password'));
    });

    test('device-wide VPN cores never ask for a local login', () async {
      core.usesLocalProxy = false;
      expect(c.localProxyNeedsAuth, isFalse);
      await c.setSystemProxy(false);
      await c.connect();
      expect(c.proxyCredentials, isNull);
      expect(c.localProxyOpen, isFalse);
      await c.disconnect();
    });
  });

  group('App F-01: settings UI', () {
    Future<ClientController> connected(
      WidgetTester tester, {
      required bool systemProxy,
    }) async {
      final c = ClientController(
        core: FakeCore(),
        store: MemoryStore(),
        systemProxy: systemProxy
            ? SystemProxyManager(runner: FakeRunner())
            : null,
      );
      await c.init();
      await c.importLink('singlink://a#Tokyo');
      await c.connect();
      addTearDown(c.dispose);
      return c;
    }

    Future<void> openSettings(WidgetTester tester, ClientController c) async {
      tester.view.physicalSize = const Size(420, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SingLinkVpnApp(controller: c));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'connected with a login: host, port, user, masked password, copy',
      (tester) async {
        final c = await connected(tester, systemProxy: false);
        await openSettings(tester, c);
        final login = c.proxyCredentials!;
        expect(find.text('Local proxy'), findsOneWidget);
        expect(find.text('127.0.0.1'), findsOneWidget);
        expect(find.text('1080'), findsWidgets);
        expect(find.text(login.username), findsOneWidget);
        expect(find.text(login.password), findsNothing, reason: 'masked');
        for (final label in ['Host', 'Port', 'Username', 'Password']) {
          expect(find.byTooltip('Copy $label'), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Show Password'));
        await tester.pump();
        expect(find.text(login.password), findsOneWidget);

        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        await tester.tap(find.byTooltip('Copy Password'));
        await tester.pump();
        expect(copied, login.password);
        expect(find.textContaining('no password'), findsNothing);
        await c.disconnect();
      },
    );

    testWidgets(
      'system proxy mode: says the port is open to every local user',
      (tester) async {
        final c = await connected(tester, systemProxy: true);
        await openSettings(tester, c);
        expect(find.text('Local proxy has no password'), findsOneWidget);
        expect(
          find.textContaining('any app or user account on this computer'),
          findsOneWidget,
        );
        expect(find.byTooltip('Copy Password'), findsNothing);
        await c.disconnect();
      },
    );

    testWidgets(
      'disconnected, system proxy on: the warning is shown ahead of time',
      (tester) async {
        final c = ClientController(
          core: FakeCore(),
          store: MemoryStore(),
          systemProxy: SystemProxyManager(runner: FakeRunner()),
        );
        await c.init();
        addTearDown(c.dispose);
        await openSettings(tester, c);
        expect(find.text('Local proxy'), findsOneWidget);
        expect(
          find.textContaining('No password while System-wide proxy is on'),
          findsOneWidget,
        );
      },
    );
  });

  group('App F-07: connection details stay out of the settings file', () {
    Map<String, dynamic> saved() =>
        jsonDecode(stateFile().readAsStringSync()) as Map<String, dynamic>;

    void expectNoDetails(Map<String, dynamic> json) {
      expect(json['version'], stateVersion);
      final raw = jsonEncode(json);
      for (final detail in [
        _server,
        'node.example.invalid',
        _sni,
        _subject,
        'singlink://',
      ]) {
        expect(raw, isNot(contains(detail)), reason: detail);
      }
      for (final p in (json['profiles'] as List).cast<Map>()) {
        for (final key in Profile.sensitiveKeys) {
          expect(p.containsKey(key), isFalse, reason: key);
        }
        expect(p['matchKey'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      }
    }

    test('import writes only display metadata and opaque references', () async {
      final c = ClientController(core: DetailedCore(), store: store());
      await c.init();
      expect(await c.importLink('singlink://a#Tokyo'), isNull);
      expect(c.profiles.single.server, _server, reason: 'known in memory');
      expectNoDetails(saved());
      expect(saved()['profiles'][0]['name'], 'Tokyo');
      c.dispose();
    });

    test(
      'after a restart details are derived from the protected link',
      () async {
        final first = ClientController(core: DetailedCore(), store: store());
        await first.init();
        await first.importLink('singlink://a');
        first.dispose();

        final again = ClientController(core: DetailedCore(), store: store());
        await again.init();
        await pumpEventQueue();
        final p = again.profiles.single;
        expect(p.server, _server);
        expect(p.subject, _subject);
        expect(p.displayName, _server, reason: 'unnamed link shows its server');
        expectNoDetails(saved());
        again.dispose();
      },
    );

    Future<String> writeV3({bool storeRecord = true}) async {
      const ref = 'slk_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      if (storeRecord) {
        secrets.values[ref] = const ProtectedCredential(
          'singlink://a#Tokyo',
          [],
        ).encode();
      }
      final v3 = {
        'version': 3,
        'profiles': [
          {
            'id': 'legacy-1',
            'secretRef': ref,
            'name': 'Tokyo',
            'server': _server,
            'transport': 'tls',
            'sni': _sni,
            'subject': _subject,
            'plan': 1,
            'expiresAt': 0,
            'caps': ['tcp'],
            'rateKbps': 0,
            'maxConns': 0,
            'addedAt': 1700000000,
          },
        ],
        'selectedId': 'legacy-1',
        'autoSelect': false,
        'lastUsedId': 'legacy-1',
        'port': 1090,
        'systemProxy': false,
        'pendingSecretDeletes': <String>[],
      };
      final text = jsonEncode(v3);
      await stateFile().writeAsString(text);
      return text;
    }

    test('v3 file migrates after the protected record is confirmed', () async {
      await writeV3();
      final s = await store().load();
      final json = saved();
      expectNoDetails(json);
      final p = (json['profiles'] as List).single as Map;
      expect(p['id'], 'legacy-1');
      expect(p['name'], 'Tokyo');
      expect(
        p['matchKey'],
        matchKeyFor(json['matchSalt'] as String, _server, _subject),
      );
      expect(s.profiles.single.id, 'legacy-1');
      expect(s.selectedId, 'legacy-1');
      expect(s.port, 1090);
      expect(s.systemProxy, isFalse);
      // The profile still connects from its protected record.
      final credential = await store().readCredential(s.profiles.single);
      expect(credential.link, 'singlink://a#Tokyo');
      // A second load is a no-op.
      final before = stateFile().readAsStringSync();
      await store().load();
      expect(stateFile().readAsStringSync(), before);
    });

    test('a locked store keeps the v3 file untouched for retry', () async {
      final original = await writeV3();
      secrets.locked = true;
      await expectLater(store().load(), throwsA(isA<AppStoreException>()));
      expect(await stateFile().readAsString(), original);
      secrets.locked = false;
      await store().load();
      expectNoDetails(saved());
    });

    test(
      'a missing record does not block migration; re-import replaces it in place',
      () async {
        await writeV3(storeRecord: false);
        final c = ClientController(core: DetailedCore(), store: store());
        await c.init();
        expect(c.storageBlocked, isFalse);
        expectNoDetails(saved());
        expect(await c.importLink('singlink://a#Tokyo'), isNull);
        expect(c.profiles, hasLength(1), reason: 'matched by the opaque key');
        expect(c.profiles.single.id, 'legacy-1');
        expectNoDetails(saved());
        c.dispose();
      },
    );

    test('match keys are keyed per installation', () {
      final a = newMatchSalt();
      final b = newMatchSalt();
      expect(
        matchKeyFor(a, _server, _subject),
        matchKeyFor(a, _server, _subject),
      );
      expect(
        matchKeyFor(a, _server, _subject),
        isNot(matchKeyFor(b, _server, _subject)),
      );
      expect(matchKeyFor(a, _server, _subject), isNot(contains('node')));
      expect(matchKeyFor(a, '', ''), isEmpty);
    });

    test('Windows: roaming data moves to local AppData once', () async {
      final roaming = Directory('${dir.path}/Roaming/SingLinkLabs/SingLinkVPN');
      final local = Directory('${dir.path}/Local/SingLinkLabs/SingLinkVPN');
      await roaming.create(recursive: true);
      await File('${roaming.path}/state.json').writeAsString('{"version":4}');
      await File(
        '${roaming.path}/system-proxy-restore.json',
      ).writeAsString('[]');
      await File('${roaming.path}/state.json.tmp').writeAsString('stale');
      await migrateDataDirectory(roaming, local);
      expect(
        await File('${local.path}/state.json').readAsString(),
        '{"version":4}',
      );
      expect(
        await File('${local.path}/system-proxy-restore.json').exists(),
        isTrue,
      );
      expect(await roaming.exists(), isFalse, reason: 'roaming copies removed');

      // An existing local state is authoritative and never overwritten; a
      // roaming copy written later (e.g. by an older version) is removed, and
      // staging leftovers of an interrupted move are cleaned up.
      await roaming.create(recursive: true);
      await File('${roaming.path}/state.json').writeAsString('{"other":true}');
      await File('${local.path}/state.json.migrating').writeAsString('partial');
      await migrateDataDirectory(roaming, local);
      expect(
        await File('${local.path}/state.json').readAsString(),
        '{"version":4}',
      );
      expect(await File('${roaming.path}/state.json').exists(), isFalse);
      expect(
        await File('${local.path}/state.json.migrating').exists(),
        isFalse,
      );
    });
  });

  group('App F-04: Android always-on start path', () {
    Future<void> seed() async {
      final c = ClientController(core: DetailedCore(), store: store());
      await c.init();
      await c.importLink('singlink://a#Tokyo');
      c.dispose();
    }

    test('an OS start connects the saved profile without the UI', () async {
      await seed();
      final core = SystemStartFakeCore()..pending = true;
      final c = ClientController(core: core, store: store());
      await c.init();
      await pumpEventQueue();
      expect(c.isConnected, isTrue);
      expect(c.target!.name, 'Tokyo');
      expect(core.failedCalls, 0);
      expect(
        c.logs.map((e) => e.message),
        contains('Started by Android (always-on VPN)'),
      );
      expect(c.connectedSummary.$1, 'Connected');

      // A repeated request while connected does nothing.
      core.pending = true;
      core.requests.add(null);
      await pumpEventQueue();
      expect(core.calls.where((x) => x.startsWith('start')), hasLength(1));
      c.dispose();
    });

    test(
      'without a saved profile the placeholder service is released',
      () async {
        final core = SystemStartFakeCore()..pending = true;
        final c = ClientController(core: core, store: store());
        await c.init();
        await pumpEventQueue();
        expect(c.isConnected, isFalse);
        expect(core.failedCalls, 1);
        c.dispose();
      },
    );

    test('changed security warnings block an OS start too', () async {
      await seed();
      final core = _WarningCore()..pending = true;
      final c = ClientController(core: core, store: store());
      await c.init();
      await pumpEventQueue();
      expect(c.isConnected, isFalse);
      expect(core.failedCalls, 1);
      expect(core.calls.where((x) => x.startsWith('start')), isEmpty);
      c.dispose();
    });

    test(
      'an OS start while a user operation runs releases the placeholder',
      () async {
        await seed();
        final core = SystemStartFakeCore();
        final c = ClientController(core: core, store: store());
        await c.init();
        final connecting = c.connect();
        core.pending = true;
        core.requests.add(null);
        await connecting;
        await pumpEventQueue();
        expect(core.failedCalls, 1);
        expect(c.isConnected, isTrue, reason: 'the user connect is unaffected');
        expect(core.calls.where((x) => x.startsWith('start')), hasLength(1));
        c.dispose();
      },
    );

    test('a request is handled once even when pushed and pulled', () async {
      await seed();
      final core = SystemStartFakeCore();
      final c = ClientController(core: core, store: store());
      await c.init();
      core.pending = true;
      core.requests
        ..add(null)
        ..add(null);
      await pumpEventQueue();
      expect(core.calls.where((x) => x.startsWith('start')), hasLength(1));
      expect(c.isConnected, isTrue);
      c.dispose();
    });
  });
}

/// A profile whose parser now reports a warning the user never accepted.
class _WarningCore extends SystemStartFakeCore {
  @override
  Future<ParseLinkResult> parseLink(String link) async {
    final r = await super.parseLink(link);
    if (!r.ok) return r;
    return ParseLinkResult.fromJson(link, {
      'ok': true,
      'profile': {'name': 'Tokyo', 'server': _server},
      'warnings': ['synthetic new warning'],
    });
  }
}
