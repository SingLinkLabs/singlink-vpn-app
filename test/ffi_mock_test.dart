// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// Exercises the real FFI + isolate path against a C mock of libsinglink
// compiled on the fly. Skipped when no C compiler is available.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/singlink_bindings.dart';
import 'package:singlink_vpn/core/singlink_service.dart';

void main() {
  late Directory tmp;
  String? libPath;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('singlink_ffi_mock');
    final out = '${tmp.path}/$libFileName';
    final args = Platform.isMacOS
        ? ['-dynamiclib', '-o', out, 'test/fixtures/mock_libsinglink.c']
        : ['-shared', '-fPIC', '-o', out, 'test/fixtures/mock_libsinglink.c'];
    try {
      final r = await Process.run('cc', args);
      if (r.exitCode == 0) libPath = out;
    } on ProcessException {
      libPath = null;
    }
  });

  tearDownAll(() => tmp.delete(recursive: true));

  test('service round-trips every SingLink call through FFI', () async {
    if (libPath == null) {
      markTestSkipped('no C compiler');
      return;
    }
    final loc = locateSingLinkLib(candidates: ['/nope/$libFileName', libPath!]);
    expect(loc.path, libPath);

    final s = SingLinkService.at(libPath!);
    expect(s.available, isTrue);
    final v = await s.version();
    expect(v.version, '1.0.0-mock');
    expect(v.protocol, 'SingLink Beta');

    final bad = await s.parseLink('sl3://x');
    expect(bad.ok, isFalse);
    expect(bad.error, 'not a singlink link');

    final good = await s.parseLink('singlink://h.example:443');
    expect(good.ok, isTrue);
    expect(good.profile!.server, 'h.example:443');
    expect(good.profile!.maxConns, 8);

    expect((await s.exitIP(timeoutMs: 5000)).error, 'not running');

    expect(
      (await s.start(link: 'singlink://h', listen: '127.0.0.1:9')).error,
      'bad cfg',
    );
    expect(
      (await s.start(link: 'singlink://h', listen: '127.0.0.1:1080')).ok,
      isTrue,
    );

    final st = await s.status();
    expect(st.running, isTrue);
    expect(st.down, 20);
    // conns echoes the mock's SingLinkFree counter: every prior reply freed.
    expect(st.conns, 6);

    final p = await s.probe(
      'https://www.gstatic.com/generate_204',
      timeoutMs: 8000,
    );
    expect(p.ok, isTrue);
    expect(p.latencyMs, 8000); // timeout int passed through intact

    final ip = await s.exitIP(timeoutMs: 8007); // 8007 % 256 == 71
    expect(ip.ok, isTrue);
    expect(ip.ip, '203.0.113.71');

    expect((await s.stop()).ok, isTrue);
    expect((await s.status()).running, isFalse);
  });
}
