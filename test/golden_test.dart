// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

// Renders the main screen with fake data so the owner can look at it without
// running the app. Regenerate after UI changes:
//   flutter test --update-goldens test/golden_test.dart
// PNGs: test/goldens/main_*.png (macOS fonts; other OSes may differ).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/core/system_proxy.dart';
import 'package:singlink_vpn/main.dart';

import 'support/fakes.dart';
import 'support/fonts.dart';

void main() {
  setUpAll(loadGoldenFonts);

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    final name = mode == ThemeMode.light ? 'light' : 'dark';

    testWidgets('main screen connected ($name)', (tester) async {
      tester.view.physicalSize = const Size(840, 1520); // 420x760 @2x
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      var now = DateTime(2026, 11, 12, 9, 0, 0);
      final core = FakeCore();
      final c = ClientController(
        core: core,
        store: MemoryStore(),
        clock: () => now,
      );
      await c.init();
      await c.importLink('singlink://a#Hong Kong 01');
      await c.importLink('singlink://b#Japan Tokyo 02');

      await tester.pumpWidget(SingLinkVpnApp(controller: c, themeMode: mode));
      await c.connect();
      await tester.pump();
      // Two status samples one second apart -> live speed.
      core.down = 812 * 1024 * 1024;
      core.up = 46 * 1024 * 1024;
      now = now.add(const Duration(hours: 1, minutes: 23, seconds: 44));
      await tester.pump(const Duration(seconds: 1));
      core.down += (2.4 * 1024 * 1024).round();
      core.up += 318 * 1024;
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 450));

      expect(find.text('Protected'), findsOneWidget);
      expect(find.text('01:23:45'), findsOneWidget);
      expect(find.text('Your IP: 203.0.113.7'), findsOneWidget);

      await expectLater(
        find.byType(SingLinkVpnApp),
        matchesGoldenFile('goldens/main_connected_$name.png'),
      );

      await c.disconnect();
      c.dispose();
    });

    testWidgets('main screen disconnected ($name)', (tester) async {
      tester.view.physicalSize = const Size(840, 1520);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final c = ClientController(core: FakeCore(), store: MemoryStore());
      await c.init();
      await c.importLink('singlink://a#Hong Kong 01');
      await tester.pumpWidget(SingLinkVpnApp(controller: c, themeMode: mode));
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(
        find.byType(SingLinkVpnApp),
        matchesGoldenFile('goldens/main_disconnected_$name.png'),
      );
      c.dispose();
    });
  }

  testWidgets('location sheet while connected (light)', (tester) async {
    tester.view.physicalSize = const Size(840, 1520);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final c = ClientController(core: FakeCore(), store: MemoryStore());
    await c.init();
    for (final n in [
      'Hong Kong 01',
      'Japan Tokyo 02',
      'Singapore 1',
      'US Los Angeles',
      'SingLink local demo node',
    ]) {
      await c.importLink('singlink://$n#$n');
    }
    await tester.pumpWidget(
      SingLinkVpnApp(controller: c, themeMode: ThemeMode.light),
    );
    await c.connect();
    await tester.pump();
    await tester.tap(find.text('Hong Kong').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('42 ms'), findsOneWidget);
    await expectLater(
      find.byType(SingLinkVpnApp),
      matchesGoldenFile('goldens/location_sheet_light.png'),
    );
    await c.disconnect();
    c.dispose();
  });

  testWidgets('settings (light)', (tester) async {
    tester.view.physicalSize = const Size(840, 1520);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final c = ClientController(
      core: FakeCore(),
      store: MemoryStore(),
      // Fake runner: shows the switch as on macOS, runs nothing.
      systemProxy: SystemProxyManager(runner: FakeRunner()),
    );
    await c.init();
    await c.importLink('singlink://a#Hong Kong 01');
    await c.importLink('singlink://b#Japan Tokyo 02');
    await tester.pumpWidget(
      SingLinkVpnApp(controller: c, themeMode: ThemeMode.light),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SingLinkVpnApp),
      matchesGoldenFile('goldens/settings_light.png'),
    );
    c.dispose();
  });
}
