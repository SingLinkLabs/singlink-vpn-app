// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// AndroidVpnCore against a mocked Kotlin channel and a fake FFI layer: the
// order of consent → TUN → core calls, failure clean-up, and revoke handling.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/error_messages.dart';
import 'package:singlink_vpn/core/singlink_bindings.dart';
import 'package:singlink_vpn/platform/android.dart';

import 'support/fakes.dart';

class FakeTunCalls implements TunCalls {
  final log = <String>[];
  bool running = false;
  String? tunStartError;
  int? fd;
  Map<String, dynamic>? tunConfig;
  int up = 0;
  int down = 0;

  @override
  Future<String> version() async =>
      '{"version":"1.0.0-test","protocol":"SingLink Beta"}';

  @override
  Future<String> parseLink(String link) async {
    log.add('parseLink');
    return jsonEncode({
      'ok': true,
      'profile': {'name': 'HK', 'server': 'node.example.com:443'},
    });
  }

  @override
  Future<String> tunStart(int fd, String configJson) async {
    log.add('tunStart');
    this.fd = fd;
    tunConfig = jsonDecode(configJson) as Map<String, dynamic>;
    final err = tunStartError;
    if (err != null) return jsonEncode({'ok': false, 'error': err});
    running = true;
    return '{"ok":true}';
  }

  @override
  Future<String> tunStop() async {
    log.add('tunStop');
    running = false;
    return '{"ok":true}';
  }

  @override
  Future<String> status() async => jsonEncode({
    'running': running,
    'listen': running ? 'tun' : '',
    'up': up,
    'down': down,
    'conns': 0,
    'lastError': '',
  });

  @override
  Future<String> probe(String url, int timeoutMs) async {
    log.add('probe');
    return '{"ok":true,"status":204,"latencyMs":35}';
  }

  @override
  Future<String> exitIP(int timeoutMs) async {
    log.add('exitIP');
    return '{"ok":true,"ip":"198.51.100.4"}';
  }
}

const _loc = SingLinkLibLocation(
  path: 'libsinglink.so',
  searched: ['libsinglink.so'],
  errors: [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late FakeTunCalls calls;
  late List<MethodCall> native;
  late bool consent;
  late int fd;
  late AndroidVpnCore core;

  setUp(() {
    calls = FakeTunCalls();
    native = [];
    consent = true;
    fd = 42;
    messenger.setMockMethodCallHandler(vpnChannel, (call) async {
      native.add(call);
      switch (call.method) {
        case 'filesDir':
          return '/data/user/0/com.singlinklabs.singlinkvpn/files';
        case 'prepare':
          return consent;
        case 'establish':
          return fd;
        case 'stop':
          return null;
      }
      throw MissingPluginException();
    });
    core = AndroidVpnCore(location: _loc, calls: calls);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(vpnChannel, null);
    appSupportDirOverride = null;
  });

  List<String> methods() => native.map((c) => c.method).toList();

  test('is a device-wide VPN, not a local proxy', () {
    expect(core.usesLocalProxy, isFalse);
    expect(core.available, isTrue);
  });

  test('initAndroid stores the files directory', () async {
    await initAndroid();
    expect(
      appSupportDirOverride,
      '/data/user/0/com.singlinklabs.singlinkvpn/files',
    );
    expect(appSupportDir(), appSupportDirOverride);
  });

  test('start: consent, TUN, then SingLinkTunStart with the fd', () async {
    final r = await core.start(link: 'singlink://x', listen: '127.0.0.1:1080');
    expect(r.ok, isTrue);
    expect(methods(), ['prepare', 'establish']);
    expect(native[1].arguments, {'mtu': 1500});
    expect(calls.log, ['tunStart']);
    expect(calls.fd, 42);
    expect(calls.tunConfig, {
      'link': 'singlink://x',
      'mtu': 1500,
      'dns': '1.1.1.1:53',
      'appleHeader': false,
    });
    expect((await core.status()).running, isTrue);
  });

  test('start: declined consent gives the friendly message, no TUN', () async {
    consent = false;
    final r = await core.start(link: 'singlink://x', listen: '');
    expect(r.ok, isFalse);
    expect(r.error, vpnPermissionDenied);
    expect(friendlyError(r.error).message, msgVpnPermission);
    expect(methods(), ['prepare']);
    expect(calls.log, isEmpty);
  });

  test('start: core failure closes the fd and stops the service', () async {
    calls.tunStartError = 'cannot reach node: dial tcp: connection refused';
    final r = await core.start(link: 'singlink://x', listen: '');
    expect(r.ok, isFalse);
    expect(r.error, contains('cannot reach node'));
    expect(methods(), ['prepare', 'establish', 'stop']);
    expect(native.last.arguments, {'closeFd': true});
  });

  test('start: establish error from Kotlin becomes an OpResult', () async {
    messenger.setMockMethodCallHandler(vpnChannel, (call) async {
      native.add(call);
      if (call.method == 'prepare') return true;
      if (call.method == 'establish') {
        throw PlatformException(code: 'establish', message: 'boom');
      }
      return null;
    });
    final r = await core.start(link: 'singlink://x', listen: '');
    expect(r.ok, isFalse);
    expect(r.error, 'boom');
    expect(methods(), ['prepare', 'establish', 'stop']);
    expect(calls.log, isEmpty);
  });

  test('start ends a session left over from an earlier UI', () async {
    calls.running = true;
    final r = await core.start(link: 'singlink://x', listen: '');
    expect(r.ok, isTrue);
    expect(calls.log, ['tunStop', 'tunStart']);
    expect(methods(), ['stop', 'prepare', 'establish']);
  });

  test('stop: core first, then the service', () async {
    await core.start(link: 'singlink://x', listen: '');
    native.clear();
    final r = await core.stop();
    expect(r.ok, isTrue);
    expect(calls.log.last, 'tunStop');
    expect(methods(), ['stop']);
    expect(native.single.arguments, {'closeFd': false});
  });

  test(
    'status: a tunnel that ended by itself takes the service down',
    () async {
      await core.start(link: 'singlink://x', listen: '');
      native.clear();
      calls.running = false;
      expect((await core.status()).running, isFalse);
      expect(methods(), ['stop']);
      native.clear();
      await core.status();
      expect(native, isEmpty);
    },
  );

  test('revoked from Kotlin stops the core', () async {
    await core.start(link: 'singlink://x', listen: '');
    await messenger.handlePlatformMessage(
      vpnChannel.name,
      vpnChannel.codec.encodeMethodCall(const MethodCall('revoked')),
      (_) {},
    );
    expect(calls.log.last, 'tunStop');
    expect((await core.status()).running, isFalse);
  });

  test('version, parseLink, probe, exitIP go to the core', () async {
    expect((await core.version()).version, '1.0.0-test');
    expect((await core.parseLink(' singlink://x ')).ok, isTrue);
    expect((await core.probe('https://e')).latencyMs, 35);
    expect((await core.exitIP()).ip, '198.51.100.4');
  });

  test('unavailable core: start fails without touching Kotlin', () async {
    final c = AndroidVpnCore(
      location: const SingLinkLibLocation(
        path: null,
        searched: ['libsinglink.so'],
        errors: [],
      ),
      calls: calls,
    );
    final r = await c.start(link: 'singlink://x', listen: '');
    expect(r.ok, isFalse);
    expect(friendlyError(r.error).message, msgCoreMissing);
    expect(native, isEmpty);
  });

  test('controller: revoke shows the dropped message', () async {
    final c = ClientController(core: core, store: MemoryStore());
    addTearDown(c.dispose);
    await c.init();
    await c.importLink('singlink://node#HK');
    await c.connect();
    expect(c.conn, ConnState.connected);
    expect(c.logs.any((l) => l.message.contains('device-wide VPN')), isTrue);

    await messenger.handlePlatformMessage(
      vpnChannel.name,
      vpnChannel.codec.encodeMethodCall(const MethodCall('revoked')),
      (_) {},
    );
    // Let the 1 s poll run.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(c.conn, ConnState.disconnected);
    expect(c.error?.message, msgDropped);
  });
}
