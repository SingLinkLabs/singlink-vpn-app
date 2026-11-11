// End-to-end test against the real Go core and a live SingLink node.
//
// Skipped unless both are provided:
//   SINGLINK_LIB=../singlink-protocol/build/libsinglink.dylib
//   SINGLINK_TEST_LINK=$(singlink demo -link-only -node 127.0.0.1:18443 | sed -n 3p)
//
// It goes through the same SingLinkService / isolate path the UI uses, then
// sends a real HTTP request through the local SOCKS5 port the core opens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/singlink_service.dart';

void main() {
  final lib = Platform.environment['SINGLINK_LIB'];
  final link = Platform.environment['SINGLINK_TEST_LINK'];
  final skip = (lib == null || link == null)
      ? 'set SINGLINK_LIB and SINGLINK_TEST_LINK to run'
      : null;

  test(
    'connect, probe, exit IP and relay through the real core',
    () async {
      final s = SingLinkService.at(lib!);
      expect(s.available, isTrue, reason: s.location.errors.join('\n'));
      expect((await s.version()).protocol, 'SingLink/1');

      final parsed = await s.parseLink(link!);
      expect(parsed.ok, isTrue, reason: parsed.error);

      const listen = '127.0.0.1:18090';
      final started = await s.start(link: link, listen: listen);
      expect(started.ok, isTrue, reason: started.error);
      addTearDown(s.stop);

      final probe = await s.probe('https://www.gstatic.com/generate_204');
      expect(probe.ok, isTrue, reason: probe.error);
      expect(probe.status, 204);

      final ip = await s.exitIP(timeoutMs: 15000);
      expect(ip.ok, isTrue, reason: ip.error);
      expect(InternetAddress.tryParse(ip.ip), isNotNull, reason: ip.ip);

      // A plain SOCKS5 CONNECT through the port, as a browser would do.
      final sock = await Socket.connect('127.0.0.1', 18090);
      final bytes = <int>[];
      final done = sock.listen(bytes.addAll).asFuture<void>();
      sock.add([5, 1, 0]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      const host = 'example.com';
      sock.add([5, 1, 0, 3, host.length, ...host.codeUnits, 0, 80]);
      sock.add('GET / HTTP/1.0\r\nHost: example.com\r\n\r\n'.codeUnits);
      await done.timeout(const Duration(seconds: 15));
      final text = String.fromCharCodes(bytes.skip(12));
      expect(text, contains('HTTP/1.'));
      expect(text.toLowerCase(), contains('example domain'));

      final st = await s.status();
      expect(st.running, isTrue);
      expect(st.listen, listen);
      expect(st.down, greaterThan(0));

      expect((await s.stop()).ok, isTrue);
      expect((await s.status()).running, isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
