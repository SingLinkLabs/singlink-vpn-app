// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/platform/windows.dart';

const _reg = r'C:\Windows\System32\reg.exe';

/// In-memory `reg.exe` for the Internet Settings key. Never touches the
/// real registry (and runs on any OS).
class FakeReg implements ProcessRunner {
  FakeReg([Map<String, RegValue>? values]) : values = values ?? {};

  final Map<String, RegValue> values;

  /// Commands (args joined with spaces) starting with one of these fail.
  final Set<String> failing = {};
  final List<List<String>> calls = [];

  /// Commands that change something, joined with spaces.
  List<String> get writes => [
    for (final c in calls)
      if (c.first != 'query') c.join(' '),
  ];

  @override
  Future<RunResult> run(String executable, List<String> args) async {
    calls.add(args);
    if (executable != _reg) return const RunResult(127, '', 'bad exe');
    if (args.length < 2 || args[1] != internetSettingsKey) {
      return const RunResult(1, '', 'ERROR: Invalid key name.');
    }
    final key = args.join(' ');
    if (failing.any(key.startsWith)) {
      return const RunResult(1, '', 'ERROR: Access is denied.');
    }
    switch (args.first) {
      case 'query':
        final b = StringBuffer(
          '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\'
          'Windows\\CurrentVersion\\Internet Settings\r\n',
        );
        for (final e in values.entries) {
          b.write('    ${e.key}    ${e.value.type}    ${e.value.data}\r\n');
        }
        b.write(
          '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\'
          'CurrentVersion\\Internet Settings\\Connections\r\n',
        );
        return RunResult(0, '$b');
      case 'add':
        expect(args.sublist(2, 3), ['/v']);
        expect(args.last, '/f');
        final name = args[3];
        final type = args[5];
        var data = args[7];
        if (type == 'REG_DWORD') {
          data = '0x${int.parse(data).toRadixString(16)}';
        }
        values[name] = RegValue(type, data);
        return const RunResult(0, 'The operation completed successfully.\r\n');
      case 'delete':
        final name = args[3];
        if (values.remove(name) == null) {
          return const RunResult(
            1,
            '',
            'ERROR: The system was unable to find the specified registry '
                'key or value.\r\n',
          );
        }
        return const RunResult(0, 'The operation completed successfully.\r\n');
    }
    return const RunResult(1, '', 'ERROR: Invalid syntax.');
  }
}

String _add(String name, String type, String data) =>
    'add $internetSettingsKey /v $name /t $type /d $data /f';
String _del(String name) => 'delete $internetSettingsKey /v $name /f';

void main() {
  late int notified;
  bool notifier() {
    notified++;
    return true;
  }

  setUp(() => notified = 0);

  WindowsSystemProxy proxy(FakeReg r, [WindowsProxyJournal? journal]) =>
      WindowsSystemProxy(
        runner: r,
        journal: journal,
        notify: notifier,
        regExe: _reg,
      );

  test('parses reg query output', () {
    final v = parseRegQuery(
      '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\'
      'Internet Settings\r\n'
      '    CertificateRevocation    REG_DWORD    0x1\r\n'
      '    ProxyEnable    REG_DWORD    0x0\r\n'
      '    ProxyServer    REG_SZ    http=10.0.0.2:3128;https=10.0.0.2:3128\r\n'
      '    AutoConfigURL    REG_SZ    \r\n'
      '    User Agent    REG_SZ    Mozilla/4.0 (compatible; MSIE 8.0)\r\n'
      '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\'
      'Internet Settings\\5.0\r\n',
    );
    expect(v['ProxyEnable'], const RegValue('REG_DWORD', '0x0'));
    expect(
      v['ProxyServer'],
      const RegValue('REG_SZ', 'http=10.0.0.2:3128;https=10.0.0.2:3128'),
    );
    expect(v['AutoConfigURL'], const RegValue('REG_SZ', ''));
    expect(
      v['User Agent'],
      const RegValue('REG_SZ', 'Mozilla/4.0 (compatible; MSIE 8.0)'),
    );
    expect(v.containsKey('ProxyOverride'), isFalse);
    expect(const RegValue('REG_DWORD', '0x10').addData, '16');
    expect(const RegValue('REG_SZ', '0x10').addData, '0x10');
  });

  test('reg.exe path comes from SystemRoot', () {
    expect(
      windowsRegExe({'SystemRoot': r'D:\WIN'}),
      r'D:\WIN\System32\reg.exe',
    );
    expect(windowsRegExe({}), _reg);
  });

  test('enable then restore puts back exactly what was there', () async {
    final before = {
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'ProxyServer': const RegValue('REG_SZ', 'corp.proxy:8080'),
      'ProxyOverride': const RegValue('REG_SZ', '*.corp.example;<local>'),
      'AutoConfigURL': const RegValue('REG_SZ', 'http://wpad.corp/proxy.pac'),
      'MigrateProxy': const RegValue('REG_DWORD', '0x1'),
    };
    final r = FakeReg(Map.of(before));
    final p = proxy(r);

    final on = await p.enable(1080);
    expect(on.ok, isTrue, reason: '$on');
    expect(p.isApplied, isTrue);
    expect(r.calls.first, ['query', internetSettingsKey]);
    expect(r.writes, [
      _add('ProxyServer', 'REG_SZ', '127.0.0.1:1080'),
      _add(
        'ProxyOverride',
        'REG_SZ',
        '<local>;localhost;127.*;10.*;172.16.*;192.168.*',
      ),
      _add('ProxyEnable', 'REG_DWORD', '1'),
      _del('AutoConfigURL'),
    ]);
    expect(on.changed, [
      'ProxyServer',
      'ProxyOverride',
      'ProxyEnable',
      'AutoConfigURL',
    ]);
    expect(r.values['ProxyEnable'], const RegValue('REG_DWORD', '0x1'));
    expect(r.values['ProxyServer']!.data, '127.0.0.1:1080');
    expect(r.values.containsKey('AutoConfigURL'), isFalse);
    expect(notified, 1);

    r.calls.clear();
    final off = await p.restore();
    expect(off.ok, isTrue, reason: '$off');
    expect(p.isApplied, isFalse);
    expect(r.writes, [
      _add('ProxyEnable', 'REG_DWORD', '0'),
      _add('ProxyServer', 'REG_SZ', 'corp.proxy:8080'),
      _add('ProxyOverride', 'REG_SZ', '*.corp.example;<local>'),
      _add('AutoConfigURL', 'REG_SZ', 'http://wpad.corp/proxy.pac'),
    ]);
    expect(r.values, before);
    expect(notified, 2);

    // Nothing left to restore.
    r.calls.clear();
    expect((await p.restore()).changed, isEmpty);
    expect(r.calls, isEmpty);
  });

  test('values that did not exist are deleted on restore', () async {
    final r = FakeReg({
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'CertificateRevocation': const RegValue('REG_DWORD', '0x1'),
    });
    final p = proxy(r);
    await p.enable(1090);
    expect(p.saved, {
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'ProxyServer': null,
      'ProxyOverride': null,
      'AutoConfigURL': null,
    });
    // No PAC configured: nothing to delete.
    expect(r.writes.any((w) => w.contains('AutoConfigURL')), isFalse);

    r.calls.clear();
    final off = await p.restore();
    expect(off.ok, isTrue, reason: '$off');
    expect(r.writes, [
      _add('ProxyEnable', 'REG_DWORD', '0'),
      _del('ProxyServer'),
      _del('ProxyOverride'),
    ]);
    expect(r.values, {
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'CertificateRevocation': const RegValue('REG_DWORD', '0x1'),
    });
  });

  test('enabling twice keeps the original values', () async {
    final r = FakeReg({
      'ProxyEnable': const RegValue('REG_DWORD', '0x1'),
      'ProxyServer': const RegValue('REG_SZ', '10.1.1.1:3128'),
    });
    final p = proxy(r);
    await p.enable(1080);
    await p.enable(1081); // e.g. reconnect on another port
    expect(r.values['ProxyServer']!.data, '127.0.0.1:1081');
    expect(p.saved['ProxyServer'], const RegValue('REG_SZ', '10.1.1.1:3128'));
    await p.restore();
    expect(r.values, {
      'ProxyEnable': const RegValue('REG_DWORD', '0x1'),
      'ProxyServer': const RegValue('REG_SZ', '10.1.1.1:3128'),
    });
  });

  test('ProxyServer value: HTTP proxy by default, optional socks5 scheme', () {
    final r = FakeReg();
    expect(proxy(r).proxyServerFor(1080), '127.0.0.1:1080');
    expect(
      WindowsSystemProxy(
        runner: r,
        mode: WindowsProxyMode.socks5,
      ).proxyServerFor(1080),
      'socks=socks5://127.0.0.1:1080',
    );
  });

  test('unreadable key: reported, nothing changed', () async {
    final r = FakeReg()..failing.add('query');
    final p = proxy(r);
    final res = await p.enable(1080);
    expect(res.ok, isFalse);
    expect(res.failed.keys, ['*']);
    expect(r.writes, isEmpty);
    expect(p.isApplied, isFalse);
    expect(notified, 0);
  });

  test('partial failure: the rest is applied and still restored', () async {
    final r = FakeReg({
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'AutoConfigURL': const RegValue('REG_SZ', 'http://wpad/pac'),
    })..failing.add('delete $internetSettingsKey /v AutoConfigURL');
    final p = proxy(r);
    final res = await p.enable(1080);
    expect(res.ok, isFalse);
    expect(res.changed, ['ProxyServer', 'ProxyOverride', 'ProxyEnable']);
    expect(res.failed.keys, ['AutoConfigURL']);
    expect(p.isApplied, isTrue);
    expect(r.values['ProxyEnable']!.data, '0x1');

    r.failing.clear();
    final back = await p.restore();
    expect(back.ok, isTrue, reason: '$back');
    expect(p.isApplied, isFalse);
    expect(r.values, {
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'AutoConfigURL': const RegValue('REG_SZ', 'http://wpad/pac'),
    });
  });

  test('restore failure keeps only the failed value for a retry', () async {
    final r = FakeReg({'ProxyEnable': const RegValue('REG_DWORD', '0x0')});
    final p = proxy(r);
    await p.enable(1080);
    r.failing.add('add $internetSettingsKey /v ProxyEnable');
    final res = await p.restore();
    expect(res.ok, isFalse);
    expect(res.failed.keys, ['ProxyEnable']);
    expect(p.saved, {'ProxyEnable': const RegValue('REG_DWORD', '0x0')});
    expect(r.values.containsKey('ProxyServer'), isFalse);

    r.failing.clear();
    r.calls.clear();
    final retry = await p.restore();
    expect(retry.ok, isTrue);
    expect(r.writes, [_add('ProxyEnable', 'REG_DWORD', '0')]);
    expect(p.isApplied, isFalse);
    expect(r.values, {'ProxyEnable': const RegValue('REG_DWORD', '0x0')});
  });

  test('journal survives a crash and recover() restores', () async {
    final dir = await Directory.systemTemp.createTemp('singlink_winjournal');
    addTearDown(() => dir.delete(recursive: true));
    final journal = WindowsProxyJournal(File('${dir.path}/j.json'));
    final before = {
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'ProxyServer': const RegValue('REG_SZ', 'old:8080'),
      'AutoConfigURL': const RegValue('REG_SZ', 'http://wpad/pac'),
    };
    final r = FakeReg(Map.of(before));
    await proxy(r, journal).enable(1080);
    expect(await journal.file.exists(), isTrue);
    expect(await journal.load(), {
      'ProxyEnable': const RegValue('REG_DWORD', '0x0'),
      'ProxyServer': const RegValue('REG_SZ', 'old:8080'),
      'ProxyOverride': null,
      'AutoConfigURL': const RegValue('REG_SZ', 'http://wpad/pac'),
    });

    // "Crash": a fresh instance on next launch.
    final next = proxy(r, journal);
    final res = await next.recover();
    expect(res.ok, isTrue, reason: '$res');
    expect(res.changed, isNotEmpty);
    expect(r.values, before);
    expect(next.isApplied, isFalse);
    expect(await journal.file.exists(), isFalse);

    // Clean state: recover is a no-op.
    r.calls.clear();
    expect((await next.recover()).changed, isEmpty);
    expect(r.calls, isEmpty);
  });

  test('a corrupt or foreign journal is ignored', () async {
    final dir = await Directory.systemTemp.createTemp('singlink_winjournal');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/j.json');
    final journal = WindowsProxyJournal(f);
    await f.writeAsString('{not json');
    expect(await journal.load(), isEmpty);
    // A macOS (networksetup) journal has no "kind": wininet.
    await f.writeAsString('{"version":1,"services":{"Wi-Fi":{}}}');
    expect(await journal.load(), isEmpty);
    final r = FakeReg();
    expect((await proxy(r, journal).recover()).changed, isEmpty);
    expect(r.calls, isEmpty);
  });
}
