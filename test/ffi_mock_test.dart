// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
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
        : Platform.isWindows
        ? ['-shared', '-o', out, 'test/fixtures/mock_libsinglink.c']
        : ['-shared', '-fPIC', '-o', out, 'test/fixtures/mock_libsinglink.c'];
    try {
      // Windows CI has MinGW gcc (installed for the cgo core build).
      final r = await Process.run(Platform.isWindows ? 'gcc' : 'cc', args);
      if (r.exitCode == 0) libPath = out;
    } on ProcessException {
      libPath = null;
    }
  });

  // Windows cannot delete a DLL this process (and its isolates) still has
  // loaded, and Dart never unloads it. Retry briefly, then leave only the
  // OS temp folder behind on Windows instead of failing the whole suite.
  tearDownAll(() async {
    for (var attempt = 0; ; attempt++) {
      try {
        await tmp.delete(recursive: true);
        return;
      } on FileSystemException {
        if (!Platform.isWindows) rethrow;
        if (attempt >= 4) {
          printOnFailure('left loaded mock DLL in ${tmp.path}');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  test('service round-trips every SingLink call through FFI', () async {
    if (libPath == null) {
      // CI sets SINGLINK_REQUIRE_FFI_MOCK so the payload checks cannot skip.
      if (Platform.environment['SINGLINK_REQUIRE_FFI_MOCK'] == '1') {
        fail('SINGLINK_REQUIRE_FFI_MOCK=1 but the C mock could not be built');
      }
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
    // App F-01: the default start sends {"link","listen","auth":true} and
    // gets the session's login back.
    final started = await s.start(
      link: 'singlink://h',
      listen: '127.0.0.1:1080',
    );
    expect(started.ok, isTrue, reason: started.error);
    expect(started.credentials!.username, 'mock-user-0123456');
    expect(started.credentials!.password, 'mock-pass-0123456');
    expect('${started.credentials}', isNot(contains('mock-pass')));

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

    // System-proxy mode: an explicit "auth":false, and no login.
    final open = await s.start(
      link: 'singlink://h',
      listen: '127.0.0.1:1080',
      auth: false,
    );
    expect(open.ok, isTrue, reason: open.error);
    expect(open.credentials, isNull);
    expect((await s.stop()).ok, isTrue);
  });
}
