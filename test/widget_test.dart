import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/singlink_service.dart';
import 'package:singlink_vpn/main.dart';

import 'support/fakes.dart';

Future<ClientController> _controller(
  WidgetTester tester,
  VpnCore core, {
  List<String> links = const [],
}) async {
  final c = ClientController(core: core, store: MemoryStore());
  await c.init();
  for (final l in links) {
    await c.importLink(l);
  }
  addTearDown(c.dispose);
  return c;
}

void main() {
  testWidgets('main screen, disconnected: VPN wording, no proxy jargon', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = await _controller(
      tester,
      FakeCore(),
      links: ['singlink://a#香港 01'],
    );
    await tester.pumpWidget(SingLinkVpnApp(controller: c));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('星連VPN'), findsOneWidget);
    expect(find.text('未受保護'), findsOneWidget);
    expect(find.text('連線'), findsOneWidget);
    expect(find.text('你的 IP：—'), findsOneWidget);
    expect(find.text('香港'), findsOneWidget);
    expect(find.text('🇭🇰'), findsOneWidget);
    expect(find.text('快速連線'), findsOneWidget);
    expect(find.text('下載'), findsOneWidget);
    expect(find.text('上傳'), findsOneWidget);
    expect(find.byTooltip('設定'), findsOneWidget);

    for (final jargon in [
      'SOCKS',
      'socks5',
      'singlink://',
      'sl3://',
      '127.0.0.1',
      ':1080',
    ]) {
      expect(find.textContaining(jargon), findsNothing, reason: jargon);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('location sheet lists servers with flag and latency dash', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await _controller(
      tester,
      FakeCore(),
      links: ['singlink://a#香港 01', 'singlink://b#Tokyo 2'],
    );
    await tester.pumpWidget(SingLinkVpnApp(controller: c));
    await tester.tap(find.text('香港'));
    await tester.pumpAndSettle();
    expect(find.text('選擇地區'), findsOneWidget);
    expect(find.text('快速連線（自動）'), findsOneWidget);
    expect(find.text('東京'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('—')),
      findsNWidgets(2),
      reason: 'no invented latency',
    );
  });

  testWidgets('settings: add server, system proxy on, advanced, about', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await _controller(tester, FakeCore());
    await tester.pumpWidget(SingLinkVpnApp(controller: c));
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();
    expect(find.text('新增伺服器'), findsOneWidget);
    expect(find.text('系統全局代理'), findsOneWidget);
    expect(find.text('本機代理'), findsOneWidget);
    expect(find.text('127.0.0.1:1080'), findsOneWidget);
    expect(find.text('1.0.0-draft'), findsOneWidget);
    expect(find.text('SingLink/1'), findsOneWidget);
  });

  testWidgets('app starts without the core and shows the banner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = await _controller(
      tester,
      SingLinkService.unavailable(
        searched: [
          '/Applications/SingLinkVPN.app/Contents/Frameworks/libsinglink.dylib',
          '/x/singlink-protocol/build/libsinglink.dylib',
        ],
      ),
    );
    await tester.pumpWidget(SingLinkVpnApp(controller: c));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('找不到核心元件 libsinglink.dylib'), findsOneWidget);
    expect(
      find.textContaining('Contents/Frameworks/libsinglink.dylib'),
      findsOneWidget,
    );
    expect(find.text('未受保護'), findsOneWidget);
    expect(find.text('尚未新增伺服器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
