// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/app_store.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/error_messages.dart';
import 'package:singlink_vpn/core/system_proxy.dart';

import 'support/fakes.dart';

void main() {
  late Directory dir;
  late FakeCore core;
  late FakeRunner runner;
  late ClientController c;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('singlink_ctrl');
    core = FakeCore();
    runner = FakeRunner(services: 'Wi-Fi\n');
    c = ClientController(
      core: core,
      store: AppStore(File('${dir.path}/state.json')),
      systemProxy: SystemProxyManager(runner: runner),
    );
    await c.init();
  });

  tearDown(() async {
    c.dispose();
    await dir.delete(recursive: true);
  });

  test('import validates scheme and stores the server', () async {
    expect((await c.importLink('')), isNotNull);
    expect((await c.importLink('sl3://old'))!.message, contains('singlink://'));
    expect(await c.importLink('singlink://a#Hong Kong 01'), isNull);
    expect(
      (await c.importLink('singlink://a#Hong Kong 01'))!.message,
      'This server is already in your list.',
    );
    expect(c.profiles.single.name, 'Hong Kong 01');
    expect(c.target!.name, 'Hong Kong 01');
  });

  test('connect sets the system proxy, disconnect restores it', () async {
    await c.importLink('singlink://a#Hong Kong 01');
    await c.connect();
    expect(c.conn, ConnState.connected);
    expect(core.calls, contains('start 127.0.0.1:1080'));
    expect(runner.writes, [
      '-setsocksfirewallproxy Wi-Fi 127.0.0.1 1080',
      '-setsocksfirewallproxystate Wi-Fi on',
    ]);
    expect(c.proxyWarning, isNull);
    await pumpEventQueue();
    expect(c.exitIp, '203.0.113.7');
    expect(c.latencyMs, 42);

    runner.calls.clear();
    await c.disconnect();
    expect(c.conn, ConnState.disconnected);
    expect(runner.writes, ['-setsocksfirewallproxystate Wi-Fi off']);
    expect(core.calls.last, 'stop');
    expect(c.exitIp, isNull);
  });

  test('system proxy failure warns but stays connected', () async {
    runner.failing.add('-listallnetworkservices');
    await c.importLink('singlink://a#Tokyo');
    await c.connect();
    expect(c.conn, ConnState.connected);
    expect(
      c.proxyWarning,
      "Couldn't set the system proxy. Set SOCKS 127.0.0.1:1080 manually in System Settings.",
    );
    await c.disconnect();
  });

  test('system proxy off: networksetup never runs', () async {
    await c.setSystemProxy(false);
    await c.importLink('singlink://a#Tokyo');
    await c.connect();
    await c.disconnect();
    expect(runner.calls, isEmpty);
  });

  test('toggling the switch while connected applies / restores', () async {
    await c.setSystemProxy(false);
    await c.importLink('singlink://a#Tokyo');
    await c.connect();
    await c.setSystemProxy(true);
    expect(runner.writes.last, '-setsocksfirewallproxystate Wi-Fi on');
    await c.setSystemProxy(false);
    expect(runner.writes.last, '-setsocksfirewallproxystate Wi-Fi off');
    await c.disconnect();
  });

  test('start failure becomes a friendly message', () async {
    core.startError = 'singlink: token expired';
    await c.importLink('singlink://a#Tokyo');
    await c.connect();
    expect(c.conn, ConnState.disconnected);
    expect(c.error!.message, msgExpired);
    expect(c.error!.detail, 'singlink: token expired');
    expect(runner.calls, isEmpty);
  });

  test('quick connect uses the last-used server', () async {
    await c.importLink('singlink://a#Hong Kong 01');
    await c.importLink('singlink://b#Japan 02');
    expect(c.autoSelect, isTrue);
    expect(c.target!.name, 'Hong Kong 01');
    await c.chooseServer(c.profiles[1].id);
    expect(c.target!.name, 'Japan 02');
    await c.connect();
    await c.disconnect();
    await c.chooseAuto();
    expect(c.target!.name, 'Japan 02', reason: 'last used');
  });

  test('switching location while connected reconnects', () async {
    await c.importLink('singlink://a#Hong Kong 01');
    await c.importLink('singlink://b#Japan 02');
    await c.connect();
    core.calls.clear();
    await c.chooseServer(c.profiles[1].id);
    expect(core.calls, ['stop', 'start 127.0.0.1:1080']);
    expect(c.isConnected, isTrue);
    expect(c.target!.name, 'Japan 02');
    await c.disconnect();
  });

  test('shutdown restores the proxy and stops the core', () async {
    await c.importLink('singlink://a#Tokyo');
    await c.connect();
    await c.shutdown();
    expect(runner.writes.last, '-setsocksfirewallproxystate Wi-Fi off');
    expect(core.running, isFalse);
    expect(c.conn, ConnState.disconnected);
  });

  test('port can only change while disconnected', () async {
    expect(await c.setPort(1090), isNull);
    expect(c.listen, '127.0.0.1:1090');
    await c.importLink('singlink://a#Tokyo');
    await c.connect();
    expect(await c.setPort(1080), isNotNull);
    await c.disconnect();
  });
}
