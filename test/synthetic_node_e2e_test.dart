// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// End-to-end through the real Go core (C ABI + Dart FFI + isolates) and a
// real SingLink node, without any external server: core/testnode starts a
// throwaway node on loopback with freshly generated keys, and the targets
// are local HTTP servers. Runs wherever the core library has been built
// (CI: `make -C core macos`); real_core_test.dart remains the optional test
// against a live node.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/singlink_service.dart';

String get _library =>
    Platform.environment['SINGLINK_SYNTHETIC_ABI_LIB'] ??
    (Platform.isWindows
        ? 'core/build/windows/singlink.dll'
        : 'core/build/macos/libsinglink.dylib');

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  // The node's replay store is a Unix file store; Windows CI covers the
  // core through the parser and DLL tests instead.
  final skip = Platform.isWindows
      ? 'synthetic node uses the Unix replay store'
      : !File(_library).existsSync()
      ? 'build the core first (make -C core macos)'
      : false;

  test(
    'connect, probe and relay through the real core and a loopback node',
    () async {
      final node = await Process.start('go', [
        'run',
        './testnode',
      ], workingDirectory: 'core');
      addTearDown(() async {
        await node.stdin.close();
        node.kill();
        await node.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () => -1,
        );
      });
      final stderr = StringBuffer();
      node.stderr.transform(utf8.decoder).listen(stderr.write);
      final lines = node.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final ready = await lines.first.timeout(
        const Duration(seconds: 120),
        onTimeout: () => fail('test node did not start: $stderr'),
      );
      final link = (jsonDecode(ready) as Map)['link'] as String;

      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      http.listen((req) {
        if (req.uri.path == '/generate_204') {
          req.response.statusCode = 204;
        } else {
          req.response.write('synthetic-e2e-ok');
        }
        req.response.close();
      });

      final s = SingLinkService.at(File(_library).absolute.path);
      expect(s.available, isTrue, reason: s.location.errors.join('\n'));
      expect((await s.parseLink(link)).ok, isTrue);

      final port = await _freePort();
      final listen = '127.0.0.1:$port';
      // App F-01: authentication is the default for the local port.
      final started = await s.start(link: link, listen: listen);
      expect(started.ok, isTrue, reason: started.error);
      addTearDown(s.stop);
      final login = started.credentials!;
      expect(login.username.length, greaterThanOrEqualTo(16));
      expect(login.password.length, greaterThanOrEqualTo(16));
      expect('$login', isNot(contains(login.password)));

      // A client without the session's credentials is refused.
      final anon = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final anonReply = <int>[];
      final anonDone = anon.listen(anonReply.addAll).asFuture<void>();
      anon.add([5, 1, 0]);
      await anonDone.timeout(const Duration(seconds: 15));
      expect(anonReply.take(2), [5, 0xFF]);

      final probe = await s.probe(
        'http://127.0.0.1:${http.port}/generate_204',
        timeoutMs: 15000,
      );
      expect(probe.ok, isTrue, reason: probe.error);
      expect(probe.status, 204);

      // SOCKS5 CONNECT with the session's username and password (RFC 1929),
      // as an app configured for manual proxy use does.
      final sock = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final bytes = <int>[];
      final done = sock.listen(bytes.addAll).asFuture<void>();
      sock.add([5, 1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sock.add([
        1,
        login.username.length,
        ...login.username.codeUnits,
        login.password.length,
        ...login.password.codeUnits,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sock.add([5, 1, 0, 1, 127, 0, 0, 1, http.port >> 8, http.port & 0xff]);
      sock.add('GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'.codeUnits);
      await done.timeout(const Duration(seconds: 15));
      expect(bytes.take(4), [5, 2, 1, 0], reason: 'method 2, login accepted');
      final text = String.fromCharCodes(bytes.skip(14));
      expect(text, contains('HTTP/1.'));
      expect(text, contains('synthetic-e2e-ok'));

      final st = await s.status();
      expect(st.running, isTrue);
      expect(st.listen, listen);
      expect(st.down, greaterThan(0));

      expect((await s.stop()).ok, isTrue);
      expect((await s.status()).running, isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 180)),
  );
}
