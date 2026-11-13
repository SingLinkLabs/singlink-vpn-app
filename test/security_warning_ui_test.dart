// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singlink_vpn/core/client_controller.dart';
import 'package:singlink_vpn/ui/settings_page.dart';
import 'support/fakes.dart';
import 'security_lifecycle_test.dart' show WarningCore;

void main() {
  testWidgets('security warnings are visible and cancelling does not import', (
    tester,
  ) async {
    final core = WarningCore();
    final c = ClientController(core: core, store: MemoryStore());
    await c.init();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(c: c, openAddServer: true)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'singlink://synthetic-ui');
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Review connection security'), findsOneWidget);
    expect(find.text(core.warnings.single), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(c.profiles, isEmpty);
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('I understand — import'));
    await tester.pumpAndSettle();
    expect(c.profiles.length, 1);
    expect(find.text('Review connection security'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
