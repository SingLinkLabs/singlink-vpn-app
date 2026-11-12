// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/app_store.dart';
import 'core/client_controller.dart';
import 'legal.dart';
import 'platform/platform_core.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicenses();
  await initPlatform();
  // Locating the core never throws; a missing library becomes a UI banner.
  final controller = ClientController(
    core: createPlatformCore(),
    store: AppStore.standard(),
    systemProxy: createSystemProxy(appSupportDir()),
  )..init();
  runApp(SingLinkVpnApp(controller: controller));
}

/// The UI is English only.
const appLocale = Locale('en', 'US');

class SingLinkVpnApp extends StatefulWidget {
  const SingLinkVpnApp({super.key, required this.controller, this.themeMode});

  final ClientController controller;

  /// Defaults to following the system.
  final ThemeMode? themeMode;

  @override
  State<SingLinkVpnApp> createState() => _SingLinkVpnAppState();
}

class _SingLinkVpnAppState extends State<SingLinkVpnApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Closing the last window or ⌘Q goes through here on macOS: put the
    // system proxy back and stop the core before the process exits.
    _lifecycle = AppLifecycleListener(onExitRequested: _onExit);
  }

  Future<AppExitResponse> _onExit() async {
    try {
      await widget.controller.shutdown().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Never block quitting; the journal restores on next launch.
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SingLinkVPN',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: widget.themeMode ?? ThemeMode.system,
      locale: appLocale,
      supportedLocales: const [appLocale],
      home: HomePage(c: widget.controller),
    );
  }
}
