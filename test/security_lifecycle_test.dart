// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/models/profile.dart';
import 'package:singlink_vpn/models/core_status.dart';
import 'support/fakes.dart';
import 'support/secret_store.dart';
import 'security_storage_test.dart' show HeldSecrets;

class HeldCore extends FakeCore {
  Completer<void>? startGate;
  Completer<void>? stopGate;
  final startEntered = Completer<void>();
  int starts = 0;
  @override
  Future<OpResult> start({
    required String link,
    required String listen,
    bool auth = true,
  }) async {
    starts++;
    if (!startEntered.isCompleted) startEntered.complete();
    await startGate?.future;
    return super.start(link: link, listen: listen);
  }

  @override
  Future<OpResult> stop() async {
    await stopGate?.future;
    return super.stop();
  }
}

class HeldStore extends TestAppStore {
  HeldStore(super.file);
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<AppState> commit(AppState state) async {
    entered?.complete();
    await gate?.future;
    return super.commit(state);
  }
}

class OrderedProxy implements SystemProxy {
  final events = <String>[];
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  bool isApplied = false;
  @override
  Future<ProxyResult> enable(int port) async {
    events.add('enable-entered');
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    isApplied = true;
    events.add('enable-sideeffect');
    return const ProxyResult();
  }

  @override
  Future<ProxyResult> restore() async {
    isApplied = false;
    events.add('restore');
    return const ProxyResult();
  }

  @override
  Future<ProxyResult> recover() async => const ProxyResult();
}

class IdlePollingCore extends FakeCore {
  final polled = Completer<void>();
  final answer = Completer<void>();
  @override
  Future<CoreStatus> status() async {
    if (!polled.isCompleted) polled.complete();
    await answer.future;
    return CoreStatus.idle;
  }
}

class HeldRestoreProxy extends OrderedProxy {
  Completer<void>? restoreGate;
  final restoring = Completer<void>();
  @override
  Future<ProxyResult> restore() async {
    if (restoreGate != null) {
      if (!restoring.isCompleted) restoring.complete();
      await restoreGate!.future;
    }
    return super.restore();
  }
}

class WarningCore extends FakeCore {
  List<String> warnings = ['Synthetic advanced security warning'];
  @override
  Future<ParseLinkResult> parseLink(String link) async =>
      ParseLinkResult.fromJson(link, {
        'ok': true,
        'profile': {'name': 'Synthetic', 'server': '127.0.0.1:9'},
        'warnings': warnings,
      });
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('synthetic-lifecycle-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  Future<ClientController> setup(
    FakeCore core, {
    AppStore? store,
    OrderedProxy? proxy,
  }) async {
    final controller = ClientController(
      core: core,
      store: store ?? TestAppStore(File('${dir.path}/state.json')),
      systemProxy: proxy,
    );
    await controller.init();
    await controller.importLink('singlink://synthetic');
    return controller;
  }

  test(
    'shutdown waits for obsolete start cleanup, then no side effects occur',
    () async {
      final core = HeldCore()..startGate = Completer<void>();
      final proxy = OrderedProxy();
      final c = await setup(core, proxy: proxy);
      final connecting = c.connect();
      await core.startEntered.future;
      var done = false;
      final ending = c.shutdown().then((_) {
        done = true;
      });
      await pumpEventQueue();
      expect(done, isFalse);
      core.startGate!.complete();
      await connecting;
      await ending;
      expect(c.conn, ConnState.disconnected);
      expect(core.running, isFalse);
      expect(proxy.events, isNot(contains('enable-sideeffect')));
      final count = proxy.events.length;
      await pumpEventQueue();
      expect(proxy.events.length, count);
      c.dispose();
    },
  );
  test('shutdown is a barrier for an in-flight proxy enable', () async {
    final proxy = OrderedProxy()..gate = Completer<void>();
    final c = await setup(FakeCore(), proxy: proxy);
    final connecting = c.connect();
    await proxy.entered.future;
    var done = false;
    final ending = c.shutdown().then((_) {
      done = true;
      proxy.events.add('shutdown-return');
    });
    await pumpEventQueue();
    expect(done, isFalse);
    proxy.gate!.complete();
    await connecting;
    await ending;
    expect(proxy.isApplied, isFalse);
    expect(proxy.events.last, 'shutdown-return');
    expect(
      proxy.events.indexOf('enable-sideeffect'),
      lessThan(proxy.events.indexOf('shutdown-return')),
    );
    c.dispose();
  });
  test(
    'setting commit completing after shutdown cannot enable proxy',
    () async {
      final core = HeldCore();
      final proxy = OrderedProxy();
      final store = HeldStore(File('${dir.path}/state.json'));
      final c = await setup(core, store: store, proxy: proxy);
      await c.setSystemProxy(false);
      await c.connect();
      store.gate = Completer<void>();
      store.entered = Completer<void>();
      core.stopGate = Completer<void>();
      final change = c.setSystemProxy(true);
      await store.entered!.future;
      final ending = c.shutdown();
      store.gate!.complete();
      await change;
      expect(proxy.events, isNot(contains('enable-sideeffect')));
      core.stopGate!.complete();
      await ending;
      c.dispose();
    },
  );
  test(
    'dispose restores an already applied proxy without real OS access',
    () async {
      final proxy = OrderedProxy();
      final c = await setup(FakeCore(), proxy: proxy);
      await c.connect();
      expect(proxy.isApplied, isTrue);
      c.dispose();
      await c.shutdown();
      expect(proxy.isApplied, isFalse);
    },
  );
  test(
    'obsolete poll does not publish a dropped error after terminal shutdown',
    () async {
      final core = IdlePollingCore();
      final proxy = HeldRestoreProxy();
      final c = await setup(core, proxy: proxy);
      await c.connect();
      await core.polled.future;
      proxy.restoreGate = Completer<void>();
      core.answer.complete();
      await proxy.restoring.future;
      final ending = c.shutdown();
      proxy.restoreGate!.complete();
      await ending;
      expect(
        c.logs.any((entry) => entry.message.startsWith('Connection dropped:')),
        isFalse,
      );
      expect(c.measuring, isFalse);
      c.dispose();
    },
  );
  test(
    'concurrent imports publish only committed metadata and preserve both',
    () async {
      final secrets = HeldSecrets();
      final store = AppStore(File('${dir.path}/state.json'), secrets: secrets);
      final c = ClientController(core: FakeCore(), store: store);
      await c.init();
      final first = c.importLink('singlink://synthetic-a');
      await secrets.entered.future;
      expect(c.profiles, isEmpty);
      final second = c.importLink('singlink://synthetic-b');
      secrets.release.complete();
      expect(await first, isNull);
      expect(await second, isNull);
      expect(c.profiles.length, 2);
      expect(c.profiles.every((p) => p.link.isEmpty), isTrue);
      c.dispose();
      await c.shutdown();
    },
  );
  test(
    'security warnings require consent and are bound to protected config',
    () async {
      final core = WarningCore();
      final c = ClientController(
        core: core,
        store: TestAppStore(File('${dir.path}/state.json')),
      );
      await c.init();
      expect(await c.importLink('singlink://synthetic'), isNotNull);
      expect(c.profiles, isEmpty);
      expect(
        await c.importLink(
          'singlink://synthetic',
          confirmWarnings: (_) async => false,
        ),
        isNotNull,
      );
      expect(
        await c.importLink(
          'singlink://synthetic',
          confirmWarnings: (_) async => true,
        ),
        isNull,
      );
      expect(
        await File('${dir.path}/state.json').readAsString(),
        isNot(contains(core.warnings.single)),
      );
      await c.connect();
      expect(c.isConnected, isTrue);
      await c.disconnect();
      core.warnings = ['Changed synthetic warning'];
      await c.connect();
      expect(c.isConnected, isFalse);
      expect(c.error!.message, contains('warnings changed'));
      c.dispose();
      await c.shutdown();
    },
  );
}
