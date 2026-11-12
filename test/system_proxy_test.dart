// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/system_proxy.dart';

import 'support/fakes.dart';

void main() {
  test('parses networksetup output', () {
    expect(
      parseEnabledServices(
        'An asterisk (*) denotes that a network service is disabled.\n'
        'Thunderbolt Bridge\nWi-Fi\n*Bluetooth PAN\n\niPhone USB\n',
      ),
      ['Thunderbolt Bridge', 'Wi-Fi', 'iPhone USB'],
    );
    expect(
      SocksSetting.parse(
        'Enabled: No\nServer: 127.0.0.1\nPort: 7897\n'
        'Authenticated Proxy Enabled: 0\n',
      ),
      const SocksSetting(enabled: false, server: '127.0.0.1', port: 7897),
    );
    expect(
      SocksSetting.parse('Enabled: Yes\nServer: \nPort: 0\n'),
      const SocksSetting(enabled: true, server: '', port: 0),
    );
    expect(
      SocksSetting.parse('** Error: The parameters were not valid.'),
      isNull,
    );
  });

  test(
    'enable sets every enabled service, restore puts back exactly',
    () async {
      final r = FakeRunner(
        socks: {
          'Wi-Fi': FakeRunner.socksOut(false, '127.0.0.1', 7897),
          'USB 10/100/1000 LAN': FakeRunner.socksOut(true, '10.0.0.2', 1081),
        },
      );
      final before = Map.of(r.socks);
      final m = SystemProxyManager(runner: r);

      final on = await m.enable(1080);
      expect(on.ok, isTrue, reason: '$on');
      expect(on.changed, [
        'Thunderbolt Bridge',
        'Wi-Fi',
        'USB 10/100/1000 LAN',
      ]);
      expect(m.isApplied, isTrue);
      // Disabled "*Bluetooth PAN" is never touched.
      expect(r.calls.any((c) => c.contains('Bluetooth PAN')), isFalse);
      expect(r.calls.first, ['-listallnetworkservices']);
      expect(r.writes, [
        '-setsocksfirewallproxy Thunderbolt Bridge 127.0.0.1 1080',
        '-setsocksfirewallproxystate Thunderbolt Bridge on',
        '-setsocksfirewallproxy Wi-Fi 127.0.0.1 1080',
        '-setsocksfirewallproxystate Wi-Fi on',
        '-setsocksfirewallproxy USB 10/100/1000 LAN 127.0.0.1 1080',
        '-setsocksfirewallproxystate USB 10/100/1000 LAN on',
      ]);
      for (final s in ['Thunderbolt Bridge', 'Wi-Fi', 'USB 10/100/1000 LAN']) {
        expect(
          SocksSetting.parse(r.socks[s]!),
          const SocksSetting(enabled: true, server: '127.0.0.1', port: 1080),
        );
      }

      r.calls.clear();
      final off = await m.restore();
      expect(off.ok, isTrue);
      expect(m.isApplied, isFalse);
      expect(r.writes, [
        // No previous server: only the state can be put back.
        '-setsocksfirewallproxystate Thunderbolt Bridge off',
        '-setsocksfirewallproxy Wi-Fi 127.0.0.1 7897',
        '-setsocksfirewallproxystate Wi-Fi off',
        '-setsocksfirewallproxy USB 10/100/1000 LAN 10.0.0.2 1081',
        '-setsocksfirewallproxystate USB 10/100/1000 LAN on',
      ]);
      expect(r.socks['Wi-Fi'], before['Wi-Fi']);
      expect(r.socks['USB 10/100/1000 LAN'], before['USB 10/100/1000 LAN']);
      expect(
        SocksSetting.parse(r.socks['Thunderbolt Bridge']!)!.enabled,
        isFalse,
      );

      // Nothing left to restore.
      r.calls.clear();
      expect((await m.restore()).changed, isEmpty);
      expect(r.calls, isEmpty);
    },
  );

  test('enabling twice keeps the original settings', () async {
    final r = FakeRunner(
      services: 'Wi-Fi\n',
      socks: {'Wi-Fi': FakeRunner.socksOut(true, '10.1.1.1', 3128)},
    );
    final m = SystemProxyManager(runner: r);
    await m.enable(1080);
    await m.enable(1090); // e.g. reconnect
    expect(
      m.saved['Wi-Fi'],
      const SocksSetting(enabled: true, server: '10.1.1.1', port: 3128),
    );
    await m.restore();
    expect(
      SocksSetting.parse(r.socks['Wi-Fi']!),
      const SocksSetting(enabled: true, server: '10.1.1.1', port: 3128),
    );
  });

  test('permission failure on listing is reported, nothing changed', () async {
    final r = FakeRunner()..failing.add('-listallnetworkservices');
    final m = SystemProxyManager(runner: r);
    final res = await m.enable(1080);
    expect(res.ok, isFalse);
    expect(res.failed.keys, ['*']);
    expect(r.writes, isEmpty);
    expect(m.isApplied, isFalse);
  });

  test('partial failure: other services still applied and restored', () async {
    final r = FakeRunner(services: 'Wi-Fi\nEthernet\n')
      ..failing.add('-setsocksfirewallproxy Ethernet');
    final m = SystemProxyManager(runner: r);
    final res = await m.enable(1080);
    expect(res.ok, isFalse);
    expect(res.changed, ['Wi-Fi']);
    expect(res.failed.keys, ['Ethernet']);
    expect(SocksSetting.parse(r.socks['Wi-Fi']!)!.enabled, isTrue);

    r.failing.clear();
    final back = await m.restore();
    expect(back.ok, isTrue);
    expect(SocksSetting.parse(r.socks['Wi-Fi']!)!.enabled, isFalse);
    expect(m.isApplied, isFalse);
  });

  test('restore failure keeps the entry for a retry', () async {
    final r = FakeRunner(services: 'Wi-Fi\n');
    final m = SystemProxyManager(runner: r);
    await m.enable(1080);
    r.failing.add('-setsocksfirewallproxystate Wi-Fi off');
    final res = await m.restore();
    expect(res.ok, isFalse);
    expect(m.isApplied, isTrue);
    r.failing.clear();
    expect((await m.restore()).ok, isTrue);
    expect(m.isApplied, isFalse);
  });

  test('an existing authenticated proxy is left alone', () async {
    final r = FakeRunner(
      services: 'Wi-Fi\n',
      socks: {'Wi-Fi': FakeRunner.socksOut(true, 'corp.proxy', 1080, auth: 1)},
    );
    final m = SystemProxyManager(runner: r);
    final res = await m.enable(1080);
    expect(res.ok, isFalse);
    expect(r.writes, isEmpty);
  });

  test('journal survives a crash and recover() restores', () async {
    final dir = await Directory.systemTemp.createTemp('singlink_journal');
    addTearDown(() => dir.delete(recursive: true));
    final journal = ProxyJournal(File('${dir.path}/j.json'));
    final r = FakeRunner(
      services: 'Wi-Fi\n',
      socks: {'Wi-Fi': FakeRunner.socksOut(false, '127.0.0.1', 7897)},
    );
    await SystemProxyManager(runner: r, journal: journal).enable(1080);
    expect(await journal.file.exists(), isTrue);

    // "Crash": a fresh manager on next launch.
    final next = SystemProxyManager(runner: r, journal: journal);
    final res = await next.recover();
    expect(res.changed, ['Wi-Fi']);
    expect(
      SocksSetting.parse(r.socks['Wi-Fi']!),
      const SocksSetting(enabled: false, server: '127.0.0.1', port: 7897),
    );
    expect(await journal.file.exists(), isFalse);

    // Clean state: recover is a no-op.
    r.calls.clear();
    expect((await next.recover()).changed, isEmpty);
    expect(r.calls, isEmpty);
  });
}
