// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/platform/android.dart';
import 'package:singlink_vpn/core/singlink_bindings.dart';
import 'android_vpn_core_test.dart' show FakeTunCalls;

const location = SingLinkLibLocation(
  path: 'libsinglink.so',
  searched: [],
  errors: [],
);

class DelayedTunCalls extends FakeTunCalls {
  final entered = Completer<void>();
  final release = Completer<void>();
  int starts = 0;
  @override
  Future<String> tunStart(int fd, String config) async {
    starts++;
    if (starts == 1) {
      entered.complete();
      await release.future;
    }
    return super.tunStart(fd, config);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(vpnChannel, null));
  test(
    'late consent after stop cannot establish an obsolete native tunnel',
    () async {
      final consent = Completer<bool>();
      final entered = Completer<void>();
      final calls = FakeTunCalls();
      int prepares = 0, establishes = 0;
      messenger.setMockMethodCallHandler(vpnChannel, (call) async {
        if (call.method == 'prepare') {
          prepares++;
          if (prepares == 1) {
            entered.complete();
            return consent.future;
          }
          return true;
        }
        if (call.method == 'establish') {
          establishes++;
          return 42;
        }
        if (call.method == 'stop') return null;
        throw MissingPluginException();
      });
      final core = AndroidVpnCore(location: location, calls: calls);
      final first = core.start(link: 'singlink://synthetic-first', listen: '');
      await entered.future;
      await core.stop();
      final second = core.start(
        link: 'singlink://synthetic-second',
        listen: '',
      );
      consent.complete(true);
      expect((await first).ok, isFalse);
      expect((await second).ok, isTrue);
      expect(establishes, 1);
      expect(calls.log.where((e) => e == 'tunStart').length, 1);
      await core.stop();
    },
  );
  test(
    'late TUN start is cleaned before a newer session can acquire core',
    () async {
      final calls = DelayedTunCalls();
      messenger.setMockMethodCallHandler(vpnChannel, (call) async {
        if (call.method == 'prepare') return true;
        if (call.method == 'establish') return 42;
        if (call.method == 'stop') return null;
        throw MissingPluginException();
      });
      final core = AndroidVpnCore(location: location, calls: calls);
      final first = core.start(link: 'singlink://synthetic-first', listen: '');
      await calls.entered.future;
      await core.stop();
      final second = core.start(
        link: 'singlink://synthetic-second',
        listen: '',
      );
      await pumpEventQueue();
      expect(calls.starts, 1);
      calls.release.complete();
      expect((await first).ok, isFalse);
      expect((await second).ok, isTrue);
      expect(calls.running, isTrue);
      expect(calls.log.last, 'tunStart');
      await core.stop();
    },
  );
}
