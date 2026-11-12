import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/error_messages.dart';
import 'package:singlink_vpn/platform/ios.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = iosVpnChannel;

  late FakeCore ffi;
  late IosTunnelCore core;
  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> replies;

  setUp(() {
    ffi = FakeCore();
    calls = [];
    replies = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final r = replies[call.method];
      if (r == null) throw MissingPluginException();
      return r(call);
    });
    core = IosTunnelCore(ffi: ffi);
  });

  tearDown(() {
    core.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'device-wide VPN: no local proxy, FFI for version and parsing',
    () async {
      expect(core.usesLocalProxy, isFalse);
      expect(core.available, isTrue);
      expect((await core.version()).protocol, 'SingLink/1');
      final p = await core.parseLink('singlink://a#香港 01');
      expect(p.ok, isTrue);
      expect(calls, isEmpty, reason: 'parsing never touches the tunnel');
    },
  );

  test('start passes the link and the parsed server to the tunnel', () async {
    replies['start'] = (_) => '{"ok":true}';
    final r = await core.start(link: 'singlink://a#香港 01', listen: 'ignored');
    expect(r.ok, isTrue);
    expect(calls.single.method, 'start');
    expect(calls.single.arguments, {
      'link': 'singlink://a#香港 01',
      'server': 'node.example.com:443',
    });
  });

  test('start errors are mapped to friendly Chinese messages', () async {
    replies['start'] = (_) =>
        '{"ok":false,"error":"vpn permission denied: permission denied"}';
    var r = await core.start(link: 'singlink://a', listen: '');
    expect(r.ok, isFalse);
    expect(friendlyError(r.error).message, msgVpnPermission);

    replies['start'] = (_) =>
        '{"ok":false,"error":"vpn unsupported: the iOS Simulator cannot run a Network Extension packet tunnel"}';
    r = await core.start(link: 'singlink://a', listen: '');
    expect(friendlyError(r.error).message, msgVpnUnsupported);

    replies['start'] = (_) =>
        '{"ok":false,"error":"cannot reach node: dial tcp: i/o timeout"}';
    r = await core.start(link: 'singlink://a', listen: '');
    expect(friendlyError(r.error).message, msgUnreachable);
  });

  test('platform failures never throw from start/stop/probe/exitIP', () async {
    // No handler registered for these methods -> MissingPluginException.
    final r = await core.start(link: 'singlink://a', listen: '');
    expect(r.ok, isFalse);
    expect(friendlyError(r.error).message, msgVpnUnsupported);
    expect((await core.stop()).ok, isFalse);
    expect((await core.probe('https://x')).ok, isFalse);
    expect((await core.exitIP()).ok, isFalse);

    replies['stop'] = (_) =>
        throw PlatformException(code: 'E', message: 'boom');
    final s = await core.stop();
    expect(s.ok, isFalse);
    expect(s.error, 'boom');
  });

  test(
    'status, probe and exitIP decode the core JSON from the tunnel',
    () async {
      replies['status'] = (_) => jsonEncode({
        'running': true,
        'listen': 'tun',
        'up': 1200,
        'down': 3400,
        'conns': 3,
        'since': 1700000000,
        'lastError': '',
        'state': 'connected',
      });
      replies['probe'] = (c) {
        expect(c.arguments, {'url': 'https://p', 'timeoutMs': 5000});
        return '{"ok":true,"status":204,"latencyMs":87}';
      };
      replies['exitIP'] = (c) {
        expect(c.arguments, {'timeoutMs': 8000});
        return '{"ok":true,"ip":"203.0.113.9"}';
      };

      final st = await core.status();
      expect(st.running, isTrue);
      expect(st.up, 1200);
      expect(st.down, 3400);
      expect(st.conns, 3);

      final p = await core.probe('https://p', timeoutMs: 5000);
      expect(p.ok, isTrue);
      expect(p.latencyMs, 87);

      final ip = await core.exitIP();
      expect(ip.ip, '203.0.113.9');
    },
  );

  test(
    'a VPN switched off in iOS reports running=false with the reason',
    () async {
      replies['status'] = (_) =>
          '{"running":false,"up":0,"down":0,"lastError":"token expired","state":"disconnected"}';
      final st = await core.status();
      expect(st.running, isFalse);
      expect(friendlyError(st.lastError).message, msgExpired);
    },
  );

  test('status errors propagate so the controller can log them', () async {
    replies['status'] = (_) => throw PlatformException(code: 'E');
    expect(core.status(), throwsA(isA<PlatformException>()));
  });

  test('onStatus pushes from iOS update vpnState', () async {
    final seen = <String>[];
    final sub = core.vpnStates.listen(seen.add);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onStatus', '{"state":"connected","running":true}'),
      ),
      (_) {},
    );
    await pumpEventQueue();
    expect(core.vpnState, 'connected');
    expect(seen, ['connected']);
    await sub.cancel();
  });
}
