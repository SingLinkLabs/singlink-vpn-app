// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// Real-registry round trip for WindowsSystemProxy: runs the actual reg.exe
// and InternetSetOptionW. It changes the current user's proxy settings for a
// moment, so it only runs on Windows with SINGLINK_WINDOWS_REGISTRY_TEST=1
// (set by the CI windows job on a throwaway runner):
//
//   set SINGLINK_WINDOWS_REGISTRY_TEST=1
//   flutter test test\windows_registry_smoke_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/platform/windows.dart';

void main() {
  final enabled =
      Platform.isWindows &&
      Platform.environment['SINGLINK_WINDOWS_REGISTRY_TEST'] == '1';

  test(
    'enable/restore round trip on the real registry',
    () async {
      const runner = IoProcessRunner();
      final reg = windowsRegExe();
      Future<Map<String, RegValue>> snapshot() async {
        final r = await runner.run(reg, ['query', internetSettingsKey]);
        expect(r.ok, isTrue, reason: r.stderr);
        final all = parseRegQuery(r.stdout);
        return {
          for (final n in managedProxyValues)
            if (all.containsKey(n)) n: all[n]!,
        };
      }

      // Start from a state with a PAC URL so its save/clear/restore runs.
      final original = await snapshot();
      final pac = original[autoConfigUrlValue];
      await runner.run(reg, [
        'add',
        internetSettingsKey,
        '/v',
        autoConfigUrlValue,
        '/t',
        'REG_SZ',
        '/d',
        'http://wpad.invalid/proxy.pac',
        '/f',
      ]);
      final before = await snapshot();

      final dir = await Directory.systemTemp.createTemp('singlink_regtest');
      addTearDown(() => dir.delete(recursive: true));
      final p = WindowsSystemProxy(
        runner: runner,
        journal: WindowsProxyJournal(File('${dir.path}\\j.json')),
        notify: notifyWinInetSettingsChanged,
        regExe: reg,
      );
      try {
        final on = await p.enable(18080);
        expect(on.ok, isTrue, reason: '$on');
        expect(p.notifyFailed, isFalse);
        final applied = await snapshot();
        expect(applied[proxyEnableValue], const RegValue('REG_DWORD', '0x1'));
        expect(
          applied[proxyServerValue],
          const RegValue('REG_SZ', '127.0.0.1:18080'),
        );
        expect(
          applied[proxyOverrideValue],
          const RegValue('REG_SZ', defaultProxyOverride),
        );
        expect(applied.containsKey(autoConfigUrlValue), isFalse);
      } finally {
        final off = await p.restore();
        expect(off.ok, isTrue, reason: '$off');
      }
      expect(await snapshot(), before);

      // Put the runner's original PAC setting back.
      if (pac == null) {
        await runner.run(reg, [
          'delete',
          internetSettingsKey,
          '/v',
          autoConfigUrlValue,
          '/f',
        ]);
      } else {
        await runner.run(reg, [
          'add',
          internetSettingsKey,
          '/v',
          autoConfigUrlValue,
          '/t',
          pac.type,
          '/d',
          pac.addData,
          '/f',
        ]);
      }
      expect(await snapshot(), original);
    },
    skip: enabled
        ? false
        : 'Windows only, set SINGLINK_WINDOWS_REGISTRY_TEST=1 to run',
  );
}
