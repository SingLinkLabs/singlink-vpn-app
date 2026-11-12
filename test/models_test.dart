// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/singlink_bindings.dart';
import 'package:singlink_vpn/core/singlink_service.dart';
import 'package:singlink_vpn/models/core_status.dart';
import 'package:singlink_vpn/models/profile.dart';

const link = 'singlink://example-token@hk1.example.com:443?name=HK%201';

Map<String, dynamic> okReply() => decodeCoreJson(
  '''
{"ok":true,"profile":{"name":"HK 1","server":"hk1.example.com:443",
 "transport":"tls","sni":"cdn.example.com","subject":"a1b2c3","plan":2,
 "expiresAt":1893456000,"caps":["tcp","udp"],"rateKbps":20000,"maxConns":64}}''',
);

void main() {
  group('SingLinkParseLink reply', () {
    test('ok reply becomes a Profile', () {
      final r = ParseLinkResult.fromJson('  $link ', okReply());
      expect(r.ok, isTrue);
      final p = r.profile!;
      expect(p.link, link);
      expect(p.name, 'HK 1');
      expect(p.server, 'hk1.example.com:443');
      expect(p.transport, 'tls');
      expect(p.sni, 'cdn.example.com');
      expect(p.subject, 'a1b2c3');
      expect(p.plan, 2);
      expect(p.expiresAt, DateTime.fromMillisecondsSinceEpoch(1893456000000));
      expect(p.isExpired, isFalse);
      expect(p.caps, ['tcp', 'udp']);
      expect(p.rateKbps, 20000);
      expect(p.maxConns, 64);
    });

    test('error reply', () {
      final r = ParseLinkResult.fromJson(
        link,
        decodeCoreJson('{"ok":false,"error":"bad signature"}'),
      );
      expect(r.ok, isFalse);
      expect(r.error, 'bad signature');
    });

    test('ok:true without profile is treated as failure', () {
      final r = ParseLinkResult.fromJson(link, {'ok': true});
      expect(r.ok, isFalse);
      expect(r.error, isNotEmpty);
    });

    test('tolerates missing / odd fields', () {
      final p = Profile.fromCore(link, {
        'server': 'h:1',
        'plan': '3',
        'expiresAt': 0,
        'caps': null,
      });
      expect(p.displayName, 'h:1');
      expect(p.plan, 3);
      expect(p.expiresAt, isNull);
      expect(p.isExpired, isFalse);
      expect(p.caps, isEmpty);
    });

    test('expired profile', () {
      final p = Profile.fromCore(link, {'server': 'h:1', 'expiresAt': 1000});
      expect(p.isExpired, isTrue);
    });

    test('non-JSON core output is wrapped as an error', () {
      expect(decodeCoreJson('panic: boom')['ok'], isFalse);
      expect(decodeCoreJson('[1,2]')['ok'], isFalse);
    });
  });

  test('Profile persistence round-trip', () {
    final p = ParseLinkResult.fromJson(link, okReply()).profile!;
    final back = Profile.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
    expect(back.toJson(), p.toJson());
    expect(back.id, p.id);
  });

  test('AppStore save/load', () async {
    final dir = await Directory.systemTemp.createTemp('singlink_store_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = AppStore(File('${dir.path}/sub/state.json'));
    expect((await store.load()).profiles, isEmpty);

    final p = ParseLinkResult.fromJson(link, okReply()).profile!;
    await store.save(
      AppState(
        profiles: [p],
        selectedId: p.id,
        autoSelect: false,
        lastUsedId: p.id,
        port: 7890,
        systemProxy: false,
      ),
    );
    final s = await store.load();
    expect(s.profiles.single.server, 'hk1.example.com:443');
    expect(s.selectedId, p.id);
    expect(s.autoSelect, isFalse);
    expect(s.lastUsedId, p.id);
    expect(s.port, 7890);
    expect(s.listen, '127.0.0.1:7890');
    expect(s.systemProxy, isFalse);

    await store.file.writeAsString('{corrupt');
    final fresh = await store.load();
    expect(fresh.port, defaultPort);
    expect(fresh.systemProxy, isTrue, reason: 'system-wide mode defaults on');
    expect(fresh.autoSelect, isTrue);

    // v1 file from the previous client: "listen" becomes the port.
    await store.file.writeAsString('{"version":1,"listen":"127.0.0.1:1090"}');
    expect((await store.load()).port, 1090);
  });

  test('status / probe / op replies', () {
    final s = CoreStatus.fromJson(
      decodeCoreJson(
        '{"running":true,"listen":"127.0.0.1:1080","up":1024,"down":2048,'
        '"conns":3,"since":1700000000,"lastError":""}',
      ),
    );
    expect(s.running, isTrue);
    expect(s.up, 1024);
    expect(s.down, 2048);
    expect(s.conns, 3);
    expect(s.since, DateTime.fromMillisecondsSinceEpoch(1700000000000));

    final ok = ProbeResult.fromJson({
      'ok': true,
      'status': 204,
      'latencyMs': 87,
    });
    expect([ok.ok, ok.status, ok.latencyMs], [true, 204, 87]);
    final bad = ProbeResult.fromJson({'ok': false, 'error': 'timeout'});
    expect([bad.ok, bad.error], [false, 'timeout']);

    expect(OpResult.fromJson({'ok': true}).ok, isTrue);
    expect(OpResult.fromJson({'ok': false, 'error': 'x'}).error, 'x');
    expect(
      CoreVersion.fromJson({
        'version': '1.0.0-draft',
        'protocol': 'SingLink Beta',
      }).toString(),
      '1.0.0-draft · SingLink Beta',
    );
    expect(
      CoreVersion.fromJson({
        'version': '1.0.0-draft',
        'protocol': 'SingLink/1',
      }).protocol,
      'SingLink Beta',
    );
    final ip = ExitIpResult.fromJson({'ok': true, 'ip': '203.0.113.7'});
    expect([ip.ok, ip.ip], [true, '203.0.113.7']);
    final noIp = ExitIpResult.fromJson({'ok': false, 'error': 'not running'});
    expect([noIp.ok, noIp.ip, noIp.error], [false, '', 'not running']);
    expect(ExitIpResult.fromJson({'ok': true}).ok, isFalse);
  });

  test('service without core fails gracefully', () async {
    final svc = SingLinkService.unavailable();
    expect(svc.available, isFalse);
    final r = await svc.parseLink(link);
    expect(r.ok, isFalse);
    expect((await svc.start(link: link, listen: '127.0.0.1:1080')).ok, isFalse);
    expect((await svc.exitIP()).ok, isFalse);
  });

  test(
    'library candidates: bundle, SINGLINK_LIB, app core, then protocol repo',
    () {
      final c = singLinkLibCandidates(
        executable:
            '/x/singlink-vpn-app/build/macos/Build/Products/Debug/SingLinkVPN.app/Contents/MacOS/SingLinkVPN',
        environment: {'SINGLINK_LIB': '/opt/libsinglink.dylib'},
        workingDirectory: '/x/singlink-vpn-app',
      );
      if (Platform.isMacOS) {
        expect(
          c[0],
          '/x/singlink-vpn-app/build/macos/Build/Products/Debug/SingLinkVPN.app/Contents/Frameworks/libsinglink.dylib',
        );
        expect(c[1], '/opt/libsinglink.dylib');
        expect(c[2], '/x/singlink-vpn-app/core/build/macos/libsinglink.dylib');
        expect(c[3], '/x/singlink-protocol/build/libsinglink.dylib');
        expect(c.toSet().length, c.length);
        expect(
          c.where(
            (p) => p.endsWith('/singlink-protocol/build/libsinglink.dylib'),
          ),
          isNotEmpty,
        );
      }
      final loc = locateSingLinkLib(
        candidates: ['/nonexistent/libsinglink.dylib'],
      );
      expect(loc.found, isFalse);
      expect(loc.expectedPath, '/nonexistent/libsinglink.dylib');
    },
  );

  test('validatePort', () {
    expect(validatePort('1080'), isNull);
    expect(validatePort(' 65535 '), isNull);
    expect(validatePort('0'), isNotNull);
    expect(validatePort('70000'), isNotNull);
    expect(validatePort('abc'), isNotNull);
  });
}
