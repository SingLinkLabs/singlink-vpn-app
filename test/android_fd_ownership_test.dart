// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// A-04: Android TUN descriptor ownership. SingLinkTunStart never takes the
// descriptor (the core consumes only its own duplicate), so the bridge's
// original must be closed exactly once, never while the core call is in
// progress, and independently of the start result: success, pre-acquisition
// failure, cancellation after acquisition, a thrown FFI call, or a start
// abandoned before the core was called.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/singlink_bindings.dart';
import 'package:singlink_vpn/platform/android.dart';

import 'android_vpn_core_test.dart' show FakeTunCalls;

const _loc = SingLinkLibLocation(
  path: 'libsinglink.so',
  searched: [],
  errors: [],
);

/// Models the native side: the core duplicates the descriptor on entry and
/// closes only that duplicate; Kotlin closes only descriptors it handed out,
/// each at most once. Every event lands in one ordered [events] log.
class ModelTunCalls extends FakeTunCalls {
  ModelTunCalls(this.events);

  final List<String> events;

  /// When set, tunStart blocks after the duplicate was made until completed.
  Completer<void>? gate;
  final entered = Completer<void>();
  Completer<void>? entered2;

  /// Reply after the gate: 'ok', 'error' (pre-acquisition failure),
  /// 'cancelled' (Stop landed after the tunnel took the duplicate) or
  /// 'throw' (the isolate call itself failed).
  String reply = 'ok';
  bool coreOwnsDuplicate = false;

  @override
  Future<String> tunStart(int fd, String configJson) async {
    events.add('core-dup:$fd');
    if (!entered.isCompleted) {
      entered.complete();
    } else {
      entered2?.complete();
    }
    final g = gate;
    if (g != null) await g.future;
    switch (reply) {
      case 'error':
        events.add('core-close-dup');
        events.add('core-return:error');
        return '{"ok":false,"error":"cannot reach node: synthetic"}';
      case 'cancelled':
        // The tunnel acquired the duplicate; the stale-start cleanup closes it.
        events.add('core-close-dup');
        events.add('core-return:cancelled');
        return '{"ok":false,"error":"context canceled"}';
      case 'throw':
        events.add('core-close-dup');
        events.add('core-return:throw');
        throw StateError('isolate failed');
    }
    coreOwnsDuplicate = true;
    events.add('core-return:ok');
    return super.tunStart(fd, configJson);
  }

  @override
  Future<String> tunStop() async {
    if (coreOwnsDuplicate) {
      events.add('core-close-dup');
      coreOwnsDuplicate = false;
    }
    return super.tunStop();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> events;
  late Set<int> kotlinOpen;
  late ModelTunCalls calls;
  late AndroidVpnCore core;
  void Function()? onEstablish;

  setUp(() {
    events = [];
    kotlinOpen = {};
    onEstablish = null;
    calls = ModelTunCalls(events);
    messenger.setMockMethodCallHandler(vpnChannel, (call) async {
      switch (call.method) {
        case 'prepare':
          return true;
        case 'establish':
          kotlinOpen.add(42);
          events.add('kotlin-establish:42');
          onEstablish?.call();
          return 42;
        case 'closeFd':
          final fd = (call.arguments as Map)['fd'] as int;
          // VpnBridge.release: only descriptors it handed out, at most once.
          if (kotlinOpen.remove(fd)) {
            events.add('kotlin-close:$fd');
          } else {
            events.add('kotlin-ignore:$fd');
          }
          return null;
        case 'stop':
          events.add('kotlin-stop');
          return null;
      }
      throw MissingPluginException();
    });
    core = AndroidVpnCore(location: _loc, calls: calls);
  });

  tearDown(() => messenger.setMockMethodCallHandler(vpnChannel, null));

  int count(String e) => events.where((x) => x == e).length;

  /// Exactly one close of the original, after the core call returned, and
  /// never a second close request for the same number.
  void expectOriginalClosedOnceAfterCore() {
    expect(count('kotlin-close:42'), 1, reason: events.join(' > '));
    expect(events.where((e) => e.startsWith('kotlin-ignore')), isEmpty);
    expect(kotlinOpen, isEmpty);
    final returned = events.indexWhere((e) => e.startsWith('core-return'));
    if (returned >= 0) {
      expect(events.indexOf('kotlin-close:42'), greaterThan(returned));
    }
  }

  test(
    'success: original closed once after the call; core keeps its dup',
    () async {
      final r = await core.start(link: 'singlink://synthetic', listen: '');
      expect(r.ok, isTrue);
      expectOriginalClosedOnceAfterCore();
      expect(count('core-close-dup'), 0);
      await core.stop();
      expect(count('core-close-dup'), 1);
      expect(count('kotlin-close:42'), 1);
    },
  );

  test(
    'pre-acquisition failure: original closed once, dup by the core',
    () async {
      calls.reply = 'error';
      final r = await core.start(link: 'singlink://synthetic', listen: '');
      expect(r.ok, isFalse);
      expectOriginalClosedOnceAfterCore();
      expect(count('core-close-dup'), 1);
    },
  );

  test(
    'cancelled after acquisition (the audited A-04 window): the core '
    'closing its dup never leads to a second close of the original',
    () async {
      calls
        ..reply = 'cancelled'
        ..gate = Completer<void>();
      final start = core.start(link: 'singlink://synthetic', listen: '');
      await calls.entered.future;
      final stopping = core.stop();
      await pumpEventQueue();
      // Stop must not close the original while the core call is in progress.
      expect(count('kotlin-close:42'), 0, reason: events.join(' > '));
      calls.gate!.complete();
      expect((await start).ok, isFalse);
      await stopping;
      expectOriginalClosedOnceAfterCore();
      expect(count('core-close-dup'), 1);
    },
  );

  test(
    'stop while the core call succeeds late: dup stopped, original once',
    () async {
      calls.gate = Completer<void>();
      final start = core.start(link: 'singlink://synthetic', listen: '');
      await calls.entered.future;
      final stopping = core.stop();
      await pumpEventQueue();
      expect(count('kotlin-close:42'), 0);
      calls.gate!.complete();
      expect((await start).ok, isFalse);
      await stopping;
      expectOriginalClosedOnceAfterCore();
      expect(count('core-close-dup'), 1);
      expect(calls.running, isFalse);
    },
  );

  test('a thrown core call still closes the original exactly once', () async {
    calls.reply = 'throw';
    final r = await core.start(link: 'singlink://synthetic', listen: '');
    expect(r.ok, isFalse);
    expectOriginalClosedOnceAfterCore();
  });

  test(
    'abandoned before the core call: original closed once, no core call',
    () async {
      Future<void>? stopping;
      onEstablish = () => stopping = core.stop();
      final r = await core.start(link: 'singlink://synthetic', listen: '');
      await stopping;
      expect(r.ok, isFalse);
      expect(events.where((e) => e.startsWith('core-')), isEmpty);
      expectOriginalClosedOnceAfterCore();
    },
  );

  test('a thrown core call also stops a core that may have started', () async {
    calls.reply = 'throw';
    await core.start(link: 'singlink://synthetic', listen: '');
    expect(calls.log.last, 'tunStop');
  });

  test(
    'a status poll during a reconnect does not stop the new service',
    () async {
      await core.start(link: 'singlink://synthetic', listen: '');
      calls.running = false; // session 1 ended by itself, not yet polled
      calls
        ..gate = Completer<void>()
        ..entered2 = Completer<void>();
      final second = core.start(link: 'singlink://synthetic', listen: '');
      await calls.entered2!.future;
      events.clear();
      await core.status();
      expect(events, isNot(contains('kotlin-stop')));
      calls.gate!.complete();
      expect((await second).ok, isTrue);
      expect(events, isNot(contains('kotlin-stop')));
    },
  );

  test('revoke after success never closes the original again', () async {
    await core.start(link: 'singlink://synthetic', listen: '');
    await messenger.handlePlatformMessage(
      vpnChannel.name,
      vpnChannel.codec.encodeMethodCall(const MethodCall('revoked')),
      (_) {},
    );
    await pumpEventQueue();
    expect(count('kotlin-close:42'), 1);
    expect(count('core-close-dup'), 1);
  });
}
