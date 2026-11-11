import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_store.dart';
import 'core/client_controller.dart';
import 'core/singlink_service.dart';
import 'core/system_proxy.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Locating the core never throws; a missing library becomes a UI banner.
  final controller = ClientController(
    core: SingLinkService.locate(),
    store: AppStore.standard(),
    systemProxy: Platform.isMacOS
        ? SystemProxyManager(
            runner: const IoProcessRunner(),
            journal: ProxyJournal(
              File('${appSupportDir()}/system-proxy-restore.json'),
            ),
          )
        : null,
  )..init();
  runApp(SingLinkVpnApp(controller: controller));
}

/// Traditional Chinese (Hong Kong) — also drives correct CJK glyph selection.
const appLocale = Locale.fromSubtags(
  languageCode: 'zh',
  scriptCode: 'Hant',
  countryCode: 'HK',
);

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
      title: '星連VPN',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: widget.themeMode ?? ThemeMode.system,
      locale: appLocale,
      supportedLocales: const [
        appLocale,
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'TW',
        ),
        Locale('en'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: HomePage(c: widget.controller),
    );
  }
}
