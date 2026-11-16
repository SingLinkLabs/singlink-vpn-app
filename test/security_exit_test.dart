// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/main.dart';
import 'support/fakes.dart';
import 'security_lifecycle_test.dart' show HeldCore;

class RetryProxy implements SystemProxy {
  bool fail = true;
  @override
  bool get isApplied => fail;
  @override
  Future<ProxyResult> enable(int port) async => const ProxyResult();
  @override
  Future<ProxyResult> recover() async => const ProxyResult();
  @override
  Future<ProxyResult> restore() async => fail
      ? const ProxyResult(failed: {'synthetic': 'retry'})
      : const ProxyResult();
}

void main() {
  test(
    'normal quit waits for held cleanup rather than exiting on a timeout',
    () async {
      final core = HeldCore()..stopGate = Completer<void>();
      final c = ClientController(core: core, store: MemoryStore());
      var returned = false;
      final quitting = requestAppExit(c).then((value) {
        returned = true;
        return value;
      });
      await pumpEventQueue();
      expect(returned, isFalse);
      core.stopGate!.complete();
      expect(await quitting, AppExitResponse.exit);
      c.dispose();
    },
  );
  test(
    'failed proxy cleanup cancels quit visibly and supports retry',
    () async {
      final proxy = RetryProxy();
      final c = ClientController(
        core: FakeCore(),
        store: MemoryStore(),
        systemProxy: proxy,
      );
      expect(await requestAppExit(c), AppExitResponse.cancel);
      expect(c.error, isNotNull);
      proxy.fail = false;
      expect(await requestAppExit(c), AppExitResponse.exit);
      c.dispose();
    },
  );
  test('a hung cleanup cancels quit instead of freezing or exiting', () async {
    final core = HeldCore()..stopGate = Completer<void>();
    final c = ClientController(core: core, store: MemoryStore());
    expect(
      await requestAppExit(c, timeout: const Duration(milliseconds: 50)),
      AppExitResponse.cancel,
    );
    expect(c.error, isNotNull);
    core.stopGate!.complete();
    expect(await requestAppExit(c), AppExitResponse.exit);
    c.dispose();
  });
}
